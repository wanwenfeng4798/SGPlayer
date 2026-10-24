#import "SGMediaTranscoder.h"
#import <libavutil/display.h>

typedef struct {NSUInteger videos,audios,red,neutral;int width,height;double signalStart,quietEnergy,toneEnergy;NSUInteger quietSamples,toneSamples;int leftDifference,rightDifference;} SGTranscodeAnalysis;
static SGTranscodeAnalysis AnalyzeTranscode(NSString *path,BOOL pixels) {
    SGTranscodeAnalysis a={0};a.signalStart=NAN;
    SGFrameReader *reader=[[SGFrameReader alloc]initWithAsset:[SGAsset assetWithURL:[NSURL fileURLWithPath:path]]];SGDecoderOptions *options=[SGOptions sharedOptions].decoder.copy;
    SGAudioDescriptor *audio=[SGAudioDescriptor new];audio.format=AV_SAMPLE_FMT_FLTP;audio.sampleRate=48000;audio.numberOfChannels=2;options.supportedAudioDescriptors=@[audio];reader.decoderOptions=options;CHECK(![reader open]);
    while(YES){SGFrame *frame=nil;NSError *error=[reader nextFrame:&frame];if(error){CHECK(error.code==SGErrorCodeDemuxerEndOfFile);break;}
        CHECK(CMTIME_IS_NUMERIC(frame.timeStamp));
        if(frame.track.type==SGMediaTypeVideo){a.videos++;SGVideoFrame *video=(SGVideoFrame *)frame;
            if(a.videos==1){SGPLFImage *image=video.image;CGImageRef cg=[image CGImageForProposedRect:NULL context:nil hints:nil];CHECK(cg);a.width=(int)CGImageGetWidth(cg);a.height=(int)CGImageGetHeight(cg);
                if(pixels){SGMediaEffects *identity=[SGMediaEffects new];identity.softwareRendering=YES;NSData *bytes=FeaturePixels(identity,[CIImage imageWithCGImage:cg],0);NSUInteger stride=bytes.length/a.height;const uint8_t *p=bytes.bytes;
                    for(int y=0;y<a.height;y++)for(int x=0;x<a.width;x++){const uint8_t *c=p+y*stride+x*4;int r=c[2],g=c[1],b=c[0];if(r>80&&r>g+50&&r>b+50)a.red++;if(abs(r-g)<15&&abs(g-b)<15)a.neutral++;}
                    const uint8_t *left=p+(a.height/2)*stride+(a.width/4)*4,*right=p+(a.height/2)*stride+(a.width*3/4)*4;a.leftDifference=left[2]-left[0];a.rightDifference=right[2]-right[0];
                }
            }
        }else if(frame.track.type==SGMediaTypeAudio){a.audios++;SGAudioFrame *sound=(SGAudioFrame *)frame;CHECK(sound.descriptor.format==AV_SAMPLE_FMT_FLTP);const float *samples=(const float *)sound.data[0];double start=CMTimeGetSeconds(sound.timeStamp);
            for(int i=0;i<sound.numberOfSamples;i++){double t=start+i/48000.0,v=samples[i];if(!isfinite(a.signalStart)&&fabs(v)>.02)a.signalStart=t;if(t>=.05&&t<.15){a.quietEnergy+=v*v;a.quietSamples++;}if(t>=.4&&t<.8){a.toneEnergy+=v*v;a.toneSamples++;}}
        }
        [frame unlock];
    }
    [reader close];return a;
}
static CGSize CopyVideoWithMetadata(NSString *source,NSString *destination,BOOL rotation,BOOL hdr,BOOL widePixels) {
    AVFormatContext *input=NULL,*output=NULL;CHECK(avformat_open_input(&input,source.fileSystemRepresentation,NULL,NULL)>=0);CHECK(avformat_find_stream_info(input,NULL)>=0);
    int index=av_find_best_stream(input,AVMEDIA_TYPE_VIDEO,-1,-1,NULL,0);CHECK(index>=0);AVStream *original=input->streams[index];CGSize size=CGSizeMake(original->codecpar->width,original->codecpar->height);
    CHECK(avformat_alloc_output_context2(&output,NULL,hdr?"matroska":"mp4",destination.fileSystemRepresentation)>=0);AVStream *stream=avformat_new_stream(output,NULL);CHECK(stream);CHECK(avcodec_parameters_copy(stream->codecpar,original->codecpar)>=0);stream->codecpar->codec_tag=0;stream->time_base=original->time_base;
    if(widePixels){stream->sample_aspect_ratio=(AVRational){2,1};stream->codecpar->sample_aspect_ratio=(AVRational){2,1};}
    if(rotation){AVPacketSideData *side=av_packet_side_data_new(&stream->codecpar->coded_side_data,&stream->codecpar->nb_coded_side_data,AV_PKT_DATA_DISPLAYMATRIX,9*sizeof(int32_t),0);CHECK(side);av_display_rotation_set((int32_t *)side->data,90);}
    if(hdr){stream->codecpar->color_trc=AVCOL_TRC_SMPTE2084;stream->codecpar->color_primaries=AVCOL_PRI_BT2020;}
    CHECK(avio_open(&output->pb,destination.fileSystemRepresentation,AVIO_FLAG_WRITE)>=0);CHECK(avformat_write_header(output,NULL)>=0);AVPacket *packet=av_packet_alloc();CHECK(packet);
    while(av_read_frame(input,packet)>=0){if(packet->stream_index==index){av_packet_rescale_ts(packet,original->time_base,stream->time_base);packet->stream_index=0;packet->pos=-1;CHECK(av_interleaved_write_frame(output,packet)>=0);}av_packet_unref(packet);}
    CHECK(av_write_trailer(output)>=0);av_packet_free(&packet);avio_closep(&output->pb);avformat_free_context(output);avformat_close_input(&input);return size;
}
static NSData *FirstTranscodePixels(NSString *path) {
    SGFrameReader *reader=[[SGFrameReader alloc]initWithAsset:[SGAsset assetWithURL:[NSURL fileURLWithPath:path]]];CHECK(![reader open]);NSData *pixels=nil;
    while(!pixels){SGFrame *frame=nil;NSError *error=[reader nextFrame:&frame];CHECK(!error);if(frame.track.type==SGMediaTypeVideo){SGPLFImage *image=[(SGVideoFrame *)frame image];CGImageRef cg=[image CGImageForProposedRect:NULL context:nil hints:nil];CHECK(cg);SGMediaEffects *identity=[SGMediaEffects new];identity.softwareRendering=YES;pixels=FeaturePixels(identity,[CIImage imageWithCGImage:cg],0);}[frame unlock];}
    [reader close];return pixels;
}
static void TestSegmentFrameBoundaries(NSString *source) {
    SGMutableAsset *asset=[SGMutableAsset new];SGMutableTrack *video=[asset addTrack:SGMediaTypeVideo];CHECK([video appendSegment:[[SGURLSegment alloc]initWithURL:[NSURL fileURLWithPath:source] index:0 timeRange:CMTimeRangeMake(CMTimeMake(7,10),CMTimeMake(1,2)) scale:CMTimeMake(1,1)]]);
    SGFrameReader *reader=[[SGFrameReader alloc]initWithAsset:asset];SGDecoderOptions *options=[SGOptions sharedOptions].decoder.copy;options.resetFrameRate=NO;options.supportedPixelFormats=@[@(AV_PIX_FMT_YUV420P)];reader.decoderOptions=options;CHECK(![reader open]);NSUInteger frames=0;double end=0;
    while(YES){SGVideoFrame *frame=nil;NSError *error=[reader nextFrame:&frame];if(error){CHECK(error.code==SGErrorCodeDemuxerEndOfFile);break;}CHECK(fabs(CMTimeGetSeconds(frame.timeStamp)-frames/30.0)<.0011);const uint8_t *y=frame.data[0];int value=y[(frame.descriptor.height/2)*frame.linesize[0]+frame.descriptor.width/2];CHECK(abs(value-(int)(21+frames)*3)<=2);end=CMTimeGetSeconds(CMTimeAdd(frame.timeStamp,frame.duration));frames++;[frame unlock];}
    CHECK(frames==15&&fabs(end-.5)<.0011);[reader close];
    for(int pad=0;pad<2;pad++){
        SGMutableAsset *sound=[SGMutableAsset new];SGMutableTrack *track=[sound addTrack:SGMediaTypeAudio];CHECK([track appendSegment:[[SGURLSegment alloc]initWithURL:[NSURL fileURLWithPath:source] index:1 timeRange:CMTimeRangeMake(kCMTimeZero,CMTimeMake(1,1)) scale:CMTimeMake(1,1)]]);
        SGFrameReader *audio=[[SGFrameReader alloc]initWithAsset:sound];SGDecoderOptions *policy=[SGOptions sharedOptions].decoder.copy;policy.padAudioToRangeStart=pad;audio.decoderOptions=policy;CHECK(![audio open]);SGAudioFrame *frame=nil;CHECK(![audio nextFrame:&frame]);double start=CMTimeGetSeconds(frame.timeStamp);CHECK(pad?fabs(start)<.0001:start>.2);[frame unlock];[audio close];
    }
    puts("PASS exact segment B-frame timestamps/content/end and optional timestamp-preserving audio range alignment");
}
static void TestBurnedOverlayVariants(NSString *directory,NSString *source) {
    NSURL *font=[NSURL fileURLWithPath:[[@(__FILE__) stringByDeletingLastPathComponent]stringByAppendingPathComponent:@"../SGPlayer/Resources/Fonts/NotoSansCJKsc-Regular.otf"]];
    for(int kernel=0;kernel<2;kernel++){
        SGTranscodeConfiguration *config=[SGTranscodeConfiguration new];config.maximumDimension=64;config.maximumFramesPerSecond=10;config.includeAudio=NO;
        NSData *baseline=nil;
        for(int scene=0;scene<4;scene++){
            SGMediaEffects *effects=[SGMediaEffects new];effects.kernel=kernel;effects.subtitleFallbackFontURL=font;effects.textSize=12;SGFilterConfiguration *gray=[SGFilterConfiguration new];gray.grayscale=YES;effects.filter=gray;
            if(scene==1){SGSubtitleCue *cue=[SGSubtitleCue new];cue.start=kCMTimeZero;cue.duration=CMTimeMake(1,1);cue.text=@"Burn 中";effects.subtitles=@[cue];effects.subtitlesEnabled=YES;}
            if(scene==2){SGDanmakuItem *item=[SGDanmakuItem new];item.start=kCMTimeZero;item.duration=1;item.mode=SGDanmakuModeTop;item.text=@"DM";effects.danmaku=@[item];effects.danmakuEnabled=YES;}
            if(scene==3){NSError *error=nil;effects.sticker=[SGAnimatedImage imageWithURL:[NSURL fileURLWithPath:[directory stringByAppendingPathComponent:@"export.gif"]] maxDecodedBytes:8*1024*1024 error:&error];CHECK(effects.sticker);effects.stickerStart=0;effects.stickerRect=CGRectMake(.25,.25,.5,.5);}
            NSString *path=[directory stringByAppendingPathComponent:[NSString stringWithFormat:@"burned-%d-%d.mp4",kernel,scene]];SGMediaTranscoder *exporter=[SGMediaTranscoder new];NSError *error=nil;CHECK([exporter transcodeURL:[NSURL fileURLWithPath:source] toURL:[NSURL fileURLWithPath:path] configuration:config range:CMTimeRangeMake(kCMTimeZero,CMTimeMake(1,2)) effects:effects error:&error]);NSData *pixels=FirstTranscodePixels(path);if(scene==0)baseline=pixels;else CHECK(![pixels isEqual:baseline]);
        }
    }
    puts("PASS both kernels independently burn real CJK subtitles, danmaku and animated GIF sticker into decoded MP4 pixels");
}
static void TestEffectSnapshotIsolation(void) {
    SGMediaEffects *effects=[SGMediaEffects new];SGFilterConfiguration *filter=[SGFilterConfiguration new];filter.brightness=.2;effects.filter=filter;
    SGSubtitleCue *cue=[SGSubtitleCue new];cue.start=kCMTimeZero;cue.duration=CMTimeMake(1,1);cue.text=@"Owned";SGSubtitleTrack *track=[SGSubtitleTrack new];track.language=@"en";track.cues=@[cue];effects.subtitleTrack=track;effects.subtitles=@[cue];effects.secondarySubtitleTrack=track;
    SGDanmakuItem *event=[SGDanmakuItem new];event.text=@"Before";effects.danmaku=@[event];SGWatermark *mark=[SGWatermark new];mark.text=@"Mark";mark.opacity=.5;effects.watermarks=@[mark];
    SGMediaEffects *copy=[effects snapshot];effects.filter.brightness=.8;cue.text=@"Changed";track.language=@"zh";event.text=@"After";mark.opacity=0;
    CHECK(copy.filter.brightness==.2&&[copy.subtitles[0].text isEqual:@"Owned"]&&[copy.subtitleTrack.language isEqual:@"en"]&&[copy.secondarySubtitleTrack.cues[0].text isEqual:@"Owned"]&&[copy.danmaku[0].text isEqual:@"Before"]&&copy.watermarks[0].opacity==.5);
    CHECK(copy.subtitleTrack!=track&&copy.subtitles[0]!=cue&&copy.danmaku[0]!=event&&copy.watermarks[0]!=mark);
    puts("PASS effect export snapshots isolate filters, primary/secondary cues, tracks, danmaku and watermarks");
}
static void TestAudioOnlyTranscoding(NSString *directory, NSString *source, NSString *videoOnly) {
    NSMutableArray *reports=[NSMutableArray array];
    SGTranscodeConfiguration *config=[SGTranscodeConfiguration new];config.includeVideo=NO;
    CHECK(![(SGTranscodeConfiguration *)config.copy includeVideo]);
    config.includeAudio=NO;CHECK(![config validate:nil]);config.includeAudio=YES;
    for (NSInteger container=0;container<3;container++) {
        config.container=container;
        NSString *path=[directory stringByAppendingPathComponent:[NSString stringWithFormat:@"audio-only-transcode.%@",@[@"mkv",@"m4a",@"ts"][container]]];
        NSError *error=nil;SGMediaTranscoder *exporter=[SGMediaTranscoder new];
        CHECK([exporter transcodeURL:[NSURL fileURLWithPath:source] toURL:[NSURL fileURLWithPath:path] configuration:config range:CMTimeRangeMake(kCMTimeZero,CMTimeMake(1,1)) effects:nil error:&error]);
        CHECK(exporter.videoFrameCount==0&&exporter.audioSampleCount>35000&&exporter.audioSampleCount<38000);
        CHECK(CMTimeGetSeconds(exporter.actualRange.duration)<=1.001);
        AVFormatContext *format=NULL;CHECK(avformat_open_input(&format,path.fileSystemRepresentation,NULL,NULL)>=0);CHECK(avformat_find_stream_info(format,NULL)>=0);
        CHECK(format->nb_streams==1&&format->streams[0]->codecpar->codec_id==AV_CODEC_ID_AAC&&format->streams[0]->codecpar->sample_rate==48000&&format->streams[0]->codecpar->ch_layout.nb_channels==2);avformat_close_input(&format);
        SGTranscodeAnalysis decoded=AnalyzeTranscode(path,NO);CHECK(decoded.videos==0&&decoded.audios>10&&isfinite(decoded.signalStart)&&decoded.toneEnergy>0);
        [reports addObject:@{@"container":@(container),@"samples":@(exporter.audioSampleCount),@"decodedAudioFrames":@(decoded.audios),@"videoFrames":@(decoded.videos)}];
    }
    config.container=SGMediaContainerMP4;config.maximumDimension=0;config.maximumFramesPerSecond=0;config.videoCodec=-1;CHECK([config validate:nil]);
    NSString *pureSource=[directory stringByAppendingPathComponent:@"audio-only-transcode.m4a"],*pureOutput=[directory stringByAppendingPathComponent:@"audio-only-reencoded.m4a"];
    SGMediaTranscoder *pure=[SGMediaTranscoder new];NSError *pureError=nil;
    CHECK([pure transcodeURL:[NSURL fileURLWithPath:pureSource] toURL:[NSURL fileURLWithPath:pureOutput] configuration:config range:CMTimeRangeMake(kCMTimeZero,CMTimeMake(1,5)) effects:nil error:&pureError]);
    CHECK(pure.videoFrameCount==0&&pure.audioSampleCount>8000&&pure.audioSampleCount<11000);CHECK(AnalyzeTranscode(pureOutput,NO).audios>0);
    config.audioGain=0;
    NSURL *destination=[NSURL fileURLWithPath:[directory stringByAppendingPathComponent:@"audio-only-silent.m4a"]];NSError *error=nil;
    SGMediaTranscoder *silent=[SGMediaTranscoder new];CHECK([silent transcodeURL:[NSURL fileURLWithPath:source] toURL:destination configuration:config range:CMTimeRangeMake(CMTimeMake(7,10),CMTimeMake(1,2)) effects:nil error:&error]);
    CHECK(silent.audioSampleCount>22000&&silent.audioSampleCount<25000);
    SGTranscodeAnalysis silence=AnalyzeTranscode(destination.path,NO);CHECK(silence.audios>0&&silence.videos==0&&!isfinite(silence.signalStart)&&silence.toneEnergy<1e-8);
    NSData *existing=[NSData dataWithContentsOfURL:destination];
    SGMediaTranscoder *missing=[SGMediaTranscoder new];CHECK(![missing transcodeURL:[NSURL fileURLWithPath:videoOnly] toURL:destination configuration:config range:CMTimeRangeMake(kCMTimeZero,CMTimeMake(1,1)) effects:nil error:&error]);CHECK([[NSData dataWithContentsOfURL:destination]isEqual:existing]);
    SGMediaTranscoder *effects=[SGMediaTranscoder new];CHECK(![effects transcodeURL:[NSURL fileURLWithPath:source] toURL:destination configuration:config range:CMTimeRangeMake(kCMTimeZero,CMTimeMake(1,1)) effects:[SGMediaEffects new] error:&error]);CHECK([[NSData dataWithContentsOfURL:destination]isEqual:existing]);
    SGMediaTranscoder *cancel=[SGMediaTranscoder new];__weak SGMediaTranscoder *weakCancel=cancel;cancel.progress=^(double progress){[weakCancel cancel];};CHECK(![cancel transcodeURL:[NSURL fileURLWithPath:source] toURL:destination configuration:config range:CMTimeRangeMake(kCMTimeZero,CMTimeMake(1,1)) effects:nil error:&error]);CHECK([[NSData dataWithContentsOfURL:destination]isEqual:existing]);
    CHECK(([[NSJSONSerialization dataWithJSONObject:@{@"passed":@YES,@"cases":reports} options:NSJSONWritingPrettyPrinted error:nil]writeToFile:[directory stringByAppendingPathComponent:@"audio-only-validation.json"]atomically:YES]));
    puts("PASS audio-only AAC in Matroska/MP4/MPEG-TS, decoded PCM, gain/trim, track validation and atomic cancellation");
}
static void TestMediaTranscoding(NSString *directory,NSString *videoPath,BOOL hardware) {
    TestEffectSnapshotIsolation();NSString *source=MakeOffsetAVFixture(directory,videoPath);TestAudioOnlyTranscoding(directory,source,videoPath);TestSegmentFrameBoundaries(source);TestBurnedOverlayVariants(directory,videoPath);SGTranscodeAnalysis original=AnalyzeTranscode(source,NO);CHECK(isfinite(original.signalStart)&&original.signalStart>.2&&original.signalStart<.3);
    SGDecoderOptions *options=[SGDecoderOptions new];CHECK(options.padAudioToRangeStart);options.padAudioToRangeStart=NO;CHECK(![options.copy padAudioToRangeStart]);
    NSMutableArray *reports=[NSMutableArray array];NSArray *extensions=@[@"mkv",@"mp4",@"ts"];
    for(int kernel=0;kernel<2;kernel++)for(int container=0;container<3;container++){
        SGTranscodeConfiguration *config=[SGTranscodeConfiguration new];config.container=container;config.maximumDimension=32;config.maximumFramesPerSecond=15;config.videoBitRate=200000;
        SGMediaEffects *effects=[SGMediaEffects new];effects.kernel=kernel;SGFilterConfiguration *filter=[SGFilterConfiguration new];filter.grayscale=YES;effects.filter=filter;
        SGWatermark *mark=[SGWatermark new];mark.image=[[CIImage imageWithColor:[CIColor colorWithRed:1 green:0 blue:0]]imageByCroppingToRect:CGRectMake(0,0,2,2)];mark.rect=CGRectMake(0,0,.25,.25);mark.opacity=1;effects.watermarks=@[mark];
        NSString *path=[directory stringByAppendingPathComponent:[NSString stringWithFormat:@"transcoded-%d-%d.%@",kernel,container,extensions[container]]];SGMediaTranscoder *exporter=[SGMediaTranscoder new];NSError *error=nil;
        CHECK([exporter transcodeURL:[NSURL fileURLWithPath:source] toURL:[NSURL fileURLWithPath:path] configuration:config range:CMTimeRangeMake(kCMTimeZero,CMTimeMake(3,2)) effects:effects error:&error]);
        CHECK(exporter.videoFrameCount>=20&&exporter.videoFrameCount<=24&&exporter.audioSampleCount>40000&&CMTIMERANGE_IS_VALID(exporter.actualRange));
        SGTranscodeAnalysis result=AnalyzeTranscode(path,YES);CHECK(result.videos==exporter.videoFrameCount&&result.audios>20&&result.width==32&&result.height==24);CHECK(result.red>=6&&result.neutral>32*24/2);
        CHECK(result.quietSamples>1000&&result.toneSamples>1000);CHECK(sqrt(result.quietEnergy/result.quietSamples)<.01&&sqrt(result.toneEnergy/result.toneSamples)>.05);CHECK(fabs(result.signalStart-original.signalStart)<.03);
        [reports addObject:@{@"kernel":@(kernel),@"container":extensions[container],@"videoFrames":@(result.videos),@"audioFrames":@(result.audios),@"signalOnsetSeconds":@(result.signalStart),@"sourceSignalOnsetSeconds":@(original.signalStart),@"watermarkPixels":@(result.red),@"neutralPixels":@(result.neutral)}];
        NSData *existing=[NSData dataWithContentsOfFile:path];CHECK(![exporter transcodeURL:[NSURL fileURLWithPath:source] toURL:[NSURL fileURLWithPath:path] configuration:config range:CMTimeRangeMake(kCMTimeZero,CMTimeMake(1,1)) effects:nil error:&error]);CHECK([[NSData dataWithContentsOfFile:path]isEqual:existing]);
    }
    NSString *output=[directory stringByAppendingPathComponent:@"atomic-transcode.mp4"];NSData *sentinel=[@"Keep existing destination" dataUsingEncoding:NSUTF8StringEncoding];CHECK([sentinel writeToFile:output atomically:YES]);NSURL *destination=[NSURL fileURLWithPath:output];NSError *error=nil;SGTranscodeConfiguration *config=[SGTranscodeConfiguration new];config.maximumDimension=64;
    SGMediaTranscoder *cancelled=[SGMediaTranscoder new];[cancelled cancel];CHECK(![cancelled transcodeURL:[NSURL fileURLWithPath:source] toURL:destination configuration:config range:CMTimeRangeMake(kCMTimeZero,CMTimeMake(1,1)) effects:nil error:&error]);CHECK([[NSData dataWithContentsOfFile:output]isEqual:sentinel]);
    SGMediaTranscoder *midway=[SGMediaTranscoder new];__weak SGMediaTranscoder *weakMidway=midway;midway.progress=^(double fraction){if(fraction>.1)[weakMidway cancel];};CHECK(![midway transcodeURL:[NSURL fileURLWithPath:source] toURL:destination configuration:config range:CMTimeRangeMake(kCMTimeZero,CMTimeMake(1,1)) effects:nil error:&error]);CHECK([[NSData dataWithContentsOfFile:output]isEqual:sentinel]);
    SGMediaTranscoder *deadline=[SGMediaTranscoder new];deadline.maximumWallTime=1;__block BOOL delayed=NO;deadline.progress=^(double fraction){if(!delayed){delayed=YES;usleep(1200000);}};CHECK(![deadline transcodeURL:[NSURL fileURLWithPath:source] toURL:destination configuration:config range:CMTimeRangeMake(kCMTimeZero,CMTimeMake(1,1)) effects:nil error:&error]);CHECK([[NSData dataWithContentsOfFile:output]isEqual:sentinel]);
    SGMediaTranscoder *past=[SGMediaTranscoder new];CHECK(![past transcodeURL:[NSURL fileURLWithPath:source] toURL:destination configuration:config range:CMTimeRangeMake(CMTimeMake(100,1),CMTimeMake(1,1)) effects:nil error:&error]);CHECK([[NSData dataWithContentsOfFile:output]isEqual:sentinel]);
    config.audioGain=NAN;CHECK(![config validate:&error]);config.audioGain=1;
    SGMediaTranscoder *trim=[SGMediaTranscoder new];NSString *trimmed=[directory stringByAppendingPathComponent:@"trimmed-transcode.mp4"];CHECK([trim transcodeURL:[NSURL fileURLWithPath:source] toURL:[NSURL fileURLWithPath:trimmed] configuration:config range:CMTimeRangeMake(CMTimeMake(7,10),CMTimeMake(1,2)) effects:nil error:&error]);SGTranscodeAnalysis cut=AnalyzeTranscode(trimmed,NO);CHECK(cut.videos==15&&cut.audios>10&&CMTimeGetSeconds(trim.actualRange.duration)<=.501);
    NSString *hdr=[directory stringByAppendingPathComponent:@"marked-hdr.mkv"];CopyVideoWithMetadata(videoPath,hdr,NO,YES,NO);SGMediaTranscoder *reject=[SGMediaTranscoder new];CHECK(![reject transcodeURL:[NSURL fileURLWithPath:hdr] toURL:destination configuration:config range:CMTimeRangeMake(kCMTimeZero,CMTimeMake(1,1)) effects:nil error:&error]);CHECK([[NSData dataWithContentsOfFile:output]isEqual:sentinel]);
    NSString *orientation=[[@(__FILE__) stringByDeletingLastPathComponent]stringByAppendingPathComponent:@"fixtures/orientation.mp4"],*rotated=[directory stringByAppendingPathComponent:@"rotate-source.mp4"],*baked=[directory stringByAppendingPathComponent:@"rotate-baked.mp4"];
    CGSize dimensions=CopyVideoWithMetadata(orientation,rotated,YES,NO,NO);config.maximumDimension=3840;config.includeAudio=NO;SGMediaTranscoder *rotate=[SGMediaTranscoder new];CHECK([rotate transcodeURL:[NSURL fileURLWithPath:rotated] toURL:[NSURL fileURLWithPath:baked] configuration:config range:CMTimeRangeMake(kCMTimeZero,CMTimeMake(1,5)) effects:nil error:&error]);SGTranscodeAnalysis rotatedOutput=AnalyzeTranscode(baked,YES);CHECK(rotatedOutput.width==(int)dimensions.height&&rotatedOutput.height==(int)dimensions.width);CHECK(rotatedOutput.leftDifference< -80&&rotatedOutput.rightDifference>80);
    NSString *wideSource=[directory stringByAppendingPathComponent:@"wide-pixel-source.mp4"],*wideResult=[directory stringByAppendingPathComponent:@"wide-pixel-baked.mp4"];
    CGSize encodedSize=CopyVideoWithMetadata(orientation,wideSource,NO,NO,YES);config.videoCodec=SGTranscodeVideoCodecMPEG4;config.includeAudio=NO;config.maximumDimension=3840;
    SGMediaTranscoder *wide=[SGMediaTranscoder new];CHECK([wide transcodeURL:[NSURL fileURLWithPath:wideSource] toURL:[NSURL fileURLWithPath:wideResult] configuration:config range:CMTimeRangeMake(kCMTimeZero,CMTimeMake(1,5)) effects:nil error:&error]);SGTranscodeAnalysis wideOutput=AnalyzeTranscode(wideResult,YES);CHECK(wideOutput.width==(int)encodedSize.width*2&&wideOutput.height==(int)encodedSize.height);CHECK(wideOutput.red>wideOutput.width*wideOutput.height*.35&&wideOutput.neutral<wideOutput.width*wideOutput.height*.1);
    if(hardware)for(int codec=1;codec<=2;codec++)for(int container=0;container<3;container++){
        config.includeAudio=YES;config.videoCodec=codec;config.container=container;config.maximumDimension=64;
        NSString *suffix=@[@"mkv",@"mp4",@"ts"][container];NSString *path=[directory stringByAppendingPathComponent:[NSString stringWithFormat:@"hardware-transcode-%d.%@",codec,suffix]];
        SGMediaTranscoder *encoder=[SGMediaTranscoder new];CHECK([encoder transcodeURL:[NSURL fileURLWithPath:source] toURL:[NSURL fileURLWithPath:path] configuration:config range:CMTimeRangeMake(kCMTimeZero,CMTimeMake(1,1)) effects:nil error:&error]);SGTranscodeAnalysis result=AnalyzeTranscode(path,NO);CHECK(result.videos>20&&result.audios>10);CHECK(fabs(result.signalStart-.25)<.03);
    }

    NSData *record=[NSJSONSerialization dataWithJSONObject:@{@"passed":@YES,@"cases":reports} options:NSJSONWritingPrettyPrinted error:nil];CHECK([record writeToFile:[directory stringByAppendingPathComponent:@"transcode-validation.json"] atomically:YES]);
    puts("PASS both effect kernels burn grayscale/watermark in three containers; AAC timing/PCM, VFR cap, trimming, display-matrix orientation, hardware encoding and atomic failure/cancel/deadline checks");
}
