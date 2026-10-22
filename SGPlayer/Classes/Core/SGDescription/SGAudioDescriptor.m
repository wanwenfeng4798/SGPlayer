//
//  SGAudioDescriptor.m
//  SGPlayer
//
//  Created by Single on 2018/11/28.
//  Copyright © 2018 single. All rights reserved.
//

#import "SGAudioDescriptor.h"
#import "SGDescriptor+Internal.h"
#import "SGFFmpeg.h"
#import "SGFrame.h"

@implementation SGAudioDescriptor

- (id)copyWithZone:(NSZone *)zone
{
    SGAudioDescriptor *obj = [[SGAudioDescriptor alloc] init];
    obj->_format = self->_format;
    obj->_sampleRate = self->_sampleRate;
    obj->_numberOfChannels = self->_numberOfChannels;
    if (av_channel_layout_copy(&obj->_channelLayout, &self->_channelLayout) < 0) {
        return nil;
    }
    return obj;
}

- (instancetype)init
{
    if (self = [super init]) {
        self->_format = AV_SAMPLE_FMT_FLTP;
        self->_sampleRate = 44100;
        self->_numberOfChannels = 2;
        av_channel_layout_default(&self->_channelLayout, 2);
    }
    return self;
}

- (instancetype)initWithFrame:(AVFrame *)frame
{
    if (!frame || frame->ch_layout.nb_channels <= 0 || frame->ch_layout.nb_channels > SGFramePlaneCount) return nil;
    if (self = [super init]) {
        self->_format = frame->format;
        self->_sampleRate = frame->sample_rate;
        self->_numberOfChannels = frame->ch_layout.nb_channels;
        if (av_channel_layout_copy(&self->_channelLayout, &frame->ch_layout) < 0) {
            return nil;
        }
    }
    return self;
}

- (void)dealloc
{
    av_channel_layout_uninit(&self->_channelLayout);
}

- (void)setChannelLayout:(AVChannelLayout)channelLayout
{
    AVChannelLayout copy = {0};
    if (channelLayout.nb_channels > SGFramePlaneCount || !av_channel_layout_check(&channelLayout) ||
        av_channel_layout_copy(&copy, &channelLayout) < 0) {
        [NSException raise:NSInvalidArgumentException format:@"Invalid audio channel layout"];
    }
    av_channel_layout_uninit(&self->_channelLayout);
    self->_channelLayout = copy;
    self->_numberOfChannels = copy.nb_channels;
}

- (void)setNumberOfChannels:(int)numberOfChannels
{
    if (numberOfChannels <= 0 || numberOfChannels > SGFramePlaneCount) {
        [NSException raise:NSInvalidArgumentException format:@"Audio supports 1 to %d channels", SGFramePlaneCount];
    }
    if (self->_channelLayout.nb_channels != numberOfChannels) {
        av_channel_layout_uninit(&self->_channelLayout);
        av_channel_layout_default(&self->_channelLayout, numberOfChannels);
    }
    self->_numberOfChannels = numberOfChannels;
}

- (BOOL)isPlanar
{
    return av_sample_fmt_is_planar(self->_format);
}

- (int)bytesPerSample
{
    return av_get_bytes_per_sample(self->_format);
}

- (int)numberOfPlanes
{
    return av_sample_fmt_is_planar(self->_format) ? self->_numberOfChannels : 1;
}

- (int)linesize:(int)numberOfSamples
{
    if (numberOfSamples < 0 || self->_numberOfChannels <= 0) {
        return AVERROR(EINVAL);
    }
    int bytes = av_get_bytes_per_sample(self->_format);
    int channels = self.isPlanar ? 1 : self->_numberOfChannels;
    if (bytes <= 0 || (int64_t)bytes * channels * numberOfSamples > INT_MAX) {
        return AVERROR(EINVAL);
    }
    return bytes * channels * numberOfSamples;
}

- (BOOL)isEqualToDescriptor:(SGAudioDescriptor *)descriptor
{
    if (!descriptor) {
        return NO;
    }
    return
    self->_format == descriptor->_format &&
    self->_sampleRate == descriptor->_sampleRate &&
    self->_numberOfChannels == descriptor->_numberOfChannels &&
    (av_channel_layout_compare(&self->_channelLayout, &descriptor->_channelLayout) == 0);
}

@end
