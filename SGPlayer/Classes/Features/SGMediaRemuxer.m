#import "SGMediaRemuxer.h"
#import "SGFFmpeg.h"
#import "SGPlayer.h"
#import <QuartzCore/QuartzCore.h>
#import <libavcodec/bsf.h>
@interface SGMediaRemuxer () <SGDemuxableDelegate>
@property(atomic, readwrite) BOOL cancelled;
@property(nonatomic, readwrite) CMTimeRange actualRange;
@property(nonatomic) CFTimeInterval deadline;
@end
static NSError *SGRemuxError(int code, NSString *operation) {
    char text[AV_ERROR_MAX_STRING_SIZE] = {0};
    av_strerror(code, text, sizeof(text));
    return
        [NSError errorWithDomain:@"SGMediaRemuxer"
                            code:code
                        userInfo:@{NSLocalizedDescriptionKey : [NSString stringWithFormat:@"%@: %s", operation, text]}];
}
static int SGRemuxInterrupt(void *opaque) {
    SGMediaRemuxer *exporter = (__bridge SGMediaRemuxer *)opaque;
    return exporter.cancelled || CACurrentMediaTime() > exporter.deadline;
}
@implementation SGMediaRemuxer
- (instancetype)init {
    if ((self = [super init])) {
        _demuxerOptions = [SGOptions sharedOptions].demuxer.copy;
        _maximumWallTime = 3600;
        _actualRange = kCMTimeRangeInvalid;
    }
    return self;
}
- (void)cancel {
    self.cancelled = YES;
}
- (BOOL)demuxableShouldAbortBlockingFunctions:(id<SGDemuxable>)demuxable {
    return SGRemuxInterrupt((__bridge void *)self);
}
- (BOOL)remuxURL:(NSURL *)source
           toURL:(NSURL *)destination
       container:(SGMediaContainer)container
           range:(CMTimeRange)range
           error:(NSError **)error {
    double start = CMTimeGetSeconds(range.start), duration = CMTimeGetSeconds(range.duration);
    if (self.cancelled || !isfinite(start) || start < 0 || !isfinite(duration) || duration <= 0 || duration > 86400 ||
        !destination.isFileURL || container < 0 || container > SGMediaContainerMPEGTS ||
        [[source URLByResolvingSymlinksInPath] isEqual:[destination URLByResolvingSymlinksInPath]]) {
        if (error)
            *error = SGRemuxError(AVERROR(EINVAL), @"Invalid remux request or cancelled exporter");
        return NO;
    }
    self.actualRange = kCMTimeRangeInvalid;
    double timeout = isfinite(self.maximumWallTime) ? MIN(86400, MAX(1, self.maximumWallTime)) : 3600;
    self.deadline = CACurrentMediaTime() + timeout;
    SGURLDemuxer *demuxer = [[SGURLDemuxer alloc] initWithURL:source];
    demuxer.options = self.demuxerOptions;
    demuxer.delegate = self;
    NSError *failure = [demuxer open];
    AVFormatContext *output = NULL;
    AVBSFContext *videoBSF = NULL;
    int status = 0;
    double available = CMTimeGetSeconds(demuxer.duration);
    if (!failure && isfinite(available) && available > 0 && start >= available)
        failure = SGRemuxError(AVERROR_EOF, @"Requested range starts after the source ends");
    const char *formats[] = {"matroska", "mp4", "mpegts"};
    NSURL *temporary = [[destination URLByDeletingLastPathComponent]
        URLByAppendingPathComponent:[NSString stringWithFormat:@".sgplayer-%@.partial", NSUUID.UUID.UUIDString]];
    if (!failure) {
        status = avformat_alloc_output_context2(&output, NULL, formats[container], temporary.fileSystemRepresentation);
        if (status < 0 || !output)
            failure = SGRemuxError(status < 0 ? status : AVERROR(ENOMEM), @"Create output container");
    }
    NSMutableDictionary<NSNumber *, NSNumber *> *mapping = [NSMutableDictionary dictionary];
    SGTrack *primary = [SGTrack trackWithTracks:demuxer.tracks type:SGMediaTypeVideo];
    double origin = DBL_MAX;
    if (!failure)
        for (SGTrack *track in demuxer.tracks) {
            AVStream *input = (AVStream *)track.coreptr;
            BOOL supported = input->codecpar->codec_type == AVMEDIA_TYPE_AUDIO ||
                             input->codecpar->codec_type == AVMEDIA_TYPE_SUBTITLE ||
                             input->codecpar->codec_type == AVMEDIA_TYPE_ATTACHMENT || track == primary;
            if (!supported)
                continue;
            if ((input->codecpar->codec_type == AVMEDIA_TYPE_VIDEO ||
                 input->codecpar->codec_type == AVMEDIA_TYPE_AUDIO) &&
                input->start_time != AV_NOPTS_VALUE)
                origin = MIN(origin, input->start_time * av_q2d(input->time_base));
            if (avformat_query_codec(output->oformat, input->codecpar->codec_id, FF_COMPLIANCE_NORMAL) == 0) {
                failure = SGRemuxError(AVERROR(ENOSYS), @"A selected codec is unsupported by this container");
                break;
            }
            AVStream *stream = avformat_new_stream(output, NULL);
            if (!stream) {
                failure = SGRemuxError(AVERROR(ENOMEM), @"Create output stream");
                break;
            }
            status = avcodec_parameters_copy(stream->codecpar, input->codecpar);
            if (status < 0) {
                failure = SGRemuxError(status, @"Copy codec parameters");
                break;
            }
            stream->codecpar->codec_tag = 0;
            stream->time_base = input->time_base;
            stream->avg_frame_rate = input->avg_frame_rate;
            stream->disposition = input->disposition;
            av_dict_copy(&stream->metadata, input->metadata, 0);
            mapping[@(track.index)] = @(stream->index);
            if (container == SGMediaContainerMPEGTS && track == primary &&
                input->codecpar->codec_id == AV_CODEC_ID_MPEG4 && input->codecpar->extradata_size > 0) {
                const AVBitStreamFilter *filter = av_bsf_get_by_name("dump_extra");
                status = filter ? av_bsf_alloc(filter, &videoBSF) : AVERROR_BSF_NOT_FOUND;
                if (status >= 0) {
                    status = avcodec_parameters_copy(videoBSF->par_in, input->codecpar);
                    videoBSF->time_base_in = input->time_base;
                }
                if (status >= 0)
                    status = av_bsf_init(videoBSF);
                if (status < 0) {
                    failure = SGRemuxError(status, @"Configure MPEG-4 transport-stream headers");
                    break;
                }
            }
        }
    if (!failure && !mapping.count)
        failure = SGRemuxError(AVERROR_STREAM_NOT_FOUND, @"No recordable streams");
    BOOL knownOrigin = origin != DBL_MAX;
    if (!knownOrigin)
        origin = 0;
    if (!failure && start > 0)
        failure = [demuxer seekToTime:CMTimeMakeWithSeconds(origin + start, 1000000)];
    if (!failure) {
        output->interrupt_callback = (AVIOInterruptCB){SGRemuxInterrupt, (__bridge void *)self};
        output->avoid_negative_ts = AVFMT_AVOID_NEG_TS_MAKE_NON_NEGATIVE;
        status = avio_open2(&output->pb, temporary.fileSystemRepresentation, AVIO_FLAG_WRITE,
                            &output->interrupt_callback, NULL);
        if (status >= 0)
            status = avformat_write_header(output, NULL);
        if (status < 0)
            failure = SGRemuxError(status, @"Open output stream");
    }
    BOOL started = NO;
    double base = 0, lastEnd = 0;
    NSUInteger written = 0;
    while (!failure && !SGRemuxInterrupt((__bridge void *)self)) {
        @autoreleasepool {
            SGPacket *packet = nil;
            NSError *next = [demuxer nextPacket:&packet];
            if (next) {
                if (next.code != SGErrorCodeDemuxerEndOfFile)
                    failure = next;
                break;
            }
            AVPacket *input = (AVPacket *)packet.coreptr;
            AVStream *stream = (AVStream *)packet.track.coreptr;
            NSNumber *mapped = mapping[@(packet.track.index)];
            double pts = input->pts == AV_NOPTS_VALUE ? NAN : input->pts * av_q2d(stream->time_base);
            if (!started && isfinite(pts) &&
                ((primary && packet.track.index == primary.index && (input->flags & AV_PKT_FLAG_KEY)) || !primary)) {
                base = pts;
                lastEnd = base;
                started = YES;
                if (!knownOrigin && start == 0)
                    origin = base;
            }
            BOOL pastEnd = started && isfinite(pts) && pts >= origin + start + duration;
            if (started && mapped && !pastEnd) {
                AVPacket *copy = av_packet_clone(input);
                if (!copy) {
                    failure = SGRemuxError(AVERROR(ENOMEM), @"Clone packet");
                    [packet unlock];
                    break;
                }
                if (videoBSF && packet.track.index == primary.index) {
                    status = av_bsf_send_packet(videoBSF, copy);
                    if (status >= 0)
                        status = av_bsf_receive_packet(videoBSF, copy);
                    if (status < 0) {
                        failure = SGRemuxError(status, @"Insert MPEG-4 transport headers");
                        av_packet_free(&copy);
                        [packet unlock];
                        break;
                    }
                }
                AVStream *target = output->streams[mapped.unsignedIntValue];
                int64_t offset = av_rescale_q(llround(base * AV_TIME_BASE), AV_TIME_BASE_Q, stream->time_base);
                if (copy->pts != AV_NOPTS_VALUE)
                    copy->pts -= offset;
                if (copy->dts != AV_NOPTS_VALUE)
                    copy->dts -= offset;
                av_packet_rescale_ts(copy, stream->time_base, target->time_base);
                copy->stream_index = target->index;
                copy->pos = -1;
                status = av_interleaved_write_frame(output, copy);
                av_packet_free(&copy);
                if (status < 0)
                    failure = SGRemuxError(status, @"Write media packet");
                else {
                    written++;
                    if (isfinite(pts))
                        lastEnd = MAX(lastEnd, pts + MAX(0, input->duration * av_q2d(stream->time_base)));
                }
                if (self.progress)
                    self.progress(MIN(1, MAX(0, (lastEnd - origin - start) / duration)));
            }
            BOOL stop = pastEnd && (!primary || packet.track.index == primary.index);
            [packet unlock];
            if (stop)
                break;
        }
    }
    if (!failure && self.cancelled)
        failure = [NSError errorWithDomain:NSCocoaErrorDomain code:NSUserCancelledError userInfo:nil];
    if (!failure && CACurrentMediaTime() > self.deadline)
        failure = SGRemuxError(AVERROR(ETIMEDOUT), @"Recording deadline exceeded");
    if (!failure && !written)
        failure = SGRemuxError(AVERROR_EOF, @"No decodable packets within requested range");
    if (!failure && lastEnd <= origin + start)
        failure = SGRemuxError(AVERROR_EOF, @"Seek returned only preroll before the requested range");
    if (!failure) {
        status = av_write_trailer(output);
        if (status < 0)
            failure = SGRemuxError(status, @"Finalize container");
    }
    av_bsf_free(&videoBSF);
    if (output) {
        if (output->pb)
            avio_closep(&output->pb);
        avformat_free_context(output);
    }
    [demuxer close];
    if (!failure) {
        BOOL exists = [NSFileManager.defaultManager fileExistsAtPath:destination.path];
        BOOL published = exists
                             ? [NSFileManager.defaultManager replaceItemAtURL:destination
                                                                withItemAtURL:temporary
                                                               backupItemName:nil
                                                                      options:0
                                                             resultingItemURL:nil
                                                                        error:&failure]
                             : [NSFileManager.defaultManager moveItemAtURL:temporary toURL:destination error:&failure];
        if (!published && !failure)
            failure = SGRemuxError(AVERROR(EIO), @"Publish output");
        if (published)
            self.actualRange = CMTimeRangeMake(CMTimeMakeWithSeconds(base - origin, 1000000),
                                               CMTimeMakeWithSeconds(MAX(0, lastEnd - base), 1000000));
    }
    [NSFileManager.defaultManager removeItemAtURL:temporary error:nil];
    if (failure && error)
        *error = failure;
    return !failure;
}
@end
