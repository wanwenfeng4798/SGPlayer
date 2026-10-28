#import "SGPlaybackSession.h"
#import "SGTimelinePreview.h"
#import "SGMediaCache.h"
#import "SGPlaybackControls.h"
@interface SGFrameReader (AbortRegression)
- (BOOL)demuxableShouldAbortBlockingFunctions:(id<SGDemuxable>)demuxable;
@end
@interface SGReaderAbortProbe : NSObject <SGFrameReaderDelegate>
@property NSUInteger calls;
@end
@implementation SGReaderAbortProbe
- (BOOL)frameReaderShouldAbortBlockingFunctions:(SGFrameReader *)reader {self.calls++;return YES;}
@end

// Deterministic backend boundary: policies must remain correct when completions arrive after user input.
@interface SGSessionTestController : SGPlaybackController
@property BOOL testPlaying;
@property NSUInteger testFrames;
@property SGPlaybackKernel testKernel;
@property CMTime testTime;
@property CMTime testDuration;
@property NSError *testError;
@property NSMutableArray<NSURL *> *openedURLs;
@property NSUInteger resets;
@property BOOL failOpen;
@property BOOL deferCompletion;
@property (copy) void (^pendingCompletion)(BOOL);
@end
@implementation SGSessionTestController
- (instancetype)init {if((self=[super init])){_testKernel=SGPlaybackKernelNative;_testTime=kCMTimeZero;_testDuration=CMTimeMake(30,1);_openedURLs=[NSMutableArray array];}return self;}
- (BOOL)playing {return self.testPlaying;}
- (NSUInteger)presentedFrameCount {return self.testFrames;}
- (SGPlaybackKernel)kernel {return self.testKernel;}
- (CMTime)currentTime {return self.testTime;}
- (CMTime)duration {return self.testDuration;}
- (NSError *)error {return self.testError;}
- (void)play {self.testPlaying=YES;}
- (void)pause {self.testPlaying=NO;}
- (void)resetToKernel:(SGPlaybackKernel)kernel {self.resets++;self.testKernel=kernel;self.testError=nil;self.testTime=kCMTimeInvalid;}
- (void)replaceWithURL:(NSURL *)URL atTime:(CMTime)time completion:(void (^)(BOOL))completion {
    [self.openedURLs addObject:URL];self.testTime=time;
    self.testError=self.failOpen?[NSError errorWithDomain:@"SGPlayer-Error-FFmpeg" code:AVERROR_INVALIDDATA userInfo:nil]:nil;
    if(self.deferCompletion)self.pendingCompletion=completion;else completion(!self.failOpen);
}
- (void)replaceWithURL:(NSURL *)URL atTime:(CMTime)time preservingSubtitles:(BOOL)preserve completion:(void (^)(BOOL))completion { [self replaceWithURL:URL atTime:time completion:completion]; }
- (void)seekToTime:(CMTime)time completion:(void (^)(BOOL))completion {self.testTime=time;if(self.deferCompletion)self.pendingCompletion=completion;else completion(YES);}
- (void)switchToKernel:(SGPlaybackKernel)kernel completion:(void (^)(BOOL))completion {
    NSURL *URL=self.openedURLs.lastObject;CMTime time=self.testTime;[self resetToKernel:kernel];
    [self replaceWithURL:URL atTime:time completion:completion];
}
- (void)close {self.testPlaying=NO;}
@end
@interface SGPlaybackSession (PolicyTests)
- (void)tick;
@end
static SGPlaybackItem *SessionTestItem(NSString *identifier) {
    return [[SGPlaybackItem alloc]initWithIdentifier:identifier title:identifier renditions:@[
        [[SGPlaybackRendition alloc]initWithIdentifier:@"low" title:@"Low" URL:[NSURL URLWithString:@"https://user:secret@example.com/low.mp4?token=secret"]],
        [[SGPlaybackRendition alloc]initWithIdentifier:@"high" title:@"High" URL:[NSURL URLWithString:@"https://example.com/high.mp4"]]]];
}
static void TestMacKeyboardPolicies(void) {
    __weak SGPlaybackControls *released=nil;
    @autoreleasepool {
    SGSessionTestController *backend=[SGSessionTestController new];
    SGPlaybackSession *session=[[SGPlaybackSession alloc]initWithController:backend resumeStore:nil];session.kernelPolicy=SGKernelSelectionPolicyManual;CHECK([session loadItems:@[SessionTestItem(@"keys")] startIndex:0 autoPlay:YES error:nil]);
    SGPlaybackControls *controls=[[SGPlaybackControls alloc]initWithSession:session];
    NSEvent *(^key)(NSString *,unsigned short,NSEventModifierFlags,BOOL)=^NSEvent *(NSString *text,unsigned short code,NSEventModifierFlags flags,BOOL repeat){return [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:flags timestamp:0 windowNumber:0 context:nil characters:text charactersIgnoringModifiers:text isARepeat:repeat keyCode:code];};
    CHECK([controls handleKeyEvent:key(@" ",49,0,YES)]&&backend.playing);
    CHECK(![controls handleKeyEvent:key(@" ",49,NSEventModifierFlagCommand,NO)]&&backend.playing);
    CHECK([controls handleKeyEvent:key(@" ",49,0,NO)]&&!backend.playing);
    backend.testTime=CMTimeMake(5,1);CHECK([controls handleKeyEvent:key(@"",123,NSEventModifierFlagShift,NO)]&&CMTimeCompare(backend.currentTime,kCMTimeZero)==0);
    CHECK([controls handleKeyEvent:key(@"",124,NSEventModifierFlagShift,NO)]&&fabs(CMTimeGetSeconds(backend.currentTime)-29.9)<.001);
    backend.volume=.6;CHECK([controls handleKeyEvent:key(@"m",46,0,NO)]&&backend.volume==0);CHECK([controls handleKeyEvent:key(@"m",46,0,YES)]&&backend.volume==0);CHECK([controls handleKeyEvent:key(@"m",46,0,NO)]&&fabs(backend.volume-.6)<.001);
    backend.rate=1;NSEvent *layout=[NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:0 timestamp:0 windowNumber:0 context:nil characters:@"]" charactersIgnoringModifiers:@"l" isARepeat:NO keyCode:37];CHECK([controls handleKeyEvent:layout]&&backend.rate==1.25&&!controls.controlsLocked);
    backend.rate=4;CHECK([controls handleKeyEvent:key(@"]",30,0,NO)]&&backend.rate==4);backend.rate=.25;CHECK([controls handleKeyEvent:key(@"[",33,0,NO)]&&backend.rate==.25);
    __block NSUInteger full=0,dismiss=0;CHECK(![controls handleKeyEvent:key(@"f",3,0,NO)]);controls.toggleFullScreen=^{full++;};controls.dismissPresentation=^{dismiss++;};
    CHECK([controls handleKeyEvent:key(@"f",3,0,NO)]&&full==1);CHECK([controls handleKeyEvent:key(@"",53,0,NO)]&&dismiss==1&&full==1);
    CHECK([controls handleKeyEvent:key(@"l",37,0,NO)]&&controls.controlsLocked);CHECK([controls handleKeyEvent:key(@" ",49,0,NO)]&&!backend.playing);CHECK([controls handleKeyEvent:key(@"l",37,0,NO)]&&!controls.controlsLocked);
    backend.testTime=CMTimeMake(5,1);[session play];backend.testFrames=2;[session tick];CHECK(session.state==SGPlaybackSessionStatePlaying);[controls refresh];controls.autoHideInterval=.01;CFRunLoopRunInMode(kCFRunLoopDefaultMode,.03,false);[controls refresh];CHECK(controls.hidden);[controls revealControls];CHECK(!controls.hidden);
    NSSlider *slider=nil;for(NSView *view in controls.subviews)if([view isKindOfClass:NSSlider.class])slider=(NSSlider *)view;CHECK(slider);slider.doubleValue=.7;slider.cell.highlighted=YES;CFRunLoopRunInMode(kCFRunLoopDefaultMode,.03,false);[controls refresh];CHECK(!controls.hidden&&fabs(slider.doubleValue-.7)<.001);slider.cell.highlighted=NO;CFRunLoopRunInMode(kCFRunLoopDefaultMode,.03,false);[controls refresh];CHECK(controls.hidden);[controls revealControls];
    controls.controlsLocked=YES;CFRunLoopRunInMode(kCFRunLoopDefaultMode,.03,false);[controls refresh];CHECK(!controls.hidden);controls.controlsLocked=NO;[session pause];CFRunLoopRunInMode(kCFRunLoopDefaultMode,.03,false);[controls refresh];CHECK(!controls.hidden);controls.autoHideInterval=NAN;CHECK(controls.autoHideInterval==0);
    released=controls;[controls attachKeyboardToView:[NSView new]];controls=nil;[session close];
    }
    CHECK(!released);
    puts("PASS Mac keyboard modifiers/repeats/timeline bounds/mute/rate/lock/presentation and weak monitor lifetime");
}
static void TestPlaybackSessionPolicies(NSString *directory) {
    TestMacKeyboardPolicies();
    CHECK(NSThread.isMainThread);
    NSString *suite=[@"SGPlayer.tests." stringByAppendingString:NSUUID.UUID.UUIDString];
    NSUserDefaults *store=[[NSUserDefaults alloc]initWithSuiteName:suite];
    SGSessionTestController *backend=[SGSessionTestController new];
    SGPlaybackSession *session=[[SGPlaybackSession alloc]initWithController:backend resumeStore:store];session.kernelPolicy=SGKernelSelectionPolicyManual;
    SGPlaybackItem *first=SessionTestItem(@"first"),*second=SessionTestItem(@"second");NSError *error=nil;
    CHECK((![session loadItems:@[first,first] startIndex:0 autoPlay:NO error:&error] && error));
    CHECK(([session loadItems:@[first,second] startIndex:0 autoPlay:YES error:&error]));CHECK(backend.playing && session.selectedIndex==0);
    backend.testTime=CMTimeMake(12,1);[session saveResumePosition];
    CHECK([session next] && session.selectedIndex==1);CHECK([session previous]);CHECK(CMTimeCompare(backend.testTime,CMTimeMake(12,1))==0);
    __block BOOL switched=NO;[session selectRenditionAtIndex:1 completion:^(BOOL success){switched=success;}];
    CHECK(switched && session.selectedRendition==1 && CMTimeCompare(backend.testTime,CMTimeMake(12,1))==0);
    CHECK(![session setLoopFrom:CMTimeMake(5,1) to:CMTimeMake(4,1)]);
    CHECK(![session setLoopFrom:kCMTimeZero to:CMTimeMake(31,1)]);
    CHECK([session setLoopFrom:CMTimeMake(3,1) to:CMTimeMake(6,1)]);
    backend.testTime=CMTimeMake(6,1);[session tick];CHECK(CMTimeCompare(backend.testTime,CMTimeMake(3,1))==0);
    [session pause];backend.testTime=CMTimeMake(7,1);[session tick];CHECK(!backend.playing && CMTimeCompare(backend.testTime,CMTimeMake(7,1))==0);
    [session play];backend.deferCompletion=YES;backend.testTime=CMTimeMake(7,1);[session tick];CHECK(backend.pendingCompletion);
    [session pause];backend.pendingCompletion(YES);backend.pendingCompletion=nil;backend.deferCompletion=NO;CHECK(!backend.playing);
    [session clearLoop];session.loopMode=SGPlaybackLoopModeAll;CHECK([session selectItemAtIndex:1]);[session play];
    backend.testTime=backend.testDuration;[session tick];CHECK(session.selectedIndex==0 && backend.playing);
    session.kernelPolicy=SGKernelSelectionPolicyPreferFFmpeg;backend.failOpen=YES;
    CHECK([session selectItemAtIndex:0]);NSUInteger before=backend.openedURLs.count;
    [session tick];CHECK(backend.resets>=1 && backend.openedURLs.count==before+1);
    [session tick];[session tick];CHECK(session.state==SGPlaybackSessionStateFailed && backend.openedURLs.count==before+1);
    backend.failOpen=NO;[session retry];CHECK(session.state==SGPlaybackSessionStatePaused);
    // Transport errors must never trigger a second backend request.
    backend.testError=[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorNotConnectedToInternet userInfo:nil];
    before=backend.openedURLs.count;[session tick];CHECK(session.state==SGPlaybackSessionStateFailed&&backend.openedURLs.count==before);
    backend.testError=nil;[session retry];
    NSData *report=[NSJSONSerialization dataWithJSONObject:session.diagnostics options:0 error:&error];CHECK(report);
    NSString *reportText=[[NSString alloc]initWithData:report encoding:NSUTF8StringEncoding];CHECK(![reportText containsString:@"secret"] && ![reportText containsString:@"example.com"]);
    CHECK([session exportDiagnosticsToURL:[NSURL fileURLWithPath:[directory stringByAppendingPathComponent:@"session-diagnostics.json"]] error:&error]);
    // Superseded rendition completion cannot overwrite the selected item/error state.
    backend.deferCompletion=YES;[session selectRenditionAtIndex:1 completion:^(BOOL success){}];void (^stale)(BOOL)=[backend.pendingCompletion copy];
    CHECK([session selectItemAtIndex:1]);void (^current)(BOOL)=[backend.pendingCompletion copy];
    stale(NO);CHECK(session.selectedIndex==1 && session.state==SGPlaybackSessionStateLoading);current(YES);CHECK(session.error==nil);
    backend.pendingCompletion=nil;backend.deferCompletion=NO;
    SGSessionTestController *otherBackend=[SGSessionTestController new];SGPlaybackSession *other=[[SGPlaybackSession alloc]initWithController:otherBackend resumeStore:nil];other.kernelPolicy=SGKernelSelectionPolicyManual;
    SGPlaybackCoordinator *group=[SGPlaybackCoordinator new];[group registerSession:session];[group activateSession:other];CHECK(otherBackend.playing&&!backend.playing);[group pauseAll];CHECK(!otherBackend.playing);
    [other close];[session close];CHECK(![session next]);[store removePersistentDomainForName:suite];
    puts("PASS session playlist/resume/rendition/A-B/pause race/bounded fallback/stale completions/private diagnostics/coordinator");
}
static void TestTimelinePreviews(NSString *videoPath) {
    NSError *error=nil;
    SGFrameReader *reader=[[SGFrameReader alloc]initWithAsset:[SGAsset assetWithURL:[NSURL fileURLWithPath:videoPath]]];
    SGReaderAbortProbe *abort=[SGReaderAbortProbe new];reader.delegate=abort;CHECK([reader demuxableShouldAbortBlockingFunctions:nil]&&abort.calls==1);
    SGTimelineSpriteIndex *index=[SGTimelineSpriteIndex indexWithWebVTT:@"WEBVTT\n\n00:00.000 --> 00:01.000\nthumb.png#xywh=0,0,32,32\n\n00:01.000 --> 00:02.000\nthumb.png#xywh=32,0,32,32\n" baseURL:[NSURL URLWithString:@"https://example.com/previews/index.vtt"] error:&error];
    CHECK(index && index.cues.count==2);CHECK([index cueAtTime:CMTimeMake(1,1)]==index.cues[1]);CHECK(![index cueAtTime:CMTimeMake(2,1)]);
    CHECK([index.cues[0].URL.absoluteString isEqual:@"https://example.com/previews/thumb.png"]);
    CHECK(![SGTimelineSpriteIndex indexWithWebVTT:@"WEBVTT\n\n00:00.000 --> 00:02.000\na.png\n\n00:01.000 --> 00:03.000\na.png\n" baseURL:[NSURL fileURLWithPath:@"/tmp/a.vtt"] error:&error]);
    SGTimelinePreview *preview=[[SGTimelinePreview alloc]initWithURL:[NSURL fileURLWithPath:videoPath]];
    CIImage *image=[preview imageAtTime:CMTimeMake(1,10) maximumDimension:160 error:&error];CHECK(image && MAX(image.extent.size.width,image.extent.size.height)<=160);
    [preview cancel];CHECK(![preview imageAtTime:kCMTimeZero maximumDimension:160 error:&error] && error);
    puts("PASS independent FFmpeg timeline decode/cancellation/WebVTT interval boundaries/relative URL/overlap rejection");
}
static void TestMediaRemuxing(NSString *directory,NSString *videoPath) {
    NSURL *source=[NSURL fileURLWithPath:videoPath];NSError *error=nil;
    for(int format=0;format<3;format++){
        NSArray *names=@[@"remux.mkv",@"remux.mp4",@"remux.ts"];
        NSURL *destination=[NSURL fileURLWithPath:[directory stringByAppendingPathComponent:names[format]]];
        SGMediaRemuxer *recorder=[SGMediaRemuxer new];
        CHECK([recorder remuxURL:source toURL:destination container:format range:CMTimeRangeMake(kCMTimeZero,CMTimeMake(1,1)) error:&error]);
        CHECK(CMTIMERANGE_IS_VALID(recorder.actualRange)&&CMTimeGetSeconds(recorder.actualRange.duration)>.5);
        SGFrameReader *reader=[[SGFrameReader alloc]initWithAsset:[SGAsset assetWithURL:destination]];CHECK(![reader open]);NSUInteger frames=0;
        while(YES){SGFrame *frame=nil;NSError *next=[reader nextFrame:&frame];if(next){CHECK(next.code==SGErrorCodeDemuxerEndOfFile);break;}CHECK(CMTIME_IS_NUMERIC(frame.timeStamp));frames++;[frame unlock];}
        CHECK(frames>10);[reader close];
        NSData *existing=[NSData dataWithContentsOfURL:destination];[recorder cancel];
        CHECK(![recorder remuxURL:source toURL:destination container:format range:CMTimeRangeMake(kCMTimeZero,CMTimeMake(1,1)) error:&error]);
        CHECK([[NSData dataWithContentsOfURL:destination] isEqual:existing]);
        SGMediaRemuxer *past=[SGMediaRemuxer new];CHECK(![past remuxURL:source toURL:destination container:format range:CMTimeRangeMake(CMTimeMake(100,1),CMTimeMake(1,1)) error:&error]);CHECK([[NSData dataWithContentsOfURL:destination] isEqual:existing]);
    }
    puts("PASS independent Matroska/MP4/MPEG-TS remux, complete output decode, timestamps and atomic cancel/past-EOF preservation");
}

static void TestNativePlaybackPolicy(NSString *videoPath) {
    SGNativePlaybackPolicy *policy=[SGNativePlaybackPolicy new];NSError *error=nil;
    CHECK([policy validate:&error]);policy.preferredMaximumResolution=CGSizeMake(1280,0);CHECK(![policy validate:&error]);
    policy.preferredMaximumResolution=CGSizeMake(1280,720);policy.preferredPeakBitRate=NAN;CHECK(![policy validate:&error]);
    policy.preferredPeakBitRate=750000;policy.preferredForwardBufferDuration=8;policy.automaticallyWaitsToMinimizeStalling=NO;policy.allowsNetworkWhilePaused=YES;
    SGPlaybackController *controller=[[SGPlaybackController alloc]initWithKernel:SGPlaybackKernelNative view:[[SGPLFView alloc]initWithFrame:CGRectMake(0,0,320,180)]];
    CHECK([controller applyNativePlaybackPolicy:policy error:&error]);policy.preferredPeakBitRate=1;
    [controller replaceWithURL:[NSURL fileURLWithPath:videoPath]];
    AVPlayerItem *item=controller.nativePlayer.currentItem;
    CHECK(item.preferredPeakBitRate==750000&&CGSizeEqualToSize(item.preferredMaximumResolution,CGSizeMake(1280,720)));
    CHECK(item.preferredForwardBufferDuration==8&&item.canUseNetworkResourcesForLiveStreamingWhilePaused&&!controller.nativePlayer.automaticallyWaitsToMinimizeStalling);
    SGNativePlaybackPolicy *snapshot=controller.nativePlaybackPolicy;snapshot.preferredPeakBitRate=2;CHECK(controller.nativePlaybackPolicy.preferredPeakBitRate==750000);
    policy.preferredPeakBitRate=-1;CHECK(![controller applyNativePlaybackPolicy:policy error:&error]&&controller.nativePlaybackPolicy.preferredPeakBitRate==750000);
    [controller replaceWithURL:[NSURL fileURLWithPath:videoPath]];CHECK(controller.nativePlayer.currentItem.preferredPeakBitRate==750000);
    CHECK(controller.nativePlaybackMetrics.count==0);[controller close];
    puts("PASS native policy validation/copy isolation/rejected-update preservation/new-source propagation and absent-log handling");
}

static NSString *MakeOffsetAVFixture(NSString *directory,NSString *videoPath) {
    NSString *path=[directory stringByAppendingPathComponent:@"offset-av.mkv"];
    AVFormatContext *input=NULL,*output=NULL;CHECK(avformat_open_input(&input,videoPath.fileSystemRepresentation,NULL,NULL)>=0);CHECK(avformat_find_stream_info(input,NULL)>=0);
    CHECK(avformat_alloc_output_context2(&output,NULL,"matroska",path.fileSystemRepresentation)>=0);
    AVStream *video=avformat_new_stream(output,NULL);CHECK(video);CHECK(avcodec_parameters_copy(video->codecpar,input->streams[0]->codecpar)>=0);video->codecpar->codec_tag=0;video->time_base=input->streams[0]->time_base;
    const AVCodec *codec=avcodec_find_encoder(AV_CODEC_ID_AAC);CHECK(codec);AVCodecContext *audio=avcodec_alloc_context3(codec);CHECK(audio);
    audio->sample_fmt=AV_SAMPLE_FMT_FLTP;audio->sample_rate=48000;av_channel_layout_default(&audio->ch_layout,2);audio->time_base=(AVRational){1,48000};audio->bit_rate=64000;audio->flags|=AV_CODEC_FLAG_GLOBAL_HEADER;CHECK(avcodec_open2(audio,codec,NULL)>=0);
    AVStream *sound=avformat_new_stream(output,NULL);CHECK(sound);sound->time_base=audio->time_base;CHECK(avcodec_parameters_from_context(sound->codecpar,audio)>=0);
    CHECK(avio_open(&output->pb,path.fileSystemRepresentation,AVIO_FLAG_WRITE)>=0);CHECK(avformat_write_header(output,NULL)>=0);
    AVPacket *packet=av_packet_alloc();CHECK(packet);
    while(av_read_frame(input,packet)>=0){if(packet->stream_index==0){av_packet_rescale_ts(packet,input->streams[0]->time_base,video->time_base);packet->stream_index=video->index;packet->pos=-1;CHECK(av_interleaved_write_frame(output,packet)>=0);}av_packet_unref(packet);}
    AVFrame *frame=av_frame_alloc();CHECK(frame);frame->format=audio->sample_fmt;frame->sample_rate=audio->sample_rate;frame->nb_samples=audio->frame_size;CHECK(av_channel_layout_copy(&frame->ch_layout,&audio->ch_layout)>=0);CHECK(av_frame_get_buffer(frame,0)>=0);
    for(int i=0;i<72;i++){
        CHECK(av_frame_make_writable(frame)>=0);CHECK(av_samples_set_silence(frame->extended_data,0,frame->nb_samples,2,audio->sample_fmt)>=0);
        for(int p=0;p<2;p++)for(int j=0;j<frame->nb_samples;j++)((float *)frame->extended_data[p])[j]=.25f*sinf(2*M_PI*1000*((int64_t)i*frame->nb_samples+j)/48000.0);
        frame->pts=12000+(int64_t)i*frame->nb_samples;CHECK(avcodec_send_frame(audio,frame)>=0);WritePackets(audio,output,sound);
    }
    CHECK(avcodec_send_frame(audio,NULL)>=0);WritePackets(audio,output,sound);CHECK(av_write_trailer(output)>=0);
    av_frame_free(&frame);av_packet_free(&packet);avcodec_free_context(&audio);avio_closep(&output->pb);avformat_free_context(output);avformat_close_input(&input);return path;
}
static double AVPacketStartOffset(NSString *path) {
    AVFormatContext *format=NULL;CHECK(avformat_open_input(&format,path.fileSystemRepresentation,NULL,NULL)>=0);CHECK(avformat_find_stream_info(format,NULL)>=0);
    double video=NAN,audio=NAN;int64_t lastDTS[32];for(int i=0;i<32;i++)lastDTS[i]=AV_NOPTS_VALUE;
    AVPacket *packet=av_packet_alloc();CHECK(packet);
    while(av_read_frame(format,packet)>=0){
        AVStream *stream=format->streams[packet->stream_index];
        if(packet->stream_index<32&&packet->dts!=AV_NOPTS_VALUE){CHECK(lastDTS[packet->stream_index]==AV_NOPTS_VALUE||packet->dts>=lastDTS[packet->stream_index]);lastDTS[packet->stream_index]=packet->dts;}
        if(packet->pts!=AV_NOPTS_VALUE){double time=packet->pts*av_q2d(stream->time_base);if(stream->codecpar->codec_type==AVMEDIA_TYPE_VIDEO&&!isfinite(video))video=time;if(stream->codecpar->codec_type==AVMEDIA_TYPE_AUDIO&&!isfinite(audio))audio=time;}
        av_packet_unref(packet);
    }
    av_packet_free(&packet);avformat_close_input(&format);CHECK(isfinite(video)&&isfinite(audio));return audio-video;
}
static void TestRemuxAVSynchronization(NSString *directory,NSString *videoPath) {
    NSString *source=MakeOffsetAVFixture(directory,videoPath);double expected=AVPacketStartOffset(source);CHECK(expected>.2&&expected<.3);
    NSArray *names=@[@"offset-recorded.mkv",@"offset-recorded.mp4",@"offset-recorded.ts"];
    for(int format=0;format<3;format++){
        NSString *path=[directory stringByAppendingPathComponent:names[format]];NSError *error=nil;SGMediaRemuxer *recorder=[SGMediaRemuxer new];
        CHECK([recorder remuxURL:[NSURL fileURLWithPath:source] toURL:[NSURL fileURLWithPath:path] container:format range:CMTimeRangeMake(kCMTimeZero,CMTimeMake(3,2)) error:&error]);
        CHECK(fabs(AVPacketStartOffset(path)-expected)<.003);
        SGFrameReader *reader=[[SGFrameReader alloc]initWithAsset:[SGAsset assetWithURL:[NSURL fileURLWithPath:path]]];CHECK(![reader open]);NSUInteger videos=0,audios=0;
        while(YES){SGFrame *frame=nil;NSError *next=[reader nextFrame:&frame];if(next){CHECK(next.code==SGErrorCodeDemuxerEndOfFile);break;}if(frame.track.type==SGMediaTypeVideo)videos++;if(frame.track.type==SGMediaTypeAudio)audios++;[frame unlock];}
        [reader close];CHECK(videos>20&&audios>20);
    }
    puts("PASS Matroska/MP4/MPEG-TS preserve delayed AAC/video offset, per-stream DTS order and full audio/video decoding");
}

static void TestPlaybackCoverState(void) {
    SGSessionTestController *backend=[SGSessionTestController new];SGPlaybackSession *session=[[SGPlaybackSession alloc]initWithController:backend resumeStore:nil];session.kernelPolicy=SGKernelSelectionPolicyManual;
    SGPLFView *view=[[SGPLFView alloc]initWithFrame:CGRectMake(0,0,320,180)];view.accessibilityLabel=@"Original media";
    NSImage *image=[[NSImage alloc]initWithSize:NSMakeSize(32,32)];SGPlaybackCover *cover=[[SGPlaybackCover alloc]initWithSession:session view:view image:image];
    CHECK(cover.visible&&[view.accessibilityLabel isEqual:@"Video cover"]);
    CHECK([session loadItems:@[SessionTestItem(@"cover")] startIndex:0 autoPlay:NO error:nil]);[cover refresh];CHECK(cover.visible);
    backend.testFrames=1;[cover refresh];CHECK(!cover.visible&&[view.accessibilityLabel isEqual:@"Original media"]);
    backend.testFrames=0;[cover refresh];CHECK(cover.visible);backend.testError=[NSError errorWithDomain:@"test" code:1 userInfo:nil];[session tick];backend.testFrames=10;[cover refresh];CHECK(cover.visible);
    [cover close];CHECK(!cover.visible&&view.subviews.count==0&&[view.accessibilityLabel isEqual:@"Original media"]);
    __weak SGPlaybackCover *released=nil;@autoreleasepool{SGPlaybackCover *temporary=[[SGPlaybackCover alloc]initWithSession:session view:view image:image];released=temporary;CHECK(temporary.visible);}
    CHECK(!released&&view.subviews.count==0&&[view.accessibilityLabel isEqual:@"Original media"]);[session close];
    puts("PASS cover idle/first-frame/reset/failure/close transitions and accessibility-label restoration");
}
