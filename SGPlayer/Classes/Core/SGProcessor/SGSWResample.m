//
//  SGSWResample.m
//  SGPlayer iOS
//
//  Created by Single on 2018/10/30.
//  Copyright © 2018 single. All rights reserved.
//

#import "SGSWResample.h"
#import "SGDescriptor+Internal.h"
#import "SGFFmpeg.h"
#import "SGFrame.h"

@interface SGSWResample ()

{
    AVBufferRef *_buffer[SGFramePlaneCount];
}

@property (nonatomic, readonly) SwrContext *context;
@property (nonatomic) int samplesAvailable;

@end

@implementation SGSWResample

- (void)dealloc
{
    if (self->_context) {
        swr_free(&_context);
        self->_context = nil;
    }
    for (int i = 0; i < SGFramePlaneCount; i++) {
        av_buffer_unref(&self->_buffer[i]);
        self->_buffer[i] = nil;
    }
}

- (BOOL)open
{
    if (!self->_inputDescriptor ||
        !self->_outputDescriptor ||
        self->_inputDescriptor.numberOfChannels <= 0 ||
        self->_outputDescriptor.numberOfChannels <= 0 ||
        self->_inputDescriptor.numberOfChannels > SGFramePlaneCount ||
        self->_outputDescriptor.numberOfChannels > SGFramePlaneCount) {
        return NO;
    }
    swr_free(&self->_context);
    self->_samplesAvailable = 0;
    AVChannelLayout inputChannelLayout = self->_inputDescriptor.channelLayout;
    AVChannelLayout outputChannelLayout = self->_outputDescriptor.channelLayout;
    int result = swr_alloc_set_opts2(&self->_context,
                                     &outputChannelLayout,
                                     self->_outputDescriptor.format,
                                     self->_outputDescriptor.sampleRate,
                                     &inputChannelLayout,
                                     self->_inputDescriptor.format,
                                     self->_inputDescriptor.sampleRate,
                                     0, NULL);
    if (result < 0) {
        return NO;
    }
    if (swr_init(self->_context) < 0) {
        swr_free(&self->_context);
        return NO;
    }
    return YES;
}

- (int)write:(uint8_t **)data nb_samples:(int)nb_samples
{
    self->_samplesAvailable = 0;
    if (!self->_context || nb_samples < 0) return AVERROR(EINVAL);
    int numberOfPlanes = self->_outputDescriptor.numberOfPlanes;
    int numberOfSamples = swr_get_out_samples(self->_context, nb_samples);
    if (numberOfSamples < 0) return numberOfSamples;
    if (numberOfSamples == 0) return 0;
    int linesize = [self->_outputDescriptor linesize:numberOfSamples];
    if (linesize <= 0) return AVERROR(EINVAL);
    uint8_t *o_data[SGFramePlaneCount] = {NULL};
    for (int i = 0; i < numberOfPlanes; i++) {
        if (!self->_buffer[i] || self->_buffer[i]->size < linesize) {
            int result = av_buffer_realloc(&self->_buffer[i], linesize);
            if (result < 0) return result;
        }
        o_data[i] = self->_buffer[i]->data;
    }
    int result = swr_convert(self->_context,
                       (uint8_t **)o_data,
                       numberOfSamples,
                       (const uint8_t **)data,
                       nb_samples);
    self->_samplesAvailable = MAX(result, 0);
    return result;
}

- (int)read:(uint8_t **)data nb_samples:(int)nb_samples
{
    if (!data || nb_samples < 0 || nb_samples > self->_samplesAvailable) return AVERROR(EINVAL);
    if (nb_samples == 0) return 0;
    int numberOfPlanes = self->_outputDescriptor.numberOfPlanes;
    int linesize = [self->_outputDescriptor linesize:nb_samples];
    if (linesize <= 0) return AVERROR(EINVAL);
    for (int i = 0; i < numberOfPlanes; i++) {
        if (!data[i] || !self->_buffer[i] || self->_buffer[i]->size < linesize) return AVERROR(EINVAL);
        memcpy(data[i], self->_buffer[i]->data, linesize);
    }
    return nb_samples;
}

- (int)delay
{
    int64_t delay = swr_get_delay(self->_context, self->_outputDescriptor.sampleRate);
    NSAssert(delay < INT32_MAX, @"Invalid ");
    return (int)delay;
}

@end
