// Included by the migration regression executable; no production player changes.
static void MakeFormatFixture(NSString *path, const char *muxer, const char *encoderName,
                              enum AVPixelFormat pixelFormat, int fps)
{
    const AVCodec *codec = avcodec_find_encoder_by_name(encoderName);
    CHECK(codec != NULL);
    AVCodecContext *encoder = avcodec_alloc_context3(codec);
    CHECK(encoder != NULL);
    encoder->width = 64; encoder->height = 48;
    encoder->pix_fmt = pixelFormat;
    encoder->time_base = (AVRational){1, fps};
    encoder->framerate = (AVRational){fps, 1};
    encoder->gop_size = 10;
    encoder->max_b_frames = strcmp(encoderName, "mpeg2video") == 0 ? 2 : 0;
    AVFormatContext *format = NULL;
    CHECK(avformat_alloc_output_context2(&format, NULL, muxer, path.fileSystemRepresentation) >= 0);
    if (format->oformat->flags & AVFMT_GLOBALHEADER) encoder->flags |= AV_CODEC_FLAG_GLOBAL_HEADER;
    CHECK(avcodec_open2(encoder, codec, NULL) >= 0);
    AVStream *stream = avformat_new_stream(format, NULL);
    CHECK(stream != NULL);
    stream->time_base = encoder->time_base;
    stream->avg_frame_rate = encoder->framerate;
    CHECK(avcodec_parameters_from_context(stream->codecpar, encoder) >= 0);
    CHECK(avio_open(&format->pb, path.fileSystemRepresentation, AVIO_FLAG_WRITE) >= 0);
    CHECK(avformat_write_header(format, NULL) >= 0);
    AVFrame *frame = av_frame_alloc();
    CHECK(frame != NULL);
    frame->format = pixelFormat; frame->width = 64; frame->height = 48;
    CHECK(av_frame_get_buffer(frame, 32) >= 0);
    for (int i = 0; i < 60; i++) {
        CHECK(av_frame_make_writable(frame) >= 0);
        for (int y = 0; y < 48; y++) for (int x = 0; x < 64; x++)
            frame->data[0][y * frame->linesize[0] + x] = 16 + (x + y + i * 3) % 200;
        if (pixelFormat == AV_PIX_FMT_PAL8) {
            uint32_t *palette = (uint32_t *)frame->data[1];
            for (int k = 0; k < 256; k++) palette[k] = 0xff000000U | (k << 16) | (k << 8) | k;
        } else {
            int height = pixelFormat == AV_PIX_FMT_YUV422P ? 48 : 24;
            memset(frame->data[1], 96, frame->linesize[1] * height);
            memset(frame->data[2], 160, frame->linesize[2] * height);
        }
        frame->pts = i;
        CHECK(avcodec_send_frame(encoder, frame) >= 0);
        WritePackets(encoder, format, stream);
    }
    CHECK(avcodec_send_frame(encoder, NULL) >= 0);
    WritePackets(encoder, format, stream);
    CHECK(av_write_trailer(format) >= 0);
    avio_closep(&format->pb);
    avformat_free_context(format);
    av_frame_free(&frame);
    avcodec_free_context(&encoder);
}

static NSDictionary *ReadFormatFrames(SGURLDemuxer *demuxer, SGVideoDecoder *decoder)
{
    int frames = 0;
    NSMutableSet *checksums = [NSMutableSet set];
    CMTime last = kCMTimeInvalid;
    Float64 firstSeconds = -1, lastSeconds = -1;
    __block int zeroDurations = 0;
    __block Float64 lastPTS = -1;
    void (^consume)(NSArray *) = ^(NSArray *output) {};
    __block int count = 0;
    __block CMTime previous = last;
    __block Float64 first = firstSeconds, end = lastSeconds;
    consume = ^(NSArray *output) {
        for (SGVideoFrame *frame in output) {
            CHECK(frame.descriptor.width == 64 && frame.descriptor.height == 48);
            CHECK(frame.descriptor.format == AV_PIX_FMT_YUV420P);
            CHECK(CMTIME_IS_NUMERIC(frame.timeStamp));
            CHECK(CMTIME_IS_NUMERIC(frame.duration) && CMTimeCompare(frame.duration, kCMTimeZero) >= 0);
            if (CMTimeCompare(frame.duration, kCMTimeZero) == 0) zeroDurations++;
            if (CMTIME_IS_NUMERIC(previous)) CHECK(CMTimeCompare(frame.timeStamp, previous) >= 0);
            previous = frame.timeStamp;
            Float64 seconds = CMTimeGetSeconds(frame.timeStamp);
            if (count == 0) first = seconds;
            lastPTS = seconds;
            end = seconds + CMTimeGetSeconds(frame.duration);
            uint64_t checksum = 14695981039346656037ULL;
            for (int y = 0; y < 48; y++) for (int x = 0; x < 64; x++) {
                checksum ^= frame.data[0][y * frame.linesize[0] + x];
                checksum *= 1099511628211ULL;
            }
            [checksums addObject:@(checksum)];
            count++;
            [frame unlock];
        }
    };
    NSError *error = nil;
    for (;;) {
        SGPacket *packet = nil;
        error = [demuxer nextPacket:&packet];
        if (error) break;
        CHECK(packet != nil);
        if (packet.track.type == SGMediaTypeVideo) consume([decoder decode:packet]);
        [packet unlock];
    }
    CHECK(error.code == SGErrorCodeDemuxerEndOfFile);
    consume([decoder finish]);
    CHECK([decoder finish].count == 0);
    frames = count;
    CHECK(frames > 0 && checksums.count > 1);
    return @{@"frames": @(frames), @"distinctLumaChecksums": @(checksums.count),
             @"firstSeconds": @(first), @"lastPTSSeconds": @(lastPTS), @"endSeconds": @(end),
             @"zeroDurationFrames": @(zeroDurations), @"allPositiveDurations": @(zeroDurations == 0), @"monotonicPTS": @YES,
             @"renderCompatibleYUV420P": @YES, @"repeatedEOF": @YES};
}

static BOOL TestAdditionalFormats(NSString *directory)
{
    [NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil];
    NSArray *specs = @[
        @{@"file": @"ffv1.mkv", @"muxer": @"matroska", @"encoder": @"ffv1", @"pix": @(AV_PIX_FMT_YUV420P)},
        @{@"file": @"h264.mkv", @"muxer": @"matroska", @"encoder": @"h264_videotoolbox", @"pix": @(AV_PIX_FMT_YUV420P)},
        @{@"file": @"huffyuv.avi", @"muxer": @"avi", @"encoder": @"huffyuv", @"pix": @(AV_PIX_FMT_YUV422P)},
        @{@"file": @"sorenson.flv", @"muxer": @"flv", @"encoder": @"flv", @"pix": @(AV_PIX_FMT_YUV420P)},
        @{@"file": @"mpeg2.ts", @"muxer": @"mpegts", @"encoder": @"mpeg2video", @"pix": @(AV_PIX_FMT_YUV420P)},
        @{@"file": @"wmv2.asf", @"muxer": @"asf", @"encoder": @"wmv2", @"pix": @(AV_PIX_FMT_YUV420P)},
        @{@"file": @"mpeg4.nut", @"muxer": @"nut", @"encoder": @"mpeg4", @"pix": @(AV_PIX_FMT_YUV420P)},
        @{@"file": @"animated.gif", @"muxer": @"gif", @"encoder": @"gif", @"pix": @(AV_PIX_FMT_PAL8)}
    ];
    NSMutableArray *results = [NSMutableArray array];
    for (NSDictionary *spec in specs) {
        @autoreleasepool {
            NSString *path = [directory stringByAppendingPathComponent:spec[@"file"]];
            fprintf(stderr, "FORMAT_START %s\n", path.UTF8String);
            int fps = [spec[@"muxer"] isEqual:@"gif"] ? 10 : 30;
            MakeFormatFixture(path, [spec[@"muxer"] UTF8String], [spec[@"encoder"] UTF8String], [spec[@"pix"] intValue], fps);
            AVFormatContext *probe = NULL;
            CHECK(avformat_open_input(&probe, path.fileSystemRepresentation, NULL, NULL) >= 0);
            CHECK(avformat_find_stream_info(probe, NULL) >= 0);
            NSString *formatName = [NSString stringWithUTF8String:probe->iformat->name];
            CHECK([formatName containsString:spec[@"muxer"]] || [spec[@"muxer"] isEqual:@"matroska"]);
            NSString *codecName = [NSString stringWithUTF8String:avcodec_get_name(probe->streams[0]->codecpar->codec_id)];
            AVStream *stream = probe->streams[0];
            SGCodecDescriptor *descriptor = [[SGCodecDescriptor alloc] init];
            descriptor.timebase = stream->time_base;
            SGCodecContext *rawDecoder = [[SGCodecContext alloc] initWithTimebase:stream->time_base codecpar:stream->codecpar frameGenerator:^SGFrame *{ return [SGVideoFrame frame]; }];
            rawDecoder.options.hardwareDecodeH264 = NO;
            rawDecoder.options.hardwareDecodeH265 = NO;
            CHECK([rawDecoder open]);
            int rawFrames = DecodePass(probe, rawDecoder, descriptor, NO);
            CHECK(rawFrames == 60);
            [rawDecoder close];
            avformat_close_input(&probe);
            SGURLDemuxer *demuxer = [[SGURLDemuxer alloc] initWithURL:[NSURL fileURLWithPath:path]];
            CHECK([demuxer open] == nil);
            CHECK([SGTrack tracksWithTracks:demuxer.tracks type:SGMediaTypeVideo].count == 1);
            SGVideoDecoder *decoder = [[SGVideoDecoder alloc] init];
            decoder.options = [SGOptions sharedOptions].decoder.copy;
            decoder.options.hardwareDecodeH264 = NO;
            decoder.options.hardwareDecodeH265 = NO;
            decoder.options.supportedPixelFormats = @[@(AV_PIX_FMT_YUV420P)];
            NSDictionary *initial = ReadFormatFrames(demuxer, decoder);
            fprintf(stderr, "FORMAT_DECODE %s: raw=%d player=%d zero-duration=%d\n", path.UTF8String, rawFrames, [initial[@"frames"] intValue], [initial[@"zeroDurationFrames"] intValue]);
            CHECK(fabs(([initial[@"lastPTSSeconds"] doubleValue] - [initial[@"firstSeconds"] doubleValue]) - 59.0 / fps) < 0.2);
            Float64 seekTarget = [initial[@"firstSeconds"] doubleValue] + 1.0;
            CHECK([demuxer seekToTime:CMTimeMakeWithSeconds(seekTarget, 1000)] == nil);
            [decoder flush];
            NSDictionary *defaultSeek = ReadFormatFrames(demuxer, decoder);
            // The simple seek API permits keyframe preroll. Require accuracy only
            // when the caller explicitly requests zero tolerance.
            CHECK([demuxer seekToTime:CMTimeMakeWithSeconds(seekTarget, 1000) toleranceBefor:kCMTimeZero toleranceAfter:kCMTimeZero] == nil);
            [decoder flush];
            NSDictionary *seek = ReadFormatFrames(demuxer, decoder);
            CHECK([seek[@"frames"] intValue] <= 60);
            BOOL seekAccurate = [seek[@"firstSeconds"] doubleValue] >= seekTarget - 0.05;
            [decoder flush];
            CHECK([demuxer close] == nil);
            NSMutableDictionary *result = spec.mutableCopy;
            result[@"detectedContainer"] = formatName;
            result[@"decodedCodec"] = codecName;
            result[@"initial"] = initial;
            result[@"seek"] = seek;
            result[@"defaultSeek"] = defaultSeek;
            result[@"rawFFmpegFrames"] = @(rawFrames);
            result[@"seekTargetSeconds"] = @(seekTarget);
            result[@"seekAccurate"] = @(seekAccurate);
            BOOL passed = [initial[@"frames"] intValue] == 60 && [initial[@"zeroDurationFrames"] intValue] == 0 && seekAccurate;
            result[@"passed"] = @(passed);
            result[@"timingWarning"] = [initial[@"zeroDurationFrames"] intValue] ? @"Decoded frames have zero duration; positive PTS progression is verified, but renderer scheduling/EOF needs separate runtime acceptance." : @"";
            [result removeObjectForKey:@"pix"];
            [results addObject:result];
            printf("%s format %s / %s: raw=%d, player=%d, zero-duration=%d, seek=%s\n", passed ? "PASS" : "FAIL", [spec[@"file"] UTF8String], codecName.UTF8String, rawFrames, [initial[@"frames"] intValue], [initial[@"zeroDurationFrames"] intValue], seekAccurate ? "pass" : "fail");
        }
    }
    BOOL allPassed = YES;
    for (NSDictionary *entry in results) allPassed &= [entry[@"passed"] boolValue];
    NSDictionary *report = @{@"ffmpegVersion": [NSString stringWithUTF8String:av_version_info()],
        @"platform": NSProcessInfo.processInfo.operatingSystemVersionString, @"passed": @(allPassed),
        @"scope": @"Physical Mac; generated video-only fixtures; production SGURLDemuxer + SGVideoDecoder with software decode and pixel conversion. No GPU presentation, audio tracks or mobile runtime verification in this matrix.",
        @"cases": results};
    NSData *data = [NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil];
    CHECK([data writeToFile:[directory stringByAppendingPathComponent:@"results.json"] atomically:YES]);
    return allPassed;
}
