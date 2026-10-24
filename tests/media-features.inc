#import "SGMediaEffects.h"
#import "SGPlayer.h"
#import <ImageIO/ImageIO.h>
#import <CoreText/CoreText.h>
#import "SGDecodeLoop.h"
#import "SGFrameOutput.h"
#import "SGPlayerItem+Internal.h"

@interface SGFrameOutput (CapacityRegression)
- (void)decodeLoop:(SGDecodeLoop *)loop didChangeCapacity:(SGCapacity)capacity;
@end
@interface SGPlayerItem (CapacityRegression)
- (void)frameOutput:(SGFrameOutput *)output didChangeCapacity:(SGCapacity)capacity type:(SGMediaType)type;
@end
static void TestStaleCapacityEvents(NSString *videoPath)
{
    SGAsset *asset=[SGAsset assetWithURL:[NSURL fileURLWithPath:videoPath]];
    SGFrameOutput *output=[[SGFrameOutput alloc]initWithAsset:asset];
    SGDecodeLoop *decoder=[output valueForKey:@"videoDecoder"];
    SGCapacity stale=SGCapacityCreate();stale.count=1;stale.size=100;stale.duration=CMTimeMake(1,30);
    // Simulate a delayed nonempty callback after the real decoder drained.
    [output decodeLoop:decoder didChangeCapacity:stale];
    CHECK(SGCapacityIsEmpty([output capacityWithType:SGMediaTypeVideo]));
    SGPlayerItem *item=[[SGPlayerItem alloc]initWithAsset:asset];
    [item frameOutput:output didChangeCapacity:stale type:SGMediaTypeVideo];
    CHECK(SGCapacityIsEmpty([item capacityWithType:SGMediaTypeVideo]));
}

static NSData *FeaturePixels(SGMediaEffects *effects, CIImage *image, double time)
{
    CVPixelBufferRef output = [effects copyPixelBufferForImage:image atTime:CMTimeMakeWithSeconds(time,1000)];
    CHECK(output != NULL);
    CHECK(CVPixelBufferLockBaseAddress(output,kCVPixelBufferLock_ReadOnly) == kCVReturnSuccess);
    NSData *data = [NSData dataWithBytes:CVPixelBufferGetBaseAddress(output) length:CVPixelBufferGetBytesPerRow(output)*CVPixelBufferGetHeight(output)];
    CVPixelBufferUnlockBaseAddress(output,kCVPixelBufferLock_ReadOnly); CVPixelBufferRelease(output); return data;
}
// Generate a real multi-track Matroska file, including an encoded bitmap event.
static NSString *MakeSubtitleFixture(NSString *directory, NSString *header)
{
    NSString *path=[directory stringByAppendingPathComponent:@"multi-subtitles.mks"];
    AVFormatContext *mux=NULL;
    CHECK(avformat_alloc_output_context2(&mux,NULL,"matroska",path.fileSystemRepresentation)>=0);
    const AVCodec *codec=avcodec_find_encoder(AV_CODEC_ID_DVD_SUBTITLE);CHECK(codec);
    AVCodecContext *encoder=avcodec_alloc_context3(codec);CHECK(encoder);
    encoder->width=320;encoder->height=180;encoder->time_base=(AVRational){1,1000};
    CHECK(avcodec_open2(encoder,codec,NULL)>=0);
    for(int i=0;i<3;i++) {
        AVStream *stream=avformat_new_stream(mux,NULL);CHECK(stream);stream->time_base=(AVRational){1,1000};
        if(i==2)CHECK(avcodec_parameters_from_context(stream->codecpar,encoder)>=0);
        else {
            stream->codecpar->codec_type=AVMEDIA_TYPE_SUBTITLE;stream->codecpar->codec_id=AV_CODEC_ID_ASS;
            NSData *bytes=[header dataUsingEncoding:NSUTF8StringEncoding];
            stream->codecpar->extradata=av_mallocz(bytes.length+AV_INPUT_BUFFER_PADDING_SIZE);CHECK(stream->codecpar->extradata);
            memcpy(stream->codecpar->extradata,bytes.bytes,bytes.length);stream->codecpar->extradata_size=(int)bytes.length;
        }
        av_dict_set(&stream->metadata,"language",i==0?"eng":i==1?"zho":"und",0);
        av_dict_set(&stream->metadata,"title",i==0?"English":i==1?"Chinese":"Bitmap",0);
        stream->disposition=i==0?AV_DISPOSITION_DEFAULT:i==1?AV_DISPOSITION_FORCED:0;
    }
    CTFontRef font=CTFontCreateWithName(CFSTR("Helvetica"),12,NULL);
    NSURL *fontURL=CFBridgingRelease(CTFontCopyAttribute(font,kCTFontURLAttribute));CFRelease(font);
    NSData *fontData=[NSData dataWithContentsOfURL:fontURL];CHECK(fontData.length>0);
    AVStream *attachment=avformat_new_stream(mux,NULL);CHECK(attachment);
    attachment->codecpar->codec_type=AVMEDIA_TYPE_ATTACHMENT;attachment->codecpar->codec_id=AV_CODEC_ID_TTF;
    attachment->codecpar->extradata=av_mallocz(fontData.length+AV_INPUT_BUFFER_PADDING_SIZE);CHECK(attachment->codecpar->extradata);
    memcpy(attachment->codecpar->extradata,fontData.bytes,fontData.length);attachment->codecpar->extradata_size=(int)fontData.length;
    av_dict_set(&attachment->metadata,"filename",fontURL.lastPathComponent.UTF8String,0);
    av_dict_set(&attachment->metadata,"mimetype","application/x-truetype-font",0);
    CHECK(avio_open(&mux->pb,path.fileSystemRepresentation,AVIO_FLAG_WRITE)>=0);CHECK(avformat_write_header(mux,NULL)>=0);
    for(int i=0;i<2;i++) {
        const char *event=i==0?"0,0,Default,,0,0,0,,Embedded English":"0,0,Default,,0,0,0,,Embedded Chinese";
        AVPacket *packet=av_packet_alloc();CHECK(packet);CHECK(av_new_packet(packet,(int)strlen(event))>=0);
        memcpy(packet->data,event,packet->size);packet->stream_index=i;packet->pts=packet->dts=1000;packet->duration=2000;
        CHECK(av_interleaved_write_frame(mux,packet)>=0);av_packet_free(&packet);
    }
    uint8_t indices[40*12];memset(indices,1,sizeof(indices));
    uint32_t palette[4]={0,0xffffffff,0xff000000,0xffff0000};
    AVSubtitleRect rectangle={0};rectangle.type=SUBTITLE_BITMAP;rectangle.x=30;rectangle.y=130;rectangle.w=40;rectangle.h=12;
    rectangle.nb_colors=4;rectangle.data[0]=indices;rectangle.data[1]=(uint8_t *)palette;rectangle.linesize[0]=40;
    AVSubtitleRect *rectangles[]={&rectangle};AVSubtitle subtitle={0};subtitle.num_rects=1;subtitle.rects=rectangles;subtitle.end_display_time=2000;
    AVPacket *packet=av_packet_alloc();CHECK(packet);CHECK(av_new_packet(packet,65536)>=0);
    int size=avcodec_encode_subtitle(encoder,packet->data,packet->size,&subtitle);CHECK(size>0);av_shrink_packet(packet,size);
    packet->stream_index=2;packet->pts=packet->dts=1000;packet->duration=2000;
    CHECK(av_interleaved_write_frame(mux,packet)>=0);av_packet_free(&packet);
    CHECK(av_write_trailer(mux)>=0);avio_closep(&mux->pb);avformat_free_context(mux);avcodec_free_context(&encoder);
    return path;
}

static void TestMediaFeatures(NSString *directory, NSString *videoPath)
{
    [NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil];
    NSMutableArray *checks = [NSMutableArray array];
    TestStaleCapacityEvents(videoPath);
    [checks addObject:@"Delayed nonempty capacity callbacks cannot overwrite drained decoder/item state"];
    for (int i=0;i<30;i++) {
        @autoreleasepool {
            SGPlayer *player=[[SGPlayer alloc]init];
            [player replaceWithURL:[NSURL fileURLWithPath:videoPath]];
            [player replaceWithPlayerItem:nil];
        }
    }
    [checks addObject:@"Thirty immediate open/close cycles without main-thread/demux join deadlock"];
    NSMutableData *bytes = [NSMutableData dataWithLength:320*180*4];
    uint8_t *pixels = bytes.mutableBytes;
    for (int y=0;y<180;y++) for(int x=0;x<320;x++){int i=(y*320+x)*4;pixels[i]=x%256;pixels[i+1]=y;pixels[i+2]=220;pixels[i+3]=255;}
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CIImage *image = [CIImage imageWithBitmapData:bytes bytesPerRow:320*4 size:CGSizeMake(320,180) format:kCIFormatRGBA8 colorSpace:space];
    CGColorSpaceRelease(space);
    for (SGPlaybackKernel kernel=SGPlaybackKernelFFmpeg;kernel<=SGPlaybackKernelNative;kernel++) {
        SGMediaEffects *effects = [[SGMediaEffects alloc] init];effects.kernel=kernel;
        NSData *baseline=FeaturePixels(effects,image,0);
        SGFilterConfiguration *config=[[SGFilterConfiguration alloc] init];config.grayscale=YES;effects.filter=config;
        NSData *gray=FeaturePixels(effects,image,0);CHECK(![gray isEqual:baseline]);
        const uint8_t *p=gray.bytes;
        for (int i=0;i<320*180;i++) {CHECK(abs(p[i*4]-p[i*4+1])<4);CHECK(abs(p[i*4+1]-p[i*4+2])<4);}
        config=[[SGFilterConfiguration alloc] init];config.horizontalFlip=YES;effects.filter=config;
        NSData *flip=FeaturePixels(effects,image,0);CHECK(![flip isEqual:baseline]);
        config=[[SGFilterConfiguration alloc] init];config.brightness=0.2;config.contrast=1.3;config.saturation=0.6;config.blurRadius=2;effects.filter=config;
        CHECK(![FeaturePixels(effects,image,0) isEqual:baseline]);
        float curve[17*3];for(int j=0;j<17;j++)for(int channel=0;channel<3;channel++)curve[j*3+channel]=1.0-j/16.0;
        config=[[SGFilterConfiguration alloc]init];config.colorCurves=[NSData dataWithBytes:curve length:sizeof(curve)];effects.filter=config;
        CHECK(![FeaturePixels(effects,image,0) isEqual:baseline]);
        // A constant cube is a strong oracle: every input color must become red in both backends.
        NSString *cube=@"TITLE \"constant red\"\nLUT_3D_SIZE 2\nDOMAIN_MIN 0 0 0\nDOMAIN_MAX 1 1 1\n1 0 0\n1 0 0\n1 0 0\n1 0 0\n1 0 0\n1 0 0\n1 0 0\n1 0 0\n";
        NSError *cubeError=nil;config=[SGFilterConfiguration configurationWithCubeText:cube error:&cubeError];CHECK(config&&!cubeError);effects.filter=config;
        NSData *red=FeaturePixels(effects,image,0);const uint8_t *redBytes=red.bytes;
        for(int pixel=0;pixel<320*180;pixel++){CHECK(redBytes[pixel*4]<8);CHECK(redBytes[pixel*4+1]<8);CHECK(redBytes[pixel*4+2]>245);}
        CHECK(![SGFilterConfiguration configurationWithCubeText:@"LUT_3D_SIZE 64\n1 0 0\n" error:&cubeError]);
        config=[SGFilterConfiguration new];config.bloomIntensity=.5;config.bloomRadius=3;effects.filter=config;
        CHECK(![FeaturePixels(effects,image,0) isEqual:baseline]);
        config.brightness=NAN;effects.filter=config;CHECK([effects composeImage:image atTime:kCMTimeZero]==nil);CHECK(effects.lastError!=nil);
        effects.filter=[[SGFilterConfiguration alloc] init];CHECK([FeaturePixels(effects,image,0) isEqual:baseline]);
        [checks addObject:kernel==SGPlaybackKernelFFmpeg?@"FFmpeg filter graph pixels, flips, grayscale, combined controls and invalid-parameter errors":@"Native Core Image filter pixels and validation"];
    }
    NSString *srt=@"1\n00:00:01,000 --> 00:00:03,000\nHello 字幕\n\n2\n00:00:04,000 --> 00:00:05,000\nSecond line\n";
    NSString *srtPath=[directory stringByAppendingPathComponent:@"test.srt"];
    CHECK([srt writeToFile:srtPath atomically:YES encoding:NSUTF8StringEncoding error:nil]);
    NSError *error=nil;NSArray *tracks=[SGSubtitleReader readURL:[NSURL fileURLWithPath:srtPath] error:&error];
    CHECK(error==nil && tracks.count==1);
    SGSubtitleTrack *track=tracks.firstObject;CHECK(track.cues.count==2);
    CHECK([track.cues[0].text containsString:@"Hello"]);CHECK(fabs(CMTimeGetSeconds(track.cues[0].start)-1)<0.01);
    SGMediaEffects *effects=[[SGMediaEffects alloc] init];effects.subtitles=track.cues;
    NSData *before=FeaturePixels(effects,image,0),*active=FeaturePixels(effects,image,2),*after=FeaturePixels(effects,image,3.5);
    CHECK(![before isEqual:active]);CHECK([before isEqual:after]);
    effects.subtitlesEnabled=NO;CHECK([before isEqual:FeaturePixels(effects,image,2)]);
    effects.subtitlesEnabled=YES;effects.subtitleOffset=1;CHECK([before isEqual:FeaturePixels(effects,image,1.5)]);
    CHECK(![before isEqual:FeaturePixels(effects,image,2.5)]);
    effects.subtitles=@[];
    SGSubtitleTrack *second=[SGSubtitleTrack new];SGSubtitleCue *secondCue=[SGSubtitleCue new];secondCue.start=CMTimeMake(1,1);secondCue.duration=CMTimeMake(2,1);secondCue.text=@"Second track";second.cues=@[secondCue];
    effects.secondarySubtitleTrack=second;
    NSData *secondaryOnly=FeaturePixels(effects,image,2);CHECK(![before isEqual:secondaryOnly]);
    effects.subtitles=track.cues;effects.subtitleOffset=0;
    NSData *dual=FeaturePixels(effects,image,2);CHECK(![dual isEqual:secondaryOnly]&&![dual isEqual:active]);
    effects.secondarySubtitleOffset=2;CHECK([FeaturePixels(effects,image,2) isEqual:active]);
    effects.secondarySubtitleTrack=nil;effects.subtitles=@[];effects.secondarySubtitleOffset=0;
    [checks addObject:@"Dual independent subtitle timing/position; true 3D cube red-pixel oracle and Bloom in both kernels"];
    SGDanmakuItem *event=[[SGDanmakuItem alloc] init];event.start=kCMTimeZero;event.text=@"Danmaku 弹幕";event.duration=5;
    effects.danmaku=@[event];
    NSData *position1=FeaturePixels(effects,image,1),*position2=FeaturePixels(effects,image,2);
    CHECK(![position1 isEqual:position2]);CHECK([position1 isEqual:FeaturePixels(effects,image,1)]);
    effects.danmakuEnabled=NO;CHECK([before isEqual:FeaturePixels(effects,image,1)]);
    effects.danmaku=@[];
    SGWatermark *mark=[[SGWatermark alloc] init];mark.text=@"Watermark 水印";effects.watermarks=@[mark];
    CHECK(![before isEqual:FeaturePixels(effects,image,1)]);
    mark.opacity=0;CHECK([before isEqual:FeaturePixels(effects,image,1)]);
    effects.watermarks=@[];
    [checks addObject:@"SRT decoding, cue boundaries, visibility, offset, deterministic danmaku seek and watermark opacity"];
    NSString *vttPath=[directory stringByAppendingPathComponent:@"test.vtt"];
    CHECK([@"WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nWebVTT text\n" writeToFile:vttPath atomically:YES encoding:NSUTF8StringEncoding error:nil]);
    tracks=[SGSubtitleReader readURL:[NSURL fileURLWithPath:vttPath] error:&error];CHECK(tracks.count==1 && ((SGSubtitleTrack *)tracks[0]).cues.count==1);
    [checks addObject:@"WebVTT decoder"];
    NSString *assPath=[directory stringByAppendingPathComponent:@"styled.ass"];
    NSString *ass=@"[Script Info]\nScriptType: v4.00+\nPlayResX: 320\nPlayResY: 180\n[V4+ Styles]\nFormat: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding\nStyle: Default,Helvetica,24,&H000000FF,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,2,0,2,0,0,0,1\n[Events]\nFormat: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\nDialogue: 0,0:00:01.00,0:00:03.00,Default,,0,0,0,,{\\pos(80,60)\\bord2\\1c&H00FF00&}Styled 字幕\n";
    CHECK([ass writeToFile:assPath atomically:YES encoding:NSUTF8StringEncoding error:nil]);
    error=nil;tracks=[SGSubtitleReader readURL:[NSURL fileURLWithPath:assPath] error:&error];
    CHECK(!error && tracks.count==1);SGSubtitleTrack *styled=tracks[0];CHECK(styled.ASSHeader.length>0 && styled.cues.count==1);
    effects.subtitleFallbackFontURL=[NSURL fileURLWithPath:[[@(__FILE__) stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"../SGPlayer/Resources/Fonts/NotoSansCJKsc-Regular.otf"]];
    effects.subtitleTrack=styled;effects.subtitles=styled.cues;
    NSData *styledPixels=FeaturePixels(effects,image,2);CHECK(![styledPixels isEqual:before]);
    const uint8_t *styledBytes=styledPixels.bytes;NSUInteger green=0;
    for(NSUInteger i=0;i<320*180;i++)if(styledBytes[i*4+1]>200 && styledBytes[i*4]<100 && styledBytes[i*4+2]<100)green++;
    CHECK(green>10);CHECK([FeaturePixels(effects,image,0) isEqual:before]);
    SGSubtitleTrack *vectorTrack=[[SGSubtitleTrack alloc]init];vectorTrack.ASSHeader=styled.ASSHeader;
    SGSubtitleCue *vector=[[SGSubtitleCue alloc]init];vector.start=CMTimeMake(1,1);vector.duration=CMTimeMake(2,1);
    vector.ASS=@"0,0,Default,,0,0,0,,{\\an7\\pos(20,20)\\p1\\bord0\\shad0\\1c&H00FF00&}m 0 0 l 20 0 20 4 4 4 4 20 0 20";
    vectorTrack.cues=@[vector];effects.subtitleTrack=vectorTrack;effects.subtitles=vectorTrack.cues;
    CIImage *black=[[CIImage imageWithColor:[CIColor colorWithRed:0 green:0 blue:0]]imageByCroppingToRect:CGRectMake(0,0,320,180)];
    NSData *shape=FeaturePixels(effects,black,2);const uint8_t *shapePixels=shape.bytes;
    // The upper horizontal stroke of this asymmetric L is above its open area.
    CHECK(shapePixels[(22*320+30)*4+1]>200);
    CHECK(shapePixels[(37*320+30)*4+1]<20);
    [checks addObject:@"Asymmetric ASS vector verifies upright orientation and top-left placement"];
    NSString *embeddedPath=MakeSubtitleFixture(directory,[[ass componentsSeparatedByString:@"Dialogue:"] firstObject]);
    error=nil;NSArray<SGSubtitleTrack *> *embedded=[SGSubtitleReader readURL:[NSURL fileURLWithPath:embeddedPath] error:&error];
    CHECK(!error && embedded.count==3);
    CHECK(embedded[0].fonts.count==1 && embedded[0].fonts.allValues.firstObject.length>0);
    CHECK(embedded[0].defaultTrack && [embedded[0].language isEqual:@"eng"]);
    CHECK(embedded[1].forced && [embedded[1].language isEqual:@"zho"]);
    CHECK(embedded[0].cues.count==1 && [embedded[0].cues[0].text containsString:@"English"]);
    CHECK(embedded[1].cues.count==1 && [embedded[1].cues[0].text containsString:@"Chinese"]);
    CHECK(embedded[2].cues.count==1 && embedded[2].cues[0].bitmap);
    CHECK(fabs(embedded[2].cues[0].region.origin.x-30.0/320)<0.01);
    CHECK(fabs(embedded[2].cues[0].region.origin.y-130.0/180)<0.01);
    // All AVFormatContext and decoder state was freed before these cues render.
    effects.subtitleTrack=embedded[2];effects.subtitles=embedded[2].cues;
    CHECK(![FeaturePixels(effects,image,2) isEqual:before]);CHECK([FeaturePixels(effects,image,0) isEqual:before]);
    [checks addObject:@"Embedded Matroska ASS multi-track language/default/forced metadata, attached font ownership and real DVD bitmap subtitle palette/placement/lifetime"];
    effects.subtitleTrack=nil;effects.subtitles=@[];
    [checks addObject:@"Real libass font rendering, ASS position/outline/color overrides and cue timing"];
    NSURL *gif=[NSURL fileURLWithPath:[directory stringByAppendingPathComponent:@"export.gif"]];
    effects.watermarks=@[mark];mark.opacity=1;
    NSData *oldGIF=[@"previous-complete-file" dataUsingEncoding:NSUTF8StringEncoding];CHECK([oldGIF writeToURL:gif atomically:YES]);
    NSFileHandle *previousReader=[NSFileHandle fileHandleForReadingFromURL:gif error:&error];CHECK(previousReader);
    SGGIFExporter *exporter=[[SGGIFExporter alloc] init];
    CHECK([exporter exportURL:[NSURL fileURLWithPath:videoPath] toURL:gif range:CMTimeRangeMake(kCMTimeZero,CMTimeMake(1,1)) framesPerSecond:10 maximumDimension:128 effects:effects error:&error]);
    CHECK([[previousReader readDataToEndOfFile]isEqual:oldGIF]);[previousReader closeFile];
    CGImageSourceRef source=CGImageSourceCreateWithURL((__bridge CFURLRef)gif,NULL);CHECK(source && CGImageSourceGetCount(source)==10);CFRelease(source);
    SGAnimatedImage *animation=[SGAnimatedImage imageWithURL:gif maxDecodedBytes:8*1024*1024 error:&error];CHECK(animation && animation.frameCount==10);CHECK(fabs(animation.duration-1)<0.05);CHECK([animation imageAtTime:0.1]!=nil);
    CHECK([SGAnimatedImage imageWithURL:gif maxDecodedBytes:1 error:&error]==nil);
    [exporter cancel];CHECK(![exporter exportURL:[NSURL fileURLWithPath:videoPath] toURL:gif range:CMTimeRangeMake(kCMTimeZero,CMTimeMake(1,1)) framesPerSecond:10 maximumDimension:128 effects:nil error:&error]);
    CHECK(error.code==NSUserCancelledError);
    NSData *existing=[NSData dataWithContentsOfURL:gif];
    SGGIFExporter *cancelled=[[SGGIFExporter alloc]init];
    __weak SGGIFExporter *weakExporter=cancelled;
    cancelled.progress=^(double progress){if(progress>0)[weakExporter cancel];};
    error=nil;CHECK(![cancelled exportURL:[NSURL fileURLWithPath:videoPath] toURL:gif range:CMTimeRangeMake(kCMTimeZero,CMTimeMake(1,1)) framesPerSecond:10 maximumDimension:128 effects:nil error:&error]);
    CHECK(error.code==NSUserCancelledError && [existing isEqual:[NSData dataWithContentsOfURL:gif]]);
    SGGIFExporter *pastEnd=[[SGGIFExporter alloc]init];error=nil;
    CHECK(![pastEnd exportURL:[NSURL fileURLWithPath:videoPath] toURL:gif range:CMTimeRangeMake(CMTimeMake(1000,1),CMTimeMake(1,1)) framesPerSecond:10 maximumDimension:128 effects:nil error:&error]);
    CHECK(error && [existing isEqual:[NSData dataWithContentsOfURL:gif]]);
    [checks addObject:@"In-progress GIF cancellation and past-EOF failure preserve the previous output atomically"];
    [checks addObject:@"Independent GIF export, watermark composition, frame count/delays, animation budget and cancellation"];
    NSDictionary *report=@{@"passed":@YES,@"checks":checks,@"platform":NSProcessInfo.processInfo.operatingSystemVersionString};
    CHECK([[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil] writeToFile:[directory stringByAppendingPathComponent:@"results.json"] atomically:YES]);
    puts("PASS media features pixel/data/export regression");
}
