//
//  SGAudioFrame.m
//  SGPlayer
//
//  Created by Single on 2018/1/19.
//  Copyright © 2018年 single. All rights reserved.
//

#import "SGAudioFrame.h"
#import "SGFrame+Internal.h"
#import "SGDescriptor+Internal.h"
#import "SGObjectPool.h"

@interface SGAudioFrame ()

{
    int _linesize[SGFramePlaneCount];
    uint8_t *_data[SGFramePlaneCount];
}

@end

@implementation SGAudioFrame

+ (instancetype)frame
{
    static NSString *name = @"SGAudioFrame";
    return [[SGObjectPool sharedPool] objectWithClass:[self class] reuseName:name];
}

+ (instancetype)frameWithDescriptor:(SGAudioDescriptor *)descriptor numberOfSamples:(int)numberOfSamples
{
    if (!descriptor || descriptor.numberOfChannels <= 0 ||
        descriptor.numberOfChannels > SGFramePlaneCount ||
        descriptor.sampleRate <= 0 || numberOfSamples <= 0) {
        return nil;
    }
    SGAudioFrame *frame = [SGAudioFrame frame];
    if (!frame) return nil;
    frame.core->format = descriptor.format;
    frame.core->nb_samples = numberOfSamples;
    frame.core->sample_rate = descriptor.sampleRate;
    AVChannelLayout layout = descriptor.channelLayout;
    if (av_channel_layout_copy(&frame.core->ch_layout, &layout) < 0 ||
        av_frame_get_buffer(frame.core, 0) < 0) {
        [frame unlock];
        return nil;
    }
    if (av_samples_set_silence(frame.core->extended_data, 0, numberOfSamples,
                               descriptor.numberOfChannels, descriptor.format) < 0) {
        [frame unlock];
        return nil;
    }
    // Audio processing uses exact sample bytes, excluding allocation padding.
    int linesize = [descriptor linesize:numberOfSamples];
    for (int i = 0; i < descriptor.numberOfPlanes; i++) {
        frame.core->linesize[i] = linesize;
    }
    return frame;
}

#pragma mark - Setter & Getter

- (SGMediaType)type
{
    return SGMediaTypeAudio;
}

- (int *)linesize
{
    return self->_linesize;
}

- (uint8_t **)data
{
    return self->_data;
}

#pragma mark - Data

- (void)clear
{
    [super clear];
    self->_numberOfSamples = 0;
    for (int i = 0; i < SGFramePlaneCount; i++) {
        self->_data[i] = nil;
        self->_linesize[i] = 0;
    }
    self->_descriptor = nil;
}

#pragma mark - Control

- (void)fill
{
    AVFrame *frame = self.core;
    AVRational timebase = self.codecDescriptor.timebase;
    SGCodecDescriptor *cd = self.codecDescriptor;
    CMTime duration = CMTimeMake(frame->nb_samples, frame->sample_rate);
    CMTime timeStamp = SGFFmpegTime(frame->best_effort_timestamp, timebase);
    CMTime decodeTimeStamp = SGFFmpegTime(frame->pkt_dts, timebase);
    duration = [cd convertDuration:duration];
    timeStamp = [cd convertTimeStamp:timeStamp];
    decodeTimeStamp = [cd convertTimeStamp:decodeTimeStamp];
    [self fillWithTimeStamp:timeStamp decodeTimeStamp:decodeTimeStamp duration:duration];
}

- (void)fillWithFrame:(SGFrame *)frame
{
    [super fillWithFrame:frame];
    SGAudioFrame *audioFrame = (SGAudioFrame *)frame;
    self->_numberOfSamples = audioFrame->_numberOfSamples;
    self->_descriptor = audioFrame->_descriptor.copy;
    for (int i = 0; i < SGFramePlaneCount; i++) {
        self->_data[i] = audioFrame->_data[i];
        self->_linesize[i] = audioFrame->_linesize[i];
    }
}

- (void)fillWithTimeStamp:(CMTime)timeStamp decodeTimeStamp:(CMTime)decodeTimeStamp duration:(CMTime)duration
{
    [super fillWithTimeStamp:timeStamp decodeTimeStamp:decodeTimeStamp duration:duration];
    AVFrame *frame = self.core;
    self->_numberOfSamples = frame->nb_samples;
    self->_descriptor = [[SGAudioDescriptor alloc] initWithFrame:frame];
    for (int i = 0; i < SGFramePlaneCount; i++) {
        self->_data[i] = frame->data[i];
        self->_linesize[i] = i < self->_descriptor.numberOfPlanes ? [self->_descriptor linesize:frame->nb_samples] : 0;
    }
}

@end
