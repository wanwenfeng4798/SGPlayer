#import "SGMediaTranscoder.h"
#import "SGFFmpeg.h"
#import "SGPlayer.h"
#import <QuartzCore/QuartzCore.h>
#import <libavutil/audio_fifo.h>
#import <libavutil/display.h>

static NSError *SGTranscodeError(int code, NSString *stage) {
    char text[AV_ERROR_MAX_STRING_SIZE] = {0};
    av_strerror(code, text, sizeof(text));
    return [NSError errorWithDomain:@"SGMediaTranscoder"
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey : [NSString stringWithFormat:@"%@: %s", stage, text]}];
}
@implementation SGTranscodeConfiguration
- (instancetype)init {
    if ((self = [super init])) {
        _container = SGMediaContainerMP4;
        _maximumDimension = 1280;
        _maximumFramesPerSecond = 30;
        _videoBitRate = 2000000;
        _includeVideo = YES;
        _includeAudio = YES;
        _audioBitRate = 128000;
        _audioGain = 1;
    }
    return self;
}
- (id)copyWithZone:(NSZone *)zone {
    SGTranscodeConfiguration *c = [[[self class] allocWithZone:zone] init];
    c.container = self.container;
    c.videoCodec = self.videoCodec;
    c.maximumDimension = self.maximumDimension;
    c.maximumFramesPerSecond = self.maximumFramesPerSecond;
    c.videoBitRate = self.videoBitRate;
    c.includeVideo = self.includeVideo;
    c.includeAudio = self.includeAudio;
    c.audioBitRate = self.audioBitRate;
    c.audioGain = self.audioGain;
    return c;
}
- (BOOL)validate:(NSError **)error {
    BOOL valid =
        self.container >= 0 && self.container <= SGMediaContainerMPEGTS && (self.includeVideo || self.includeAudio) &&
        (!self.includeVideo ||
         (self.videoCodec >= 0 && self.videoCodec <= SGTranscodeVideoCodecHEVCVideoToolbox &&
          self.maximumDimension >= 32 && self.maximumDimension <= 3840 && self.maximumFramesPerSecond >= 1 &&
          self.maximumFramesPerSecond <= 60 && self.videoBitRate >= 16000 && self.videoBitRate <= 200000000)) &&
        self.audioBitRate >= 16000 && self.audioBitRate <= 320000 && isfinite(self.audioGain) && self.audioGain >= 0 &&
        self.audioGain <= 4;
    if (!valid && error)
        *error = SGTranscodeError(AVERROR(EINVAL), @"Invalid transcode configuration");
    return valid;
}
@end

typedef struct {
    AVFormatContext *format;
    AVCodecContext *video, *audio;
    AVStream *videoStream, *audioStream;
    AVFrame *videoFrame;
    AVAudioFifo *fifo;
    struct SwsContext *scale;
    int64_t nextAudioPTS;
    BOOL audioStarted;
    float gain;
    NSUInteger videos;
    int64_t samples;
    double lastMediaTime;
} SGTranscodeJob;
static int SGTranscodeDrainPackets(SGTranscodeJob *job, AVCodecContext *codec, AVStream *stream) {
    AVPacket *packet = av_packet_alloc();
    if (!packet)
        return AVERROR(ENOMEM);
    int result = 0;
    while ((result = avcodec_receive_packet(codec, packet)) >= 0) {
        av_packet_rescale_ts(packet, codec->time_base, stream->time_base);
        packet->stream_index = stream->index;
        packet->pos = -1;
        result = av_interleaved_write_frame(job->format, packet);
        av_packet_unref(packet);
        if (result < 0)
            break;
    }
    av_packet_free(&packet);
    return result == AVERROR(EAGAIN) || result == AVERROR_EOF ? 0 : result;
}
static int SGTranscodeEncode(SGTranscodeJob *job, AVCodecContext *codec, AVStream *stream, AVFrame *frame) {
    int result = avcodec_send_frame(codec, frame);
    if (result == AVERROR(EAGAIN)) {
        result = SGTranscodeDrainPackets(job, codec, stream);
        if (result >= 0)
            result = avcodec_send_frame(codec, frame);
    }
    if (result == AVERROR_EOF && !frame)
        return 0;
    return result < 0 ? result : SGTranscodeDrainPackets(job, codec, stream);
}
static int SGTranscodeDrainAudio(SGTranscodeJob *job, BOOL final) {
    int block = job->audio->frame_size;
    while (av_audio_fifo_size(job->fifo) >= block || (final && av_audio_fifo_size(job->fifo) > 0)) {
        int useful = MIN(block, av_audio_fifo_size(job->fifo));
        AVFrame *frame = av_frame_alloc();
        if (!frame)
            return AVERROR(ENOMEM);
        frame->format = job->audio->sample_fmt;
        frame->sample_rate = 48000;
        frame->nb_samples = block;
        frame->pts = job->nextAudioPTS;
        frame->duration = block;
        int result = av_channel_layout_copy(&frame->ch_layout, &job->audio->ch_layout);
        if (result >= 0)
            result = av_frame_get_buffer(frame, 0);
        if (result >= 0)
            result = av_samples_set_silence(frame->extended_data, 0, block, 2, AV_SAMPLE_FMT_FLTP);
        if (result >= 0 && av_audio_fifo_read(job->fifo, (void **)frame->extended_data, useful) != useful)
            result = AVERROR(EIO);
        if (result >= 0) {
            for (int p = 0; p < 2; p++) {
                float *data = (float *)frame->extended_data[p];
                for (int i = 0; i < useful; i++)
                    data[i] = fminf(1, fmaxf(-1, data[i] * job->gain));
            }
            result = SGTranscodeEncode(job, job->audio, job->audioStream, frame);
        }
        av_frame_free(&frame);
        if (result < 0)
            return result;
        job->samples += useful;
        job->lastMediaTime = MAX(job->lastMediaTime, (job->nextAudioPTS + useful) / 48000.0);
        job->nextAudioPTS += block;
    }
    return 0;
}
static int SGTranscodeAppendAudio(SGTranscodeJob *job, SGAudioFrame *frame) {
    if (frame.descriptor.sampleRate != 48000 || frame.descriptor.numberOfChannels != 2 ||
        frame.descriptor.format != AV_SAMPLE_FMT_FLTP)
        return AVERROR(EINVAL);
    double seconds = CMTimeGetSeconds(frame.timeStamp);
    if (!isfinite(seconds) || seconds < 0)
        return AVERROR(EINVAL);
    int64_t position = llround(seconds * 48000);
    int skip = 0, count = frame.numberOfSamples;
    if (!job->audioStarted) {
        job->audioStarted = YES;
        job->nextAudioPTS = position;
    }
    int64_t delta = position - (job->nextAudioPTS + av_audio_fifo_size(job->fifo));
    if (delta > 0) {
        // Fill at most one partial AAC block. Long timestamp gaps never allocate silence proportional to the gap.
        int needed = job->audio->frame_size - av_audio_fifo_size(job->fifo);
        int fill = (int)MIN(delta, needed);
        if (av_audio_fifo_size(job->fifo) > 0 || delta < job->audio->frame_size) {
            float silence[1024] = {0};
            void *planes[2] = {silence, silence};
            if (fill > 1024)
                return AVERROR(EINVAL);
            if (av_audio_fifo_realloc(job->fifo, av_audio_fifo_size(job->fifo) + fill) < 0)
                return AVERROR(ENOMEM);
            if (av_audio_fifo_write(job->fifo, planes, fill) != fill)
                return AVERROR(EIO);
            int result = SGTranscodeDrainAudio(job, NO);
            if (result < 0)
                return result;
        }
        if (av_audio_fifo_size(job->fifo) == 0)
            job->nextAudioPTS = position;
    } else if (delta < 0) {
        skip = (int)MIN((int64_t)count, -delta);
        count -= skip;
    }
    if (count <= 0)
        return 0;
    if (av_audio_fifo_realloc(job->fifo, av_audio_fifo_size(job->fifo) + count) < 0)
        return AVERROR(ENOMEM);
    uint8_t *planes[2] = {frame.data[0] + skip * sizeof(float), frame.data[1] + skip * sizeof(float)};
    if (av_audio_fifo_write(job->fifo, (void **)planes, count) != count)
        return AVERROR(EIO);
    return SGTranscodeDrainAudio(job, NO);
}
@interface SGMediaTranscoder () <SGDemuxableDelegate, SGFrameReaderDelegate>
@property(atomic, readwrite) BOOL cancelled;
@property(nonatomic) BOOL used;
@property(nonatomic) CFTimeInterval deadline;
@property(nonatomic, readwrite) NSUInteger videoFrameCount;
@property(nonatomic, readwrite) int64_t audioSampleCount;
@property(nonatomic, readwrite) CMTimeRange actualRange;
@end
static int SGTranscodeInterrupt(void *opaque) {
    SGMediaTranscoder *job = (__bridge SGMediaTranscoder *)opaque;
    return job.cancelled || CACurrentMediaTime() > job.deadline;
}
@implementation SGMediaTranscoder
- (instancetype)init {
    if ((self = [super init])) {
        _maximumWallTime = 3600;
        _demuxerOptions = [SGOptions sharedOptions].demuxer.copy;
        _actualRange = kCMTimeRangeInvalid;
    }
    return self;
}
- (void)cancel {
    @synchronized(self) {
        self.cancelled = YES;
    }
}
- (BOOL)demuxableShouldAbortBlockingFunctions:(id<SGDemuxable>)demuxable {
    return SGTranscodeInterrupt((__bridge void *)self);
}
- (BOOL)frameReaderShouldAbortBlockingFunctions:(SGFrameReader *)reader {
    return SGTranscodeInterrupt((__bridge void *)self);
}
- (BOOL)transcodeURL:(NSURL *)source
               toURL:(NSURL *)destination
       configuration:(SGTranscodeConfiguration *)configuration
               range:(CMTimeRange)range
             effects:(SGMediaEffects *)effects
               error:(NSError **)error {
    @synchronized(self) {
        if (self.used) {
            if (error)
                *error = SGTranscodeError(AVERROR(EINVAL), @"Exporter already used");
            return NO;
        }
        self.used = YES;
    }
    SGTranscodeConfiguration *config = [configuration copy];
    double start = CMTimeGetSeconds(range.start), duration = CMTimeGetSeconds(range.duration);
    NSError *failure = nil;
    if (!config || ![config validate:&failure] || (!config.includeVideo && effects) || self.cancelled ||
        !isfinite(start) || start < 0 || !isfinite(duration) || duration <= 0 || duration > 86400 ||
        !destination.isFileURL || !source.scheme.length ||
        [[source URLByResolvingSymlinksInPath] isEqual:[destination URLByResolvingSymlinksInPath]]) {
        if (error)
            *error =
                failure
                    ?: SGTranscodeError(self.cancelled ? AVERROR_EXIT : AVERROR(EINVAL), @"Invalid transcode request");
        return NO;
    }
    self.deadline =
        CACurrentMediaTime() + (isfinite(self.maximumWallTime) ? MIN(86400, MAX(1, self.maximumWallTime)) : 3600);
    SGTranscodeJob job = {0};
    job.gain = config.audioGain;
    SGURLDemuxer *probe = [[SGURLDemuxer alloc] initWithURL:source];
    probe.options = self.demuxerOptions;
    probe.delegate = self;
    failure = [probe open];
    SGTrack *primaryVideo = [SGTrack trackWithTracks:probe.tracks type:SGMediaTypeVideo];
    SGTrack *video = config.includeVideo ? primaryVideo : nil,
            *audio = config.includeAudio ? [SGTrack trackWithTracks:probe.tracks type:SGMediaTypeAudio] : nil;
    if (!failure && ((config.includeVideo && !video) || (!config.includeVideo && !audio)))
        failure = SGTranscodeError(AVERROR_STREAM_NOT_FOUND, @"Requested primary track is unavailable");
    double available = CMTimeGetSeconds(probe.duration);
    if (!failure && isfinite(available) && available > 0) {
        if (start >= available)
            failure = SGTranscodeError(AVERROR_EOF, @"Range starts after source ends");
        else
            duration = MIN(duration, available - start);
    }
    AVStream *input = video ? (AVStream *)video.coreptr : NULL;
    double origin = DBL_MAX;
    for (SGTrack *track in audio ? @[ primaryVideo ?: audio, audio ] : video ? @[ video ] : @[]) {
        AVStream *stream = (AVStream *)track.coreptr;
        if (stream->start_time != AV_NOPTS_VALUE)
            origin = MIN(origin, stream->start_time * av_q2d(stream->time_base));
    }
    if (origin == DBL_MAX)
        origin = 0;
    CGAffineTransform display = CGAffineTransformIdentity;
    CGSize sourceSize = CGSizeZero;
    double pixelAspect = 1;
    if (!failure && video) {
        if (input->codecpar->color_trc == AVCOL_TRC_SMPTE2084 || input->codecpar->color_trc == AVCOL_TRC_ARIB_STD_B67)
            failure = SGTranscodeError(AVERROR(ENOSYS), @"HDR tone mapping is not implemented by this SDR exporter");
        double sar = input->sample_aspect_ratio.den ? av_q2d(input->sample_aspect_ratio) : 1;
        if (!isfinite(sar) || sar <= 0)
            sar = 1;
        pixelAspect = sar;
        sourceSize = CGSizeMake(input->codecpar->width * sar, input->codecpar->height);
        const AVPacketSideData *side = av_packet_side_data_get(
            input->codecpar->coded_side_data, input->codecpar->nb_coded_side_data, AV_PKT_DATA_DISPLAYMATRIX);
        if (side && side->size >= 9 * sizeof(int32_t)) {
            const int32_t *m = (const int32_t *)side->data;
            if (m[2] || m[5] || m[8] != (1 << 30))
                failure = SGTranscodeError(AVERROR(ENOSYS), @"Projective display matrix is unsupported");
            else
                display = CGAffineTransformMake(m[0] / 65536.0, m[1] / 65536.0, m[3] / 65536.0, m[4] / 65536.0,
                                                m[6] / 65536.0, m[7] / 65536.0);
        }
        CGRect bounds = CGRectApplyAffineTransform(CGRectMake(0, 0, sourceSize.width, sourceSize.height), display);
        if (!isfinite(bounds.size.width) || !isfinite(bounds.size.height) || bounds.size.width <= 0 ||
            bounds.size.height <= 0)
            failure = SGTranscodeError(AVERROR(EINVAL), @"Invalid video dimensions or display transform");
        else {
            double scale = MIN(1, config.maximumDimension / MAX(bounds.size.width, bounds.size.height));
            sourceSize = CGSizeMake(MAX(2, floor(bounds.size.width * scale / 2) * 2),
                                    MAX(2, floor(bounds.size.height * scale / 2) * 2));
        }
    }
    SGMutableAsset *asset = [SGMutableAsset new];
    CMTimeRange clip =
        CMTimeRangeMake(CMTimeMakeWithSeconds(origin + start, 1000000), CMTimeMakeWithSeconds(duration, 1000000));
    if (!failure) {
        NSMutableArray<SGTrack *> *tracks = [NSMutableArray array];
        if (video)
            [tracks addObject:video];
        if (audio)
            [tracks addObject:audio];
        for (SGTrack *track in tracks) {
            SGMutableTrack *target = [asset addTrack:track.type];
            if (![target appendSegment:[[SGURLSegment alloc] initWithURL:source
                                                                   index:track.index
                                                               timeRange:clip
                                                                   scale:CMTimeMake(1, 1)]])
                failure = SGTranscodeError(AVERROR(EINVAL), @"Create clipped track");
        }
    }
    [probe close];
    SGFrameReader *reader = nil;
    if (!failure) {
        reader = [[SGFrameReader alloc] initWithAsset:asset];
        reader.demuxerOptions = self.demuxerOptions;
        reader.delegate = self;
        SGDecoderOptions *options = [SGOptions sharedOptions].decoder.copy;
        options.padAudioToRangeStart = NO;
        options.resetFrameRate = NO;
        SGAudioDescriptor *descriptor = [SGAudioDescriptor new];
        descriptor.format = AV_SAMPLE_FMT_FLTP;
        descriptor.sampleRate = 48000;
        descriptor.numberOfChannels = 2;
        options.supportedAudioDescriptors = @[ descriptor ];
        reader.decoderOptions = options;
        failure = [reader open];
        if (!failure)
            failure = [reader seekable];
        if (!failure)
            failure = [reader seekToTime:kCMTimeZero];
    }
    NSURL *temporary = [[destination URLByDeletingLastPathComponent]
        URLByAppendingPathComponent:[NSString
                                        stringWithFormat:@".sgplayer-transcode-%@.partial", NSUUID.UUID.UUIDString]];
    const char *formats[] = {"matroska", "mp4", "mpegts"},
               *encoders[] = {"mpeg4", "h264_videotoolbox", "hevc_videotoolbox"};
    int result = 0;
    if (!failure) {
        result = avformat_alloc_output_context2(&job.format, NULL, formats[config.container],
                                                temporary.fileSystemRepresentation);
        if (result < 0 || !job.format)
            failure = SGTranscodeError(result < 0 ? result : AVERROR(ENOMEM), @"Create output");
    }
    if (!failure && video) {
        const AVCodec *codec = avcodec_find_encoder_by_name(encoders[config.videoCodec]);
        job.video = codec ? avcodec_alloc_context3(codec) : NULL;
        job.videoStream = avformat_new_stream(job.format, NULL);
        if (!job.video || !job.videoStream)
            failure = SGTranscodeError(codec ? AVERROR(ENOMEM) : AVERROR_ENCODER_NOT_FOUND, @"Create video encoder");
        else {
            job.video->width = (int)sourceSize.width;
            job.video->height = (int)sourceSize.height;
            job.video->pix_fmt = AV_PIX_FMT_YUV420P;
            job.video->time_base = (AVRational){1, 60000};
            job.video->framerate = (AVRational){(int)config.maximumFramesPerSecond, 1};
            job.video->bit_rate = config.videoBitRate;
            job.video->gop_size = (int)config.maximumFramesPerSecond * 2;
            job.video->max_b_frames = 0;
            job.video->thread_count = 2;
            job.video->color_primaries = AVCOL_PRI_BT709;
            job.video->color_trc = AVCOL_TRC_BT709;
            job.video->colorspace = AVCOL_SPC_BT709;
            job.video->color_range = AVCOL_RANGE_MPEG;
            job.video->sample_aspect_ratio = (AVRational){1, 1};
            if (job.format->oformat->flags & AVFMT_GLOBALHEADER)
                job.video->flags |= AV_CODEC_FLAG_GLOBAL_HEADER;
            result = avcodec_open2(job.video, codec, NULL);
            if (result >= 0)
                result = avcodec_parameters_from_context(job.videoStream->codecpar, job.video);
            job.videoStream->time_base = job.video->time_base;
            job.videoStream->avg_frame_rate = job.video->framerate;
            if (result < 0)
                failure = SGTranscodeError(result, @"Open selected video encoder");
        }
    }
    if (!failure && audio) {
        const AVCodec *codec = avcodec_find_encoder(AV_CODEC_ID_AAC);
        job.audio = codec ? avcodec_alloc_context3(codec) : NULL;
        job.audioStream = avformat_new_stream(job.format, NULL);
        if (!job.audio || !job.audioStream)
            failure = SGTranscodeError(AVERROR(ENOMEM), @"Create AAC encoder");
        else {
            job.audio->sample_fmt = AV_SAMPLE_FMT_FLTP;
            job.audio->sample_rate = 48000;
            job.audio->time_base = (AVRational){1, 48000};
            job.audio->bit_rate = config.audioBitRate;
            av_channel_layout_default(&job.audio->ch_layout, 2);
            if (job.format->oformat->flags & AVFMT_GLOBALHEADER)
                job.audio->flags |= AV_CODEC_FLAG_GLOBAL_HEADER;
            result = avcodec_open2(job.audio, codec, NULL);
            if (result >= 0)
                result = avcodec_parameters_from_context(job.audioStream->codecpar, job.audio);
            job.audioStream->time_base = job.audio->time_base;
            if (result < 0 || job.audio->frame_size != 1024)
                failure = SGTranscodeError(result < 0 ? result : AVERROR(ENOSYS), @"Open stereo AAC encoder");
            else {
                job.fifo = av_audio_fifo_alloc(AV_SAMPLE_FMT_FLTP, 2, 1024);
                if (!job.fifo)
                    failure = SGTranscodeError(AVERROR(ENOMEM), @"Create bounded audio FIFO");
            }
        }
    }
    if (!failure) {
        job.format->interrupt_callback = (AVIOInterruptCB){SGTranscodeInterrupt, (__bridge void *)self};
        job.format->max_interleave_delta = AV_TIME_BASE;
        job.format->avoid_negative_ts = AVFMT_AVOID_NEG_TS_MAKE_NON_NEGATIVE;
        result = avio_open2(&job.format->pb, temporary.fileSystemRepresentation, AVIO_FLAG_WRITE,
                            &job.format->interrupt_callback, NULL);
        if (result >= 0)
            result = avformat_write_header(job.format, NULL);
        if (result < 0)
            failure = SGTranscodeError(result, @"Write output header");
    }
    if (!failure && video) {
        job.videoFrame = av_frame_alloc();
        if (job.videoFrame) {
            job.videoFrame->format = AV_PIX_FMT_YUV420P;
            job.videoFrame->width = job.video->width;
            job.videoFrame->height = job.video->height;
            result = av_frame_get_buffer(job.videoFrame, 32);
        } else
            result = AVERROR(ENOMEM);
        job.scale = sws_getContext(job.video->width, job.video->height, AV_PIX_FMT_BGRA, job.video->width,
                                   job.video->height, AV_PIX_FMT_YUV420P, SWS_BICUBIC, NULL, NULL, NULL);
        if (result < 0 || !job.scale)
            failure = SGTranscodeError(result < 0 ? result : AVERROR(ENOMEM), @"Allocate video conversion");
        else
            sws_setColorspaceDetails(job.scale, sws_getCoefficients(SWS_CS_ITU709), 1,
                                     sws_getCoefficients(SWS_CS_ITU709), 0, 0, 1 << 16, 1 << 16);
    }
    SGMediaEffects *compositor = video ? (effects ?: [SGMediaEffects new]) : nil;
    BOOL previousSoftware = compositor.softwareRendering;
    compositor.softwareRendering = YES;
    double nextVideoTime = 0, lastProgress = 0;
    NSUInteger videoBudget = video ? (NSUInteger)ceil(duration * config.maximumFramesPerSecond) : 0;
    while (!failure && !SGTranscodeInterrupt((__bridge void *)self)) {
        @autoreleasepool {
            SGFrame *frame = nil;
            NSError *next = [reader nextFrame:&frame];
            if (next) {
                if (next.code != SGErrorCodeDemuxerEndOfFile)
                    failure = next;
                break;
            }
            double time = CMTimeGetSeconds(frame.timeStamp);
            if (!isfinite(time)) {
                failure = SGTranscodeError(AVERROR(EINVAL), @"Frame has no finite timestamp");
                [frame unlock];
                break;
            }
            if (frame.track.type == SGMediaTypeVideo && time >= 0 && time < duration) {
                if (time + .001 >= nextVideoTime && job.videos < videoBudget) {
                    SGPLFImage *platform = [(SGVideoFrame *)frame image];
                    CGImageRef cg = NULL;
#if SGPLATFORM_TARGET_OS_MAC
                    cg = [platform CGImageForProposedRect:NULL context:nil hints:nil];
#else
                    cg = platform.CGImage;
#endif
                    CIImage *image = cg ? [CIImage imageWithCGImage:cg] : nil;
                    if (image) {
                        image = [image imageByApplyingTransform:CGAffineTransformMakeScale(pixelAspect, 1)];
                        image = [image
                            imageByApplyingTransform:CGAffineTransformMake(1, 0, 0, -1, 0, image.extent.size.height)];
                        image = [image imageByApplyingTransform:display];
                        image = [image imageByApplyingTransform:CGAffineTransformMakeScale(1, -1)];
                        CGRect b = image.extent;
                        image =
                            [image imageByApplyingTransform:CGAffineTransformMakeTranslation(-b.origin.x, -b.origin.y)];
                        double scale = MIN(job.video->width / b.size.width, job.video->height / b.size.height);
                        image = [image imageByApplyingTransform:CGAffineTransformMakeScale(scale, scale)];
                        image =
                            [image imageByApplyingTransform:CGAffineTransformMakeTranslation(
                                                                (job.video->width - image.extent.size.width) / 2,
                                                                (job.video->height - image.extent.size.height) / 2)];
                        CIImage *black = [[CIImage imageWithColor:[CIColor colorWithRed:0 green:0 blue:0]]
                            imageByCroppingToRect:CGRectMake(0, 0, job.video->width, job.video->height)];
                        image = [[image imageByCompositingOverImage:black] imageByCroppingToRect:black.extent];
                    }
                    CVPixelBufferRef buffer =
                        image
                            ? [compositor copyPixelBufferForImage:image
                                                           atTime:CMTimeMakeWithSeconds(origin + start + time, 1000000)]
                            : NULL;
                    if (!buffer)
                        failure = compositor.lastError ?: SGTranscodeError(AVERROR(EINVAL), @"Compose export frame");
                    else {
                        result = av_frame_make_writable(job.videoFrame);
                        CVReturn lock = CVPixelBufferLockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly);
                        if (result >= 0 && lock == kCVReturnSuccess) {
                            const uint8_t *planes[4] = {CVPixelBufferGetBaseAddress(buffer), NULL, NULL, NULL};
                            int strides[4] = {(int)CVPixelBufferGetBytesPerRow(buffer), 0, 0, 0};
                            result = sws_scale(job.scale, planes, strides, 0, job.video->height, job.videoFrame->data,
                                               job.videoFrame->linesize);
                            if (result == job.video->height) {
                                job.videoFrame->pts = llround(time * 60000);
                                double d = CMTimeGetSeconds(frame.duration);
                                job.videoFrame->duration =
                                    MAX(1, llround(MIN(duration - time,
                                                       isfinite(d) && d > 0 ? d : 1.0 / config.maximumFramesPerSecond) *
                                                   60000));
                                result = SGTranscodeEncode(&job, job.video, job.videoStream, job.videoFrame);
                            } else if (result >= 0)
                                result = AVERROR(EIO);
                        } else if (lock != kCVReturnSuccess)
                            result = AVERROR(EIO);
                        if (lock == kCVReturnSuccess)
                            CVPixelBufferUnlockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly);
                        CVPixelBufferRelease(buffer);
                        if (result < 0)
                            failure = SGTranscodeError(result, @"Encode video frame");
                        else {
                            job.videos++;
                            nextVideoTime += 1.0 / config.maximumFramesPerSecond;
                            if (nextVideoTime < time - .001)
                                nextVideoTime =
                                    (floor(time * config.maximumFramesPerSecond) + 1) / config.maximumFramesPerSecond;
                            job.lastMediaTime = MAX(job.lastMediaTime, time + job.videoFrame->duration / 60000.0);
                        }
                    }
                }
            } else if (frame.track.type == SGMediaTypeAudio && job.audio && time >= 0 && time < duration) {
                result = SGTranscodeAppendAudio(&job, (SGAudioFrame *)frame);
                if (result < 0)
                    failure = SGTranscodeError(result, @"Encode audio samples");
            }
            [frame unlock];
            self.videoFrameCount = job.videos;
            self.audioSampleCount = job.samples;
            lastProgress = MAX(lastProgress, MIN(1, job.lastMediaTime / duration));
            if (self.progress)
                self.progress(lastProgress);
        }
    }
    if (!failure && SGTranscodeInterrupt((__bridge void *)self))
        failure = SGTranscodeError(self.cancelled ? AVERROR_EXIT : AVERROR(ETIMEDOUT), @"Transcode interrupted");
    if (!failure && config.includeVideo && !job.videos)
        failure = SGTranscodeError(AVERROR_EOF, @"No video frames within range");
    if (!failure && job.audio) {
        result = SGTranscodeDrainAudio(&job, YES);
        if (result >= 0)
            result = SGTranscodeEncode(&job, job.audio, job.audioStream, NULL);
        if (result < 0)
            failure = SGTranscodeError(result, @"Drain AAC encoder");
    }
    if (!failure && !config.includeVideo && !job.samples)
        failure = SGTranscodeError(AVERROR_EOF, @"No audio samples within range");
    if (!failure) {
        result = job.video ? SGTranscodeEncode(&job, job.video, job.videoStream, NULL) : 0;
        if (result >= 0)
            result = av_write_trailer(job.format);
        if (result < 0)
            failure = SGTranscodeError(result, @"Finalize encoded media");
    }
    self.videoFrameCount = job.videos;
    self.audioSampleCount = job.samples;
    compositor.softwareRendering = previousSoftware;
    [reader close];
    if (job.format) {
        if (job.format->pb) {
            int closed = avio_closep(&job.format->pb);
            if (closed < 0 && !failure)
                failure = SGTranscodeError(closed, @"Close encoded output");
        }
        avformat_free_context(job.format);
    }
    avcodec_free_context(&job.video);
    avcodec_free_context(&job.audio);
    av_frame_free(&job.videoFrame);
    if (job.fifo)
        av_audio_fifo_free(job.fifo);
    sws_freeContext(job.scale);
    if (!failure) {
        @synchronized(self) {
            if (SGTranscodeInterrupt((__bridge void *)self))
                failure = SGTranscodeError(self.cancelled ? AVERROR_EXIT : AVERROR(ETIMEDOUT), @"Publish cancelled");
            else {
                BOOL exists = [NSFileManager.defaultManager fileExistsAtPath:destination.path];
                BOOL published = exists ? [NSFileManager.defaultManager replaceItemAtURL:destination
                                                                           withItemAtURL:temporary
                                                                          backupItemName:nil
                                                                                 options:0
                                                                        resultingItemURL:nil
                                                                                   error:&failure]
                                        : [NSFileManager.defaultManager moveItemAtURL:temporary
                                                                                toURL:destination
                                                                                error:&failure];
                if (!published && !failure)
                    failure = SGTranscodeError(AVERROR(EIO), @"Publish encoded media");
                if (published)
                    self.actualRange =
                        CMTimeRangeMake(range.start, CMTimeMakeWithSeconds(MIN(duration, job.lastMediaTime), 1000000));
            }
        }
    }
    [NSFileManager.defaultManager removeItemAtURL:temporary error:nil];
    if (failure && error)
        *error = failure;
    return !failure;
}
@end
