//
//  SGFrame.m
//  SGPlayer
//
//  Created by Single on 2018/6/26.
//  Copyright © 2018 single. All rights reserved.
//

#import "SGFrame.h"
#import "SGFrame+Internal.h"
#import "SGObjectPool.h"
#import <CoreVideo/CoreVideo.h>

// Decoded frames account for owned memory, rather than compressed packet bytes.
static int SGFrameBufferSize(const AVFrame *frame)
{
    if (frame->format == AV_PIX_FMT_VIDEOTOOLBOX && frame->data[3]) {
        return (int)MIN(CVPixelBufferGetDataSize((CVPixelBufferRef)frame->data[3]), (size_t)INT_MAX);
    }
    int64_t size = 0;
    int count = AV_NUM_DATA_POINTERS + frame->nb_extended_buf;
    for (int i = 0; i < count; i++) {
        const AVBufferRef *buffer = i < AV_NUM_DATA_POINTERS ? frame->buf[i] : frame->extended_buf[i - AV_NUM_DATA_POINTERS];
        if (!buffer) continue;
        BOOL duplicate = NO;
        for (int j = 0; j < i; j++) {
            const AVBufferRef *previous = j < AV_NUM_DATA_POINTERS ? frame->buf[j] : frame->extended_buf[j - AV_NUM_DATA_POINTERS];
            if (previous && previous->buffer == buffer->buffer) { duplicate = YES; break; }
        }
        if (!duplicate) {
            size += MIN(buffer->size, (size_t)INT_MAX);
            if (size >= INT_MAX) return INT_MAX;
        }
    }
    return (int)size;
}

@interface SGFrame ()

{
    NSLock *_lock;
    NSUInteger _lockingCount;
}

@end

@implementation SGFrame

@synthesize flags = _flags;
@synthesize reuseName = _reuseName;

+ (instancetype)frame
{
    NSAssert(NO, @"Subclass only.");
    return nil;
}

- (instancetype)init
{
    if (self = [super init]) {
        self->_lock = [[NSLock alloc] init];
        self->_core = av_frame_alloc();
        if (!self->_core) return nil;
        self->_coreptr = self->_core;
        [self clear];
    }
    return self;
}

- (void)dealloc
{
    NSAssert(self->_lockingCount == 0, @"SGFrame, Invalid locking count");
    [self clear];
    if (self->_core) {
        av_frame_free(&self->_core);
        self->_core = nil;
    }
}

- (NSString *)description
{
    return [NSString stringWithFormat:@"<%@: %p>, track: %d, pts: %f, end: %f, duration: %f",
            NSStringFromClass(self.class), self,
            (int)self->_track.index,
            CMTimeGetSeconds(self->_timeStamp),
            CMTimeGetSeconds(CMTimeAdd(self->_timeStamp, self->_duration)),
            CMTimeGetSeconds(self->_duration)];
}

#pragma mark - Setter & Getter

- (SGMediaType)type
{
    return SGMediaTypeUnknown;
}

#pragma mark - Data

- (void)lock
{
    [self->_lock lock];
    self->_lockingCount += 1;
    [self->_lock unlock];
}

- (void)unlock
{
    [self->_lock lock];
    NSAssert(self->_lockingCount > 0, @"SGFrame, Invalid locking count");
    self->_lockingCount -= 1;
    BOOL comeback = self->_lockingCount == 0;
    [self->_lock unlock];
    if (comeback) {
        [[SGObjectPool sharedPool] comeback:self];
    }
}

- (void)clear
{
    if (self->_core) {
        av_frame_unref(self->_core);
    }
    self->_size = 0;
    self->_flags = 0;
    self->_track = nil;
    self->_duration = kCMTimeZero;
    self->_timeStamp = kCMTimeZero;
    self->_decodeTimeStamp = kCMTimeZero;
    self->_codecDescriptor = nil;
}

#pragma mark - Control

- (void)fill
{
    AVFrame *frame = self->_core;
    AVRational timebase = self->_codecDescriptor.timebase;
    SGCodecDescriptor *cd = self->_codecDescriptor;
    self->_size = SGFrameBufferSize(frame);
    self->_track = cd.track;
    self->_metadata = cd.metadata;
    CMTime duration = SGFFmpegTime(frame->duration, timebase);
    CMTime timeStamp = SGFFmpegTime(frame->best_effort_timestamp, timebase);
    CMTime decodeTimeStamp = SGFFmpegTime(frame->pkt_dts, timebase);
    self->_duration = [cd convertDuration:duration];
    self->_timeStamp = [cd convertTimeStamp:timeStamp];
    self->_decodeTimeStamp = [cd convertTimeStamp:decodeTimeStamp];
}

- (void)fillWithFrame:(SGFrame *)frame
{
    av_frame_ref(self->_core, frame->_core);
    self->_size = frame->_size;
    self->_track = frame->_track;
    self->_metadata = frame->_metadata;
    self->_duration = frame->_duration;
    self->_timeStamp = frame->_timeStamp;
    self->_decodeTimeStamp = frame->_decodeTimeStamp;
    self->_codecDescriptor = frame->_codecDescriptor.copy;
}

- (void)fillWithTimeStamp:(CMTime)timeStamp decodeTimeStamp:(CMTime)decodeTimeStamp duration:(CMTime)duration
{
    AVFrame *frame = self->_core;
    SGCodecDescriptor *cd = self->_codecDescriptor;
    self->_size = SGFrameBufferSize(frame);
    self->_track = cd.track;
    self->_metadata = cd.metadata;
    self->_duration = duration;
    self->_timeStamp = timeStamp;
    self->_decodeTimeStamp = decodeTimeStamp;
}

@end
