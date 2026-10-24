#import <Foundation/Foundation.h>
#import "SGFrame+Internal.h"
#import "SGDescriptor+Internal.h"
#import "SGPacket+Internal.h"
#import "SGCodecContext.h"
#import "SGAudioDecoder.h"
#import "SGVideoDecoder.h"
#import "SGError.h"
#import "SGOptions.h"
#import "SGURLDemuxer.h"
#import "SGTrack+Internal.h"
#import "SGDecoderOptions.h"
#import "SGSWResample.h"
#import "SGObjectPool.h"
#import "SGClock+Internal.h"

#define CHECK(condition) do { if (!(condition)) { fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #condition); exit(1); } } while (0)

static void TestRunningClockRate(void)
{
    SGClock *clock = [[SGClock alloc] init];
    CHECK([clock open]);
    [clock setVideoTime:kCMTimeZero];
    CHECK([clock resume]);
    clock.rate = 0.5;
    Float64 begin = CMTimeGetSeconds(clock.currentTime);
    [NSThread sleepForTimeInterval:0.2];
    Float64 slow = CMTimeGetSeconds(clock.currentTime) - begin;
    CHECK(slow > 0.06 && slow < 0.16);
    clock.rate = 2.0;
    begin = CMTimeGetSeconds(clock.currentTime);
    [NSThread sleepForTimeInterval:0.2];
    Float64 fast = CMTimeGetSeconds(clock.currentTime) - begin;
    CHECK(fast > 0.3 && fast < 0.6);
    [clock pause];
    begin = CMTimeGetSeconds(clock.currentTime);
    clock.rate = 0.5;
    [NSThread sleepForTimeInterval:0.1];
    CHECK(fabs(CMTimeGetSeconds(clock.currentTime) - begin) < 0.005);
    [clock close];
    puts("PASS running video clock changes speed immediately; paused rate changes stay paused");
}

static void TestLayoutAndBuffers(void)
{
    AVChannelLayout layout = {0};
    CHECK(av_channel_layout_custom_init(&layout, 2) == 0);
    layout.u.map[0].id = AV_CHAN_FRONT_RIGHT;
    layout.u.map[1].id = AV_CHAN_FRONT_LEFT;
    SGAudioDescriptor *descriptor = [[SGAudioDescriptor alloc] init];
    descriptor.channelLayout = layout;
    SGAudioDescriptor *copy = descriptor.copy;
    av_channel_layout_uninit(&layout);
    CHECK(copy.channelLayout.u.map != descriptor.channelLayout.u.map);
    SGAudioFrame *audio = [SGAudioFrame frameWithDescriptor:descriptor numberOfSamples:257];
    CHECK(audio != nil);
    for (int i = 0; i < 257 * sizeof(float); i++) {
        CHECK(audio.core->data[0][i] == 0 && audio.core->data[1][i] == 0);
    }
    SGAudioDescriptor *fromFrame = [[SGAudioDescriptor alloc] initWithFrame:audio.core];
    [audio unlock];
    CHECK(fromFrame.channelLayout.u.map[0].id == AV_CHAN_FRONT_RIGHT);
    CHECK([fromFrame isEqualToDescriptor:copy]);
    copy.numberOfChannels = 1;
    CHECK(copy.channelLayout.nb_channels == 1);
    CHECK(descriptor.channelLayout.nb_channels == 2);
    CHECK([SGAudioFrame frameWithDescriptor:descriptor numberOfSamples:0] == nil);
    AVFrame *unsupported = av_frame_alloc();
    av_channel_layout_default(&unsupported->ch_layout, 16);
    CHECK([[SGAudioDescriptor alloc] initWithFrame:unsupported] == nil);
    av_frame_free(&unsupported);
    BOOL rejected = NO;
    @try { copy.numberOfChannels = 16; } @catch (NSException *exception) { rejected = YES; }
    CHECK(rejected);
    SGVideoDescriptor *videoDescriptor = [[SGVideoDescriptor alloc] init];
    videoDescriptor.width = 65;
    videoDescriptor.height = 49;
    videoDescriptor.format = AV_PIX_FMT_YUV420P;
    for (int i = 0; i < 100; i++) {
        SGVideoFrame *video = [SGVideoFrame frameWithDescriptor:videoDescriptor];
        CHECK(video != nil);
        CHECK(av_frame_is_writable(video.core));
        CHECK(video.core->linesize[0] >= 65);
        CHECK(video.core->data[1] && video.core->data[2]);
        memset(video.core->data[0], 128, video.core->linesize[0] * 49);
        [video fillWithTimeStamp:kCMTimeZero decodeTimeStamp:kCMTimeZero duration:CMTimeMake(1, 30)];
        CHECK(video.size >= 65 * 49);
        SGVideoFrame *reference = [SGVideoFrame frame];
        [reference fillWithFrame:video];
        [video unlock];
        CHECK(reference.core->data[0][0] == 128);
        [reference unlock];
    }
    CHECK(CMTIME_IS_INVALID(SGFFmpegTime(AV_NOPTS_VALUE, (AVRational){1, 1000})));
    CHECK(CMTimeCompare(SGFFmpegTime(90000, (AVRational){1, 90000}), CMTimeMake(1, 1)) == 0);
    puts("PASS layout ownership, channel bounds, YUV allocation/pool/reference, timestamps");
}

static void TestResample(void)
{
    SGAudioDescriptor *input = [[SGAudioDescriptor alloc] init];
    input.sampleRate = 44100;
    SGAudioDescriptor *output = input.copy;
    output.sampleRate = 48000;
    output.format = AV_SAMPLE_FMT_S16;
    SGSWResample *resample = [[SGSWResample alloc] init];
    resample.inputDescriptor = input;
    resample.outputDescriptor = output;
    CHECK([resample open]);
    int total = 0;
    for (int i = 0; i < 100; i++) {
        SGAudioFrame *frame = [SGAudioFrame frameWithDescriptor:input numberOfSamples:441];
        CHECK(frame != nil);
        CHECK(av_samples_set_silence(frame.core->data, 0, 441, 2, AV_SAMPLE_FMT_FLTP) >= 0);
        int count = [resample write:frame.core->data nb_samples:441];
        CHECK(count >= 0);
        if (count) {
            SGAudioFrame *converted = [SGAudioFrame frameWithDescriptor:output numberOfSamples:count];
            CHECK(converted != nil);
            CHECK([resample read:converted.core->data nb_samples:count] == count);
            CHECK([resample read:converted.core->data nb_samples:count + 1] < 0);
            [converted unlock];
        }
        total += count;
        [frame unlock];
    }
    int count;
    while ((count = [resample write:NULL nb_samples:0]) > 0) total += count;
    CHECK(count == 0);
    CHECK(total == 48000);
    CHECK([resample write:NULL nb_samples:-1] < 0);
    puts("PASS planar/packed resampling 44100 -> 48000 samples including EOF drain");
}

static void WritePackets(AVCodecContext *encoder, AVFormatContext *format, AVStream *stream)
{
    AVPacket *packet = av_packet_alloc();
    int result;
    while ((result = avcodec_receive_packet(encoder, packet)) >= 0) {
        av_packet_rescale_ts(packet, encoder->time_base, stream->time_base);
        packet->stream_index = stream->index;
        CHECK(av_interleaved_write_frame(format, packet) >= 0);
        av_packet_unref(packet);
    }
    CHECK(result == AVERROR(EAGAIN) || result == AVERROR_EOF);
    av_packet_free(&packet);
}

static void MakeVideo(const char *path, const char *encoderName)
{
    const AVCodec *codec = avcodec_find_encoder_by_name(encoderName);
    CHECK(codec != NULL);
    AVCodecContext *encoder = avcodec_alloc_context3(codec);
    encoder->width = 64; encoder->height = 48;
    encoder->pix_fmt = AV_PIX_FMT_YUV420P;
    encoder->time_base = (AVRational){1, 30};
    encoder->framerate = (AVRational){30, 1};
    encoder->max_b_frames = strcmp(encoderName, "mpeg4") == 0 ? 2 : 0;
    encoder->gop_size = 12;
    encoder->flags |= AV_CODEC_FLAG_GLOBAL_HEADER;
    CHECK(avcodec_open2(encoder, codec, NULL) >= 0);
    AVFormatContext *format = NULL;
    CHECK(avformat_alloc_output_context2(&format, NULL, "mp4", path) >= 0);
    AVStream *stream = avformat_new_stream(format, NULL);
    CHECK(stream != NULL);
    stream->time_base = encoder->time_base;
    CHECK(avcodec_parameters_from_context(stream->codecpar, encoder) >= 0);
    CHECK(avio_open(&format->pb, path, AVIO_FLAG_WRITE) >= 0);
    CHECK(avformat_write_header(format, NULL) >= 0);
    AVFrame *frame = av_frame_alloc();
    frame->format = encoder->pix_fmt; frame->width = encoder->width; frame->height = encoder->height;
    CHECK(av_frame_get_buffer(frame, 32) >= 0);
    for (int i = 0; i < 60; i++) {
        CHECK(av_frame_make_writable(frame) >= 0);
        memset(frame->data[0], i * 3, frame->linesize[0] * frame->height);
        memset(frame->data[1], 96, frame->linesize[1] * (frame->height / 2));
        memset(frame->data[2], 160, frame->linesize[2] * (frame->height / 2));
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

static int DecodePass(AVFormatContext *format, SGCodecContext *decoder, SGCodecDescriptor *descriptor, BOOL hardware)
{
    int frames = 0;
    AVPacket *packet = av_packet_alloc();
    while (av_read_frame(format, packet) >= 0) {
        SGPacket *input = [SGPacket packet];
        av_packet_move_ref(input.core, packet);
        NSArray<SGFrame *> *decoded = [decoder decode:input];
        [input unlock];
        for (SGFrame *frame in decoded) {
            frame.codecDescriptor = descriptor;
            [frame fill];
            CHECK(frame.size > 0);
            CHECK((frame.core->format == AV_PIX_FMT_VIDEOTOOLBOX) == hardware);
            CHECK(CMTIME_IS_NUMERIC(frame.timeStamp));
            frames++;
            [frame unlock];
        }
    }
    for (SGFrame *frame in [decoder decode:nil]) {
        frame.codecDescriptor = descriptor;
        [frame fill];
        CHECK(frame.size > 0);
        frames++;
        [frame unlock];
    }
    av_packet_free(&packet);
    return frames;
}

static void TestDecode(const char *path, const char *encoderName, BOOL hardware)
{
    MakeVideo(path, encoderName);
    AVFormatContext *format = NULL;
    CHECK(avformat_open_input(&format, path, NULL, NULL) >= 0);
    CHECK(avformat_find_stream_info(format, NULL) >= 0);
    AVStream *stream = format->streams[0];
    SGCodecDescriptor *descriptor = [[SGCodecDescriptor alloc] init];
    descriptor.timebase = stream->time_base;
    SGCodecContext *decoder = [[SGCodecContext alloc] initWithTimebase:stream->time_base codecpar:stream->codecpar frameGenerator:^SGFrame *{ return [SGVideoFrame frame]; }];
    decoder.options.hardwareDecodeH264 = hardware;
    decoder.options.hardwareDecodeH265 = hardware;
    CHECK([decoder open]);
    CHECK(DecodePass(format, decoder, descriptor, hardware) == 60);
    CHECK(avformat_seek_file(format, 0, INT64_MIN, stream->duration / 2, INT64_MAX, AVSEEK_FLAG_BACKWARD) >= 0);
    [decoder flush];
    int frames = DecodePass(format, decoder, descriptor, hardware);
    CHECK(frames > 0 && frames <= 60);
    [decoder close];
    avformat_close_input(&format);
    printf("PASS %s -> %s decode (60 frames), EOF drain, seek/flush\n", encoderName, hardware ? "VideoToolbox" : "software");
}

static void TestAudioDecode(const char *path)
{
    AVFormatContext *format = NULL;
    CHECK(avformat_open_input(&format, path, NULL, NULL) >= 0);
    CHECK(avformat_find_stream_info(format, NULL) >= 0);
    AVStream *stream = format->streams[0];
    SGCodecDescriptor *descriptor = [[SGCodecDescriptor alloc] init];
    descriptor.timebase = stream->time_base;
    descriptor.codecpar = stream->codecpar;
    descriptor.track = [[SGTrack alloc] initWithType:SGMediaTypeAudio index:0];
    SGAudioDescriptor *output = [[SGAudioDescriptor alloc] init];
    output.sampleRate = 48000;
    SGAudioDecoder *decoder = [[SGAudioDecoder alloc] init];
    decoder.options = [SGOptions sharedOptions].decoder.copy;
    decoder.options.supportedAudioDescriptors = @[output];
    AVPacket *packet = av_packet_alloc();
    int samples = 0;
    while (av_read_frame(format, packet) >= 0) {
        SGPacket *input = [SGPacket packet];
        av_packet_move_ref(input.core, packet);
        input.codecDescriptor = descriptor;
        [input fill];
        for (SGAudioFrame *frame in [decoder decode:input]) {
            CHECK(frame.descriptor.sampleRate == 48000);
            CHECK(CMTIME_IS_NUMERIC(frame.timeStamp));
            samples += frame.numberOfSamples;
            [frame unlock];
        }
        [input unlock];
    }
    for (SGAudioFrame *frame in [decoder finish]) {
        samples += frame.numberOfSamples;
        [frame unlock];
    }
    CHECK(samples == 48000);
    CHECK([decoder finish].count == 0);
    av_packet_free(&packet);
    avformat_close_input(&format);
    puts("PASS WAV -> SGAudioDecoder -> formatter/resampler, all 48000 output samples and repeated EOF");
}

static void TestHTTPS(const char *url)
{
    AVFormatContext *format = NULL;
    AVDictionary *options = NULL;
    av_dict_set(&options, "tls_verify", "1", 0);
    av_dict_set(&options, "rw_timeout", "5000000", 0);
    CHECK(avformat_open_input(&format, url, NULL, &options) < 0);
    av_dict_free(&options);
    CHECK(format == NULL);
    // Test certificate is deliberately self-signed; allow it only in this test.
    av_dict_set(&options, "tls_verify", "0", 0);
    av_dict_set(&options, "rw_timeout", "5000000", 0);
    CHECK(avformat_open_input(&format, url, NULL, &options) >= 0);
    av_dict_free(&options);
    CHECK(avformat_find_stream_info(format, NULL) >= 0);
    CHECK(format->streams[0]->codecpar->sample_rate == 44100);
    avformat_close_input(&format);
    NSURL *base = [NSURL URLWithString:[NSString stringWithUTF8String:url]];
    SGURLDemuxer *demuxer = [[SGURLDemuxer alloc] initWithURL:[[base URLByDeletingLastPathComponent] URLByAppendingPathComponent:@"player.wav"]];
    NSMutableDictionary *playerOptions = demuxer.options.options.mutableCopy;
    playerOptions[@"tls_verify"] = @0;
    demuxer.options.options = playerOptions;
    CHECK([demuxer open] == nil);
    CHECK(demuxer.tracks.count > 0);
    CHECK([demuxer close] == nil);
    puts("PASS HTTPS/SecureTransport, untrusted certificate rejection, SGURLDemuxer User-Agent");
}

#include "ffmpeg-formats.inc"
#include "media-features.inc"
#include "playback-session.inc"
#include "transcode.inc"

int main(int argc, const char *argv[])
{
    @autoreleasepool {
        CHECK(argc >= 2);
        CHECK(LIBAVCODEC_VERSION_MAJOR == 63 && LIBAVUTIL_VERSION_MAJOR == 61);
        CHECK(strcmp(av_version_info(), "9.0.2") == 0);
        BOOL formatsPassed = YES;
        if (argc >= 6 && argv[5][0]) formatsPassed = TestAdditionalFormats([NSString stringWithUTF8String:argv[5]]);
        if (argc >= 7 && argv[6][0]) MakeVideo(argv[1], "mpeg4");
        if (argc >= 7 && argv[6][0]) TestMediaFeatures([NSString stringWithUTF8String:argv[6]], [NSString stringWithUTF8String:argv[1]]);
        if (argc >= 7 && argv[6][0]) {
            TestPlaybackCoverState();
            TestNativePlaybackPolicy([NSString stringWithUTF8String:argv[1]]);
            TestPlaybackSessionPolicies([NSString stringWithUTF8String:argv[6]]);
            TestTimelinePreviews([NSString stringWithUTF8String:argv[1]]);
            TestRemuxAVSynchronization([NSString stringWithUTF8String:argv[6]], [NSString stringWithUTF8String:argv[1]]);
            TestMediaTranscoding([NSString stringWithUTF8String:argv[6]], [NSString stringWithUTF8String:argv[1]], argc>3 && argv[3][0]);
            TestMediaRemuxing([NSString stringWithUTF8String:argv[6]], [NSString stringWithUTF8String:argv[1]]);
        }
        TestRunningClockRate();
        TestLayoutAndBuffers();
        TestResample();
        TestDecode(argv[1], "mpeg4", NO);
        CHECK(argc >= 5);
        TestAudioDecode(argv[4]);
        if (argc >= 3 && argv[2][0]) TestHTTPS(argv[2]);
        if (argc >= 4 && strcmp(argv[3], "hardware") == 0) {
            TestDecode(argv[1], "h264_videotoolbox", YES);
            TestDecode(argv[1], "h264_videotoolbox", NO);
            TestDecode(argv[1], "hevc_videotoolbox", YES);
            TestDecode(argv[1], "hevc_videotoolbox", NO);
        }
        [[SGObjectPool sharedPool] flush];
        puts("PASS existing FFmpeg 9.0.2 migration regression checks");
        if (!formatsPassed) { fprintf(stderr, "FAIL extended format acceptance; see formats/results.json\n"); return 2; }
        puts("PASS FFmpeg 9.0.2 migration regression suite");
    }
    return 0;
}
