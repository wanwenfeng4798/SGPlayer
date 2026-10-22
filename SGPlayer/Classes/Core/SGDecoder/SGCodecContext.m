//
//  SGCodecContext.m
//  SGPlayer iOS
//
//  Created by Single on 2018/8/16.
//  Copyright © 2018 single. All rights reserved.
//

#import "SGCodecContext.h"
#import "SGPacket+Internal.h"
#import "SGFrame+Internal.h"
#import "SGMapping.h"
#import "SGOptions.h"
#import "SGError.h"
#import "SGMacro.h"

@interface SGCodecContext ()

@property (nonatomic, readonly) AVRational timebase;
@property (nonatomic, readonly) AVCodecParameters *codecpar;
@property (nonatomic, readonly) AVCodecContext *codecContext;
@property (nonatomic, copy, readonly) __kindof SGFrame *(^frameGenerator)(void);

@end

@implementation SGCodecContext

- (instancetype)initWithTimebase:(AVRational)timebase
                        codecpar:(AVCodecParameters *)codecpar
                  frameGenerator:(__kindof SGFrame *(^)(void))frameGenerator
{
    if (self = [super init]) {
        self->_timebase = timebase;
        self->_codecpar = codecpar;
        self->_frameGenerator = frameGenerator;
        self->_options = [SGOptions sharedOptions].decoder.copy;
    }
    return self;
}

- (void)dealloc
{
    [self close];
}

#pragma mark - Interface

- (BOOL)open
{
    if (!self->_codecpar) {
        return NO;
    }
    self->_codecContext = [self createCcodecContext];
    if (!self->_codecContext) {
        return NO;
    }
    return YES;
}

- (void)close
{
    if (self->_codecContext) {
        avcodec_free_context(&self->_codecContext);
        self->_codecContext = nil;
    }
}

- (void)flush
{
    if (self->_codecContext) {
        avcodec_flush_buffers(self->_codecContext);
    }
}

- (NSArray<__kindof SGFrame *> *)decode:(SGPacket *)packet
{
    if (!self->_codecContext) {
        return nil;
    }
    NSMutableArray *array = [NSMutableArray array];
    int result = avcodec_send_packet(self->_codecContext, packet ? packet.core : NULL);
    if (result == AVERROR(EAGAIN)) {
        [self receiveFrames:array];
        result = avcodec_send_packet(self->_codecContext, packet ? packet.core : NULL);
    }
    if (result >= 0 || result == AVERROR_EOF) {
        [self receiveFrames:array];
    } else {
        av_log(self->_codecContext, AV_LOG_ERROR, "SGPlayer: sending packet failed (%d)\n", result);
    }
    return array;
}

- (void)receiveFrames:(NSMutableArray<SGFrame *> *)frames
{
    while (YES) {
        SGFrame *frame = self->_frameGenerator();
        if (!frame) return;
        int result = avcodec_receive_frame(self->_codecContext, frame.core);
        if (result < 0) {
            [frame unlock];
            if (result != AVERROR(EAGAIN) && result != AVERROR_EOF) {
                av_log(self->_codecContext, AV_LOG_ERROR, "SGPlayer: receiving frame failed (%d)\n", result);
            }
            return;
        }
        // The processing chain stores at most eight audio planes.
        if (self->_codecContext->codec_type == AVMEDIA_TYPE_AUDIO &&
            (frame.core->ch_layout.nb_channels <= 0 || frame.core->ch_layout.nb_channels > SGFramePlaneCount)) {
            av_log(self->_codecContext, AV_LOG_ERROR, "SGPlayer: unsupported audio channel count\n");
            [frame unlock];
            continue;
        }
        [frames addObject:frame];
    }
}

#pragma mark - AVCodecContext

- (AVCodecContext *)createCcodecContext
{
    AVCodecContext *codecContext = avcodec_alloc_context3(NULL);
    if (!codecContext) {
        return nil;
    }
    codecContext->opaque = (__bridge void *)self;
    
    int result = avcodec_parameters_to_context(codecContext, self->_codecpar);
    NSError *error = SGGetFFError(result, SGActionCodeCodecSetParametersToContext);
    if (error) {
        avcodec_free_context(&codecContext);
        return nil;
    }
    codecContext->pkt_timebase = self->_timebase;
    if ((self->_options.hardwareDecodeH264 && self->_codecpar->codec_id == AV_CODEC_ID_H264) ||
        (self->_options.hardwareDecodeH265 && self->_codecpar->codec_id == AV_CODEC_ID_H265)) {
        codecContext->get_format = SGCodecContextGetFormat;
    }
    
    const AVCodec *codec = avcodec_find_decoder(codecContext->codec_id);
    if (!codec) {
        avcodec_free_context(&codecContext);
        return nil;
    }
    codecContext->codec_id = codec->id;
    
    AVDictionary *opts = SGDictionaryNS2FF(self->_options.options);
    if (self->_options.threadsAuto &&
        !av_dict_get(opts, "threads", NULL, 0)) {
        av_dict_set(&opts, "threads", "auto", 0);
    }
    result = avcodec_open2(codecContext, codec, &opts);
    
    if (opts) {
        const AVDictionaryEntry *entry = NULL;
        while ((entry = av_dict_get(opts, "", entry, AV_DICT_IGNORE_SUFFIX))) {
            av_log(codecContext, AV_LOG_WARNING, "SGPlayer: unused decoder option %s\n", entry->key);
        }
        av_dict_free(&opts);
    }
    
    error = SGGetFFError(result, SGActionCodeCodecOpen2);
    if (error) {
        avcodec_free_context(&codecContext);
        return nil;
    }
    
    return codecContext;
}

static enum AVPixelFormat SGCodecContextGetFormat(struct AVCodecContext *s, const enum AVPixelFormat *fmt)
{
    for (int i = 0; fmt[i] != AV_PIX_FMT_NONE; i++) {
        if (fmt[i] == AV_PIX_FMT_VIDEOTOOLBOX) {
            if (s->hw_device_ctx) return fmt[i];
            AVBufferRef *device = NULL;
            if (av_hwdevice_ctx_create(&device, AV_HWDEVICE_TYPE_VIDEOTOOLBOX, NULL, NULL, 0) >= 0) {
                s->hw_device_ctx = device;
                return fmt[i];
            }
            av_buffer_unref(&device);
            break;
        }
    }
    for (int i = 0; fmt[i] != AV_PIX_FMT_NONE; i++) {
        const AVPixFmtDescriptor *descriptor = av_pix_fmt_desc_get(fmt[i]);
        if (descriptor && !(descriptor->flags & AV_PIX_FMT_FLAG_HWACCEL) && sws_isSupportedInput(fmt[i])) {
            return fmt[i];
        }
    }
    return AV_PIX_FMT_NONE;
}

@end
