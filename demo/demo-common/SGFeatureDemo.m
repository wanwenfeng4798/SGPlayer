#import "SGFeatureDemo.h"
#import <ImageIO/ImageIO.h>

@interface SGFeatureDemo ()
@property (nonatomic, strong, readwrite) SGPlaybackController *playback;
@property (nonatomic, copy, readwrite) NSDictionary<NSString *,id> *buttons;
@property (nonatomic, readwrite) BOOL busy;
@property (nonatomic, strong, readwrite) NSError *lastActionError;
@property (nonatomic, strong, readwrite) NSURL *exportedGIF;
@property (nonatomic, strong, readwrite) NSURL *exportedVideo;
@property (nonatomic) BOOL videoExportDemo;
@property (nonatomic) BOOL audioExportDemo;
@property (nonatomic, strong) SGMediaTranscoder *transcoder;
@property (nonatomic, copy) NSString *exportMessage;
@property (nonatomic) NSUInteger exportGeneration;
@property (nonatomic, strong) SGPLFView *view;
@property (nonatomic, strong) SGPLFView *videoView;
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic, strong) id statusLabel;
@property (nonatomic, strong) NSURL *mediaURL;
@property (nonatomic, strong) SGGIFExporter *exporter;
@property (nonatomic) NSUInteger filterIndex;
@property (nonatomic) NSUInteger sourceIndex;
@property (nonatomic, copy) NSArray<NSURL *> *sources;
@property (nonatomic, strong) SGPlaybackSession *session;
@property (nonatomic, strong) SGPlaybackControls *sessionControls;
@property (nonatomic, strong) SGPlaybackPresentation *presentation;
@property (nonatomic, strong) SGHLSAssetStore *HLSStore;
@property (nonatomic, copy) NSString *HLSPhase;
@property (nonatomic, copy) NSString *HLSIdentifier;
@end
@implementation SGFeatureDemo
- (instancetype)initWithView:(SGPLFView *)view {
    return [self initWithView:view sessionControls:[NSProcessInfo.processInfo.arguments containsObject:@"--sgplayer-session-controls"]];
}
- (instancetype)initWithView:(SGPLFView *)view sessionControls:(BOOL)sessionControls {
    return [self initWithView:view sessionControls:sessionControls exportMode:[NSProcessInfo.processInfo.arguments containsObject:@"--sgplayer-audio-export"]?SGFeatureExportAudio:[NSProcessInfo.processInfo.arguments containsObject:@"--sgplayer-transcode-demo"]?SGFeatureExportVideo:SGFeatureExportNone];
}
- (instancetype)initWithView:(SGPLFView *)view sessionControls:(BOOL)sessionControls exportMode:(SGFeatureExportMode)exportMode {
    BOOL videoExportDemo=exportMode!=SGFeatureExportNone;
    if(videoExportDemo)sessionControls=NO;
    if ((self=[super init])) {
        self.videoExportDemo=videoExportDemo;
        self.audioExportDemo=exportMode==SGFeatureExportAudio;
        self.view=view;
        CGFloat width=MAX(320,view.bounds.size.width),height=MAX(480,view.bounds.size.height);
        CGFloat controls=sessionControls?260:210;
#if SGPLATFORM_TARGET_OS_TV
        controls=340;
#endif
#if SGPLATFORM_TARGET_OS_MAC
        self.videoView=[[NSView alloc] initWithFrame:NSMakeRect(0,controls,width,height-controls)];
        self.videoView.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable;
#else
        self.videoView=[[UIView alloc] initWithFrame:CGRectMake(0,0,width,height-controls)];
        self.videoView.autoresizingMask=UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;
        self.videoView.backgroundColor=UIColor.blackColor;
#endif
#if SGPLATFORM_TARGET_OS_MAC
        self.videoView.accessibilityElement=YES;
        self.videoView.accessibilityRole=NSAccessibilityImageRole;
#else
        self.videoView.isAccessibilityElement=YES;
#endif
        self.videoView.accessibilityIdentifier=@"feature.video";
        [view addSubview:self.videoView];
        self.playback=[[SGPlaybackController alloc] initWithKernel:SGPlaybackKernelFFmpeg view:self.videoView];
        NSAssert(self.playback.effects.subtitleFallbackFontURL!=nil,@"Copy SGPlayer subtitle font resources into the application bundle");
        NSMutableArray *sources=[NSMutableArray array];
        for (NSString *name in @[@"i-see-fire.mp4",@"google-help-vr.mp4",@"ffv1.mkv",@"h264.mkv",@"huffyuv.avi",@"sorenson.flv",@"mpeg2.ts",@"wmv2.asf",@"mpeg4.nut",@"animated.gif"]) {
            NSURL *URL=[NSBundle.mainBundle URLForResource:name.stringByDeletingPathExtension withExtension:name.pathExtension];
            if (URL) [sources addObject:URL];
        }
        self.sources=sources;self.mediaURL=sources.firstObject;
        if([NSProcessInfo.processInfo.arguments containsObject:@"--sgplayer-feature-orientation-test"]) self.mediaURL=[NSBundle.mainBundle URLForResource:@"orientation" withExtension:@"mp4"];
        if([NSProcessInfo.processInfo.arguments containsObject:@"--sgplayer-feature-invalid-source"]) self.mediaURL=[NSBundle.mainBundle.bundleURL URLByAppendingPathComponent:@"missing-test-media.mp4"];
        if(videoExportDemo){NSURL *fixture=[NSBundle.mainBundle URLForResource:@"transcode-av" withExtension:@"mp4"];if(fixture){self.mediaURL=fixture;self.sources=@[fixture];}self.playback.volume=.1;}
        if(sessionControls){[self setupSessionControls:controls width:width height:height];return self;}
        self.session=[[SGPlaybackSession alloc]initWithController:self.playback resumeStore:nil];
        if (self.mediaURL) [self openAutomaticURL:self.mediaURL];
        NSArray *actions=@[@"play",@"pause",@"seek",@"kernel",@"subtitles",@"danmaku",@"watermark",@"filter",@"sticker",@"pip",@"export",@"stop",@"source",@"vr",@"rate",@"screenshot"];
        NSArray *titles=@[@"播放 Play",@"暂停 Pause",@"跳转 Seek",@"内核 Kernel",@"字幕 Subs",@"弹幕 Danmaku",@"水印 Mark",@"滤镜 Filter",@"贴纸 Sticker",@"画中画 PiP",@"导出 GIF",@"停止 Stop",@"媒体 Source",@"全景 VR",@"倍速 Rate",@"截图 Capture"];
        NSMutableDictionary *buttons=[NSMutableDictionary dictionary];
        CGFloat rowHeight=(controls-40)/4;
        for (NSUInteger i=0;i<actions.count;i++) {
            CGFloat x=(i%4)*width/4+3;
#if SGPLATFORM_TARGET_OS_MAC
            CGFloat y=controls-40-(i/4+1)*rowHeight;
            NSButton *button=[NSButton buttonWithTitle:videoExportDemo&&i==10?(self.audioExportDemo?@"导出音频 Export audio":@"导出 MP4"):titles[i] target:self action:@selector(buttonPressed:)];
            button.frame=NSMakeRect(x,y,width/4-6,rowHeight-4);button.identifier=actions[i];
            button.accessibilityIdentifier=[@"feature." stringByAppendingString:actions[i]];
            button.autoresizingMask=NSViewMinXMargin|NSViewMaxXMargin;
#else
            CGFloat y=height-controls+40+(i/4)*rowHeight;
            UIButton *button=[UIButton buttonWithType:UIButtonTypeSystem];
            button.frame=CGRectMake(x,y,width/4-6,rowHeight-4);[button setTitle:videoExportDemo&&i==10?(self.audioExportDemo?@"导出音频 Export audio":@"导出 MP4"):titles[i] forState:UIControlStateNormal];
            button.titleLabel.font=[UIFont systemFontOfSize:12];
            button.accessibilityIdentifier=[@"feature." stringByAppendingString:actions[i]];
            [button addTarget:self action:@selector(buttonPressed:) forControlEvents:UIControlEventPrimaryActionTriggered];
            button.autoresizingMask=UIViewAutoresizingFlexibleTopMargin|UIViewAutoresizingFlexibleLeftMargin|UIViewAutoresizingFlexibleRightMargin;
#endif
            if(i==3 && ![NSProcessInfo.processInfo.arguments containsObject:@"--sgplayer-debug-kernel"]) button.hidden=YES;
            [view addSubview:button];buttons[actions[i]]=button;
        }
        self.buttons=buttons;
#if SGPLATFORM_TARGET_OS_MAC
        NSTextField *label=[NSTextField labelWithString:@"Loading"];label.frame=NSMakeRect(8,controls-35,width-16,30);label.autoresizingMask=NSViewWidthSizable;
#else
        UILabel *label=[[UILabel alloc] initWithFrame:CGRectMake(8,height-controls,width-16,36)];label.textColor=UIColor.whiteColor;label.backgroundColor=UIColor.darkGrayColor;label.font=[UIFont systemFontOfSize:11];label.numberOfLines=2;label.autoresizingMask=UIViewAutoresizingFlexibleTopMargin|UIViewAutoresizingFlexibleWidth;
#endif
        label.accessibilityIdentifier=@"feature.status";self.statusLabel=label;[view addSubview:label];
        __weak SGFeatureDemo *weakSelf=self;
        self.playback.pictureInPictureChanged=^(BOOL active,NSError *error){if(error) weakSelf.lastActionError=error;};
        self.playback.restoreInterface=^(void (^completion)(BOOL)) {
#if SGPLATFORM_TARGET_OS_MAC
            [weakSelf.view.window makeKeyAndOrderFront:nil];[NSApp activateIgnoringOtherApps:YES];
#endif
            completion(weakSelf.view.window!=nil);
        };
        self.timer=[NSTimer scheduledTimerWithTimeInterval:0.2 repeats:YES block:^(NSTimer *timer){[weakSelf updateStatus];}];
        [self.playback play];
        if([NSProcessInfo.processInfo.arguments containsObject:@"--sgplayer-auto-kernel-test"]) [self verifyAutomaticKernels];
    }return self;
}
- (void)dealloc {[self.timer invalidate];[self.presentation restore];[self.session close];[self.playback close];[self.exporter cancel];[self.transcoder cancel];}
- (void)setupSessionControls:(CGFloat)height width:(CGFloat)width height:(CGFloat)containerHeight {
    NSUserDefaults *store=[NSProcessInfo.processInfo.arguments containsObject:@"--sgplayer-no-resume"]?nil:NSUserDefaults.standardUserDefaults;
    self.session=[[SGPlaybackSession alloc]initWithController:self.playback resumeStore:store];self.session.kernelPolicy=SGKernelSelectionPolicyAutomatic;
    NSArray *sources=[NSProcessInfo.processInfo.arguments containsObject:@"--sgplayer-feature-orientation-test"]&&self.mediaURL?@[self.mediaURL]:self.sources;
    BOOL coverTest=[NSProcessInfo.processInfo.arguments containsObject:@"--sgplayer-cover-test"];
    if(coverTest&&self.mediaURL){sources=@[[NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:@"SGPlayer-cover-missing.mp4"]],self.mediaURL];self.session.kernelPolicy=SGKernelSelectionPolicyManual;}
    NSMutableArray *items=[NSMutableArray array];for(NSURL *URL in sources){SGPlaybackRendition *rendition=[[SGPlaybackRendition alloc]initWithIdentifier:@"original" title:@"Original" URL:URL];[items addObject:[[SGPlaybackItem alloc]initWithIdentifier:URL.lastPathComponent title:URL.lastPathComponent renditions:@[rendition]]];}
    [self.session loadItems:items startIndex:0 autoPlay:YES error:nil];
    self.sessionControls=[[SGPlaybackControls alloc]initWithSession:self.session];
    if(coverTest){
        CGColorSpaceRef space=CGColorSpaceCreateDeviceRGB();CGContextRef context=CGBitmapContextCreate(NULL,32,32,8,128,space,kCGImageAlphaPremultipliedLast);CGContextSetRGBFillColor(context,0,0,1,1);CGContextFillRect(context,CGRectMake(0,0,32,32));CGImageRef image=CGBitmapContextCreateImage(context);
#if SGPLATFORM_TARGET_OS_MAC
        SGPLFImage *cover=[[NSImage alloc]initWithCGImage:image size:NSMakeSize(32,32)];
#else
        SGPLFImage *cover=[UIImage imageWithCGImage:image];
#endif
        [self.sessionControls setCoverImage:cover forView:self.videoView];CGImageRelease(image);CGContextRelease(context);CGColorSpaceRelease(space);
    }
#if SGPLATFORM_TARGET_OS_IPHONE
    [self.sessionControls attachGesturesToView:self.videoView];
#elif SGPLATFORM_TARGET_OS_TV
    [self.sessionControls attachRemoteToView:self.videoView];
#endif
    if([NSProcessInfo.processInfo.arguments containsObject:@"--sgplayer-auto-hide-controls"])self.sessionControls.autoHideInterval=4;
#if SGPLATFORM_TARGET_OS_MAC
    [self.sessionControls attachKeyboardToView:self.videoView];
    if([NSProcessInfo.processInfo.arguments containsObject:@"--sgplayer-keyboard-test-input"]){NSTextField *input=[[NSTextField alloc]initWithFrame:NSMakeRect(20,20,220,26)];input.accessibilityIdentifier=@"session.keyboard-input";[self.videoView addSubview:input];}
    self.sessionControls.frame=CGRectMake(0,0,width,height);self.sessionControls.autoresizingMask=NSViewWidthSizable;
#else
    self.sessionControls.frame=CGRectMake(0,containerHeight-height,width,height);self.sessionControls.autoresizingMask=UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleTopMargin;
#endif
    [self.view addSubview:self.sessionControls];self.presentation=[[SGPlaybackPresentation alloc]initWithSurface:self.videoView];
    __weak typeof(self) weakSelf=self;
    self.sessionControls.toggleFullScreen=^{SGFeatureDemo *self=weakSelf;if(!self)return;if(self.presentation.mode==SGPlaybackPresentationModeFullScreen)[self.presentation restore];else[self.presentation showFullScreenInView:self.view];};
    self.sessionControls.dismissPresentation=^{[weakSelf.presentation restore];};
    self.sessionControls.toggleFloatingWindow=^{SGFeatureDemo *self=weakSelf;if(!self)return;if(self.presentation.mode==SGPlaybackPresentationModeFloating)[self.presentation restore];else{CGFloat w=MIN(320,self.view.bounds.size.width-20),h=MIN(208,self.view.bounds.size.height-20);[self.presentation showFloatingInView:self.view frame:CGRectMake(10,10,w,h)];}};
    self.buttons=@{};
    for(NSString *argument in NSProcessInfo.processInfo.arguments)if([argument hasPrefix:@"--sgplayer-hls-test="])[self verifyHLS:[NSURL URLWithString:[argument substringFromIndex:@"--sgplayer-hls-test=".length]]];
}
- (void)verifyHLS:(NSURL *)URL {
    if(!SGHLSAssetStore.isSupported)return;
    self.HLSIdentifier=@"hls-verification";for(NSString *argument in NSProcessInfo.processInfo.arguments)if([argument hasPrefix:@"--sgplayer-hls-test-id="])self.HLSIdentifier=[argument substringFromIndex:@"--sgplayer-hls-test-id=".length];
    self.HLSStore=[[SGHLSAssetStore alloc]initWithBackgroundIdentifier:[NSBundle.mainBundle.bundleIdentifier stringByAppendingString:@".hls-verification"] metadataStore:NSUserDefaults.standardUserDefaults];
    __weak typeof(self) weakSelf=self;
    void (^offline)(NSURL *,NSString *)=^(NSURL *asset,NSString *phase){
        SGFeatureDemo *self=weakSelf;if(!self)return;self.HLSPhase=phase;
        [self.playback resetToKernel:SGPlaybackKernelNative];self.session.kernelPolicy=SGKernelSelectionPolicyManual;
        SGPlaybackRendition *rendition=[[SGPlaybackRendition alloc]initWithIdentifier:@"offline" title:@"Offline HLS" URL:asset];SGPlaybackItem *item=[[SGPlaybackItem alloc]initWithIdentifier:@"hls-verification" title:@"Offline HLS" renditions:@[rendition]];
        [self.session loadItems:@[item] startIndex:0 autoPlay:YES error:nil];
        self.timer=[NSTimer scheduledTimerWithTimeInterval:.2 repeats:YES block:^(NSTimer *timer){SGFeatureDemo *self=weakSelf;if(!self)return;
            if(self.playback.presentedFrameCount>=5){
                NSDictionary *result=@{@"passed":@YES,@"phase":self.HLSPhase,@"frames":@(self.playback.presentedFrameCount),@"kernel":@"native"};
                if([NSProcessInfo.processInfo.arguments containsObject:@"--sgplayer-hls-test-cleanup"]){[self.session close];NSError *error=nil;if(![self.HLSStore removeIdentifier:self.HLSIdentifier error:&error])result=@{@"passed":@NO,@"errorCode":@(error.code)};}
                [self writeHLSResult:result];[timer invalidate];}
            else if(self.session.error){[self writeHLSResult:@{@"passed":@NO,@"errorCode":@(self.session.error.code)}];[timer invalidate];}
        }];
    };
    self.HLSStore.changed=^(NSString *identifier,NSURL *asset,NSError *error){if(asset)offline(asset,@"downloaded");else[weakSelf writeHLSResult:@{@"passed":@NO,@"errorCode":@(error.code)}];};
    [self.HLSStore restoreTasksWithCompletion:^{SGFeatureDemo *self=weakSelf;if(!self)return;NSURL *cached=[self.HLSStore offlineURLForIdentifier:self.HLSIdentifier];
        if(cached)offline(cached,@"restored");
        else{NSError *error=nil;if(![self.HLSStore downloadAsset:[AVURLAsset URLAssetWithURL:URL options:nil] identifier:self.HLSIdentifier title:@"SGPlayer HLS verification" error:&error])[self writeHLSResult:@{@"passed":@NO,@"errorCode":@(error.code)}];}
    }];
}
- (void)writeHLSResult:(NSDictionary *)result {
    [[NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted error:nil]writeToURL:[[self directory]URLByAppendingPathComponent:@"hls-test.json"] options:NSDataWritingAtomic error:nil];
}
- (void)verifyAutomaticKernels {
    NSURL *native=[NSBundle.mainBundle URLForResource:@"orientation" withExtension:@"mp4"];
    NSURL *ffmpeg=[NSBundle.mainBundle URLForResource:@"ffv1" withExtension:@"mkv"];
    if(!native || !ffmpeg)return;
    NSURL *extensionless=[[self directory]URLByAppendingPathComponent:@"native-without-extension"];
    NSURL *misnamed=[[self directory]URLByAppendingPathComponent:@"ffv1-misnamed.mp4"];
    [[NSData dataWithContentsOfURL:native]writeToURL:extensionless atomically:YES];
    [[NSData dataWithContentsOfURL:ffmpeg]writeToURL:misnamed atomically:YES];
    NSArray *URLs=@[native,extensionless,ffmpeg,misnamed];
    __block NSUInteger index=0;__block NSTimeInterval started=NSDate.timeIntervalSinceReferenceDate;
    NSMutableArray *results=[NSMutableArray array];
    [self.timer invalidate];[self openAutomaticURL:URLs[0]];
    __weak typeof(self) weakSelf=self;
    self.timer=[NSTimer scheduledTimerWithTimeInterval:.2 repeats:YES block:^(NSTimer *timer){
        SGFeatureDemo *self=weakSelf;if(!self){[timer invalidate];return;}
        BOOL ready=self.session.state==SGPlaybackSessionStatePlaying&&self.playback.presentedFrameCount>=3;
        if(!ready&&!self.session.error&&NSDate.timeIntervalSinceReferenceDate-started<25)return;
        SGPlaybackKernel expected=index<2?SGPlaybackKernelNative:SGPlaybackKernelFFmpeg;
        BOOL passed=ready&&!self.session.error&&(index==1 || self.playback.kernel==expected);
        [results addObject:@{@"index":@(index),@"passed":@(passed),@"kernel":@(self.playback.kernel),@"frames":@(self.playback.presentedFrameCount)}];
        if(!passed || ++index==URLs.count){
            NSString *run=@"";for(NSString *arg in NSProcessInfo.processInfo.arguments)if([arg hasPrefix:@"--sgplayer-smoke-run="])run=[arg substringFromIndex:@"--sgplayer-smoke-run=".length];
            NSDictionary *report=@{@"passed":@(passed),@"runID":run,@"cases":results};
            [[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil]writeToURL:[[self directory]URLByAppendingPathComponent:@"auto-kernel-test.json"] atomically:YES];
            [timer invalidate];return;
        }
        started=NSDate.timeIntervalSinceReferenceDate;[self openAutomaticURL:URLs[index]];
    }];
}
- (void)openAutomaticURL:(NSURL *)URL {
    SGPlaybackRendition *rendition=[[SGPlaybackRendition alloc]initWithIdentifier:@"original" title:@"Original" URL:URL];
    SGPlaybackItem *item=[[SGPlaybackItem alloc]initWithIdentifier:URL.lastPathComponent title:URL.lastPathComponent renditions:@[rendition]];
    [self.session loadItems:@[item] startIndex:0 autoPlay:YES error:nil];
}
- (void)buttonPressed:(id)sender {
#if SGPLATFORM_TARGET_OS_MAC
    NSString *identifier=[sender identifier];
#else
    NSString *identifier=[[sender accessibilityIdentifier] stringByReplacingOccurrencesOfString:@"feature." withString:@""];
#endif
    [self activateAction:identifier];
}
- (NSURL *)directory {
    NSURL *directory=[NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
    for (NSString *argument in NSProcessInfo.processInfo.arguments) if ([argument hasPrefix:@"--sgplayer-test-output="]) directory=[NSURL fileURLWithPath:[argument substringFromIndex:[@"--sgplayer-test-output=" length]] isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:nil];return directory;
}
- (void)activateAction:(NSString *)identifier {
    self.lastActionError=nil;
    SGMediaEffects *effects=self.playback.effects;
    if ([identifier isEqual:@"play"]) [self.playback play];
    else if ([identifier isEqual:@"pause"]) [self.playback pause];
    else if ([identifier isEqual:@"seek"]) {
        CMTime time=CMTimeAdd(self.playback.currentTime,CMTimeMake(5,1));
        if (CMTIME_IS_NUMERIC(self.playback.duration)) time=CMTimeMinimum(time,CMTimeMaximum(kCMTimeZero,CMTimeSubtract(self.playback.duration,CMTimeMake(1,2))));
        self.busy=YES;[self.playback seekToTime:time completion:^(BOOL success){self.busy=NO;if(!success) self.lastActionError=[NSError errorWithDomain:@"SGDemo" code:1 userInfo:@{NSLocalizedDescriptionKey:@"Seek failed"}];}];
    } else if ([identifier isEqual:@"kernel"] && !self.busy) {
        self.busy=YES;[self.playback switchToKernel:self.playback.kernel==SGPlaybackKernelFFmpeg?SGPlaybackKernelNative:SGPlaybackKernelFFmpeg completion:^(BOOL success){self.busy=NO;if(!success)self.lastActionError=self.playback.error?:[NSError errorWithDomain:@"SGDemo" code:2 userInfo:@{NSLocalizedDescriptionKey:@"Backend switch failed"}];}];
    } else if ([identifier isEqual:@"subtitles"] && !self.busy) {
        if (self.playback.subtitleTracks.count) [self.playback selectSubtitleTrack:self.playback.selectedSubtitleTrack<0?self.playback.subtitleTracks.firstObject.index:-1];
        else {
            NSURL *URL=[[self directory] URLByAppendingPathComponent:@"demo.srt"];
            [@"1\n00:00:00,000 --> 00:00:05,000\nSGPlayer 字幕 / Subtitle\n\n2\n00:00:05,000 --> 00:10:00,000\n同步字幕 / Synchronized captions\n" writeToURL:URL atomically:YES encoding:NSUTF8StringEncoding error:nil];
            self.busy=YES;[self.playback loadSubtitlesFromURL:URL completion:^(NSError *error){self.busy=NO;self.lastActionError=error;if(!error&&self.playback.subtitleTracks.count)[self.playback selectSubtitleTrack:self.playback.subtitleTracks.firstObject.index];}];
        }
    } else if ([identifier isEqual:@"danmaku"]) {
        if (effects.danmaku.count) effects.danmaku=@[];
        else {NSMutableArray *events=[NSMutableArray array];double now=CMTimeGetSeconds(self.playback.currentTime);for(int i=0;i<20;i++){SGDanmakuItem *item=[[SGDanmakuItem alloc]init];item.start=CMTimeMakeWithSeconds((isfinite(now)?now:0)+i*0.6,1000);item.text=[NSString stringWithFormat:@"弹幕 Danmaku %d",i+1];item.mode=i%3;[events addObject:item];}effects.danmaku=events;}
    } else if ([identifier isEqual:@"watermark"]) {
        SGWatermark *mark=[[SGWatermark alloc]init];mark.text=@"OmniLink / SGPlayer";effects.watermarks=effects.watermarks.count?@[]:@[mark];
    } else if ([identifier isEqual:@"filter"]) {
        SGFilterConfiguration *filter=[[SGFilterConfiguration alloc]init];self.filterIndex=(self.filterIndex+1)%5;
        if(self.filterIndex==1)filter.grayscale=YES;
        if(self.filterIndex==2){filter.brightness=0.15;filter.contrast=1.2;filter.saturation=1.3;}
        if(self.filterIndex==3){filter.horizontalFlip=YES;filter.verticalFlip=YES;}
        if(self.filterIndex==4)filter.blurRadius=3;
        effects.filter=filter;
    } else if ([identifier isEqual:@"export"] && !self.busy) {
        if(self.videoExportDemo){if(self.exportedVideo)[self playExportedVideo];else[self exportVideo];}else[self exportGIF:NO];
    }
    else if ([identifier isEqual:@"sticker"] && !self.busy) {
        if(effects.sticker)effects.sticker=nil;else [self exportGIF:YES];
    } else if ([identifier isEqual:@"pip"]) {
        if(self.playback.pictureInPictureActive)[self.playback stopPictureInPicture];else{NSError *error=nil;[self.playback startPictureInPicture:&error];self.lastActionError=error;}
    } else if ([identifier isEqual:@"stop"]) { [self.playback pause];[self.exporter cancel];[self.playback stopPictureInPicture];if(self.transcoder){self.exportGeneration++;[self.transcoder cancel];self.transcoder=nil;self.busy=NO;self.exportMessage=self.audioExportDemo?@"Audio:cancelled":@"Video:cancelled";} }
    else if ([identifier isEqual:@"source"] && !self.busy && self.sources.count) {if(self.videoExportDemo){self.exportedVideo=nil;self.exportMessage=nil;[self setVideoExportButtonReady:NO];}self.sourceIndex=(self.sourceIndex+1)%self.sources.count;self.mediaURL=self.sources[self.sourceIndex];[self openAutomaticURL:self.mediaURL];}
    else if ([identifier isEqual:@"vr"]) {
        if(self.playback.kernel==SGPlaybackKernelFFmpeg){SGVideoRenderer *renderer=self.playback.ffmpegPlayer.videoRenderer;renderer.displayMode=renderer.displayMode==SGDisplayModePlane?SGDisplayModeVR:SGDisplayModePlane;self.session.requiresFFmpeg=renderer.displayMode!=SGDisplayModePlane;}
        else {self.session.requiresFFmpeg=YES;[self.session switchToKernel:SGPlaybackKernelFFmpeg completion:^(BOOL success){if(success)self.playback.ffmpegPlayer.videoRenderer.displayMode=SGDisplayModeVR;}];}
    } else if ([identifier isEqual:@"rate"]) self.playback.rate=self.playback.rate==1?0.5:self.playback.rate==0.5?2:1;
    else if ([identifier isEqual:@"screenshot"]) {
        SGPLFImage *image=[self.playback currentImage];NSData *data=nil;
#if SGPLATFORM_TARGET_OS_MAC
        NSBitmapImageRep *bitmap=[[NSBitmapImageRep alloc]initWithData:image.TIFFRepresentation];data=[bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
#else
        if(image)data=UIImagePNGRepresentation(image);
#endif
        if(!data||![data writeToURL:[[self directory] URLByAppendingPathComponent:@"feature-capture.png"] atomically:YES])self.lastActionError=[NSError errorWithDomain:@"SGDemo" code:4 userInfo:@{NSLocalizedDescriptionKey:@"Capture unavailable"}];
    }
    [self updateStatus];
}
- (void)exportGIF:(BOOL)sticker {
    self.busy=YES;self.exporter=[[SGGIFExporter alloc]init];
    SGGIFExporter *exporter=self.exporter;NSURL *source=self.mediaURL,*destination=[[self directory]URLByAppendingPathComponent:sticker?@"sticker.gif":@"feature-export.gif"];
    SGMediaEffects *effects=sticker?nil:[self.playback.effects snapshot];
    __weak SGFeatureDemo *weakSelf=self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
        NSError *error=nil;BOOL success=[exporter exportURL:source toURL:destination range:CMTimeRangeMake(kCMTimeZero,CMTimeMake(1,1)) framesPerSecond:10 maximumDimension:320 effects:effects error:&error];
        dispatch_async(dispatch_get_main_queue(),^{SGFeatureDemo *self=weakSelf;if(!self)return;self.busy=NO;self.lastActionError=error;self.exporter=nil;if(success){self.exportedGIF=destination;if(sticker){NSError *stickerError=nil;self.playback.effects.sticker=[SGAnimatedImage imageWithURL:destination maxDecodedBytes:32*1024*1024 error:&stickerError];self.playback.effects.stickerStart=CMTimeGetSeconds(self.playback.currentTime);self.lastActionError=stickerError;}}});
    });
}
- (void)setVideoExportButtonReady:(BOOL)ready {
    id button=self.buttons[@"export"];
#if SGPLATFORM_TARGET_OS_MAC
    [button setTitle:ready?@"播放导出 Play export":self.audioExportDemo?@"导出音频 Export audio":@"导出 MP4"];
#else
    [button setTitle:ready?@"播放导出 Play export":self.audioExportDemo?@"导出音频 Export audio":@"导出 MP4" forState:UIControlStateNormal];
#endif
}
- (void)playExportedVideo {
    if(!self.exportedVideo)return;
    SGMediaEffects *effects=self.playback.effects;effects.filter=[SGFilterConfiguration new];effects.subtitles=@[];effects.subtitleTrack=nil;effects.secondarySubtitleTrack=nil;effects.danmaku=@[];effects.watermarks=@[];effects.sticker=nil;
    self.mediaURL=self.exportedVideo;[self openAutomaticURL:self.mediaURL];self.exportMessage=self.audioExportDemo?@"Audio:playing":@"Video:playing";
}
- (void)exportVideo {
    self.busy=YES;self.exportMessage=self.audioExportDemo?@"Audio:working":@"Video:working";self.transcoder=[SGMediaTranscoder new];SGMediaTranscoder *exporter=self.transcoder;NSUInteger generation=++self.exportGeneration;
    BOOL audioOnly=self.audioExportDemo;SGPlaybackKernel kernel=self.playback.kernel;NSString *kind=audioOnly?@"Audio":@"Video";
    NSURL *source=self.mediaURL,*destination=[[self directory]URLByAppendingPathComponent:audioOnly?@"feature-audio.m4a":@"feature-export.mp4"];
    SGMediaEffects *effects=audioOnly?nil:[self.playback.effects snapshot];SGTranscodeConfiguration *config=[SGTranscodeConfiguration new];config.includeVideo=!audioOnly;config.maximumDimension=320;config.videoCodec=SGTranscodeVideoCodecH264VideoToolbox;
    __weak typeof(self) weakSelf=self;exporter.progress=^(double fraction){dispatch_async(dispatch_get_main_queue(),^{if(weakSelf.exportGeneration==generation)weakSelf.exportMessage=[NSString stringWithFormat:@"%@:working %.0f%%",kind,fraction*100];});};
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
        NSError *error=nil;BOOL success=[exporter transcodeURL:source toURL:destination configuration:config range:CMTimeRangeMake(kCMTimeZero,CMTimeMake(1,1)) effects:effects error:&error];
        dispatch_async(dispatch_get_main_queue(),^{SGFeatureDemo *self=weakSelf;if(!self||self.exportGeneration!=generation)return;self.busy=NO;self.transcoder=nil;self.lastActionError=error;self.exportMessage=[kind stringByAppendingString:success?@":ready":@":failed"];
            if(success){self.exportedVideo=destination;[self setVideoExportButtonReady:YES];}
            NSDictionary *report=@{@"passed":@(success),@"kernel":@(kernel),@"includeVideo":@(config.includeVideo),@"videoCodec":@(config.videoCodec),@"videoFrames":@(exporter.videoFrameCount),@"audioSamples":@(exporter.audioSampleCount),@"errorCode":error?@(error.code):NSNull.null};
            [[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil]writeToURL:[[self directory]URLByAppendingPathComponent:[NSString stringWithFormat:@"%@-demo-%ld.json",audioOnly?@"audio":@"transcode",(long)kernel]] options:NSDataWritingAtomic error:nil];
        });
    });
}
- (void)updateStatus {
    NSString *message=[NSString stringWithFormat:@"%@ | %.1fs | %.1fx | %lu frames%@%@",self.playback.kernel==SGPlaybackKernelFFmpeg?@"FFmpeg":@"Native",CMTimeGetSeconds(self.playback.currentTime),self.playback.rate,(unsigned long)self.playback.presentedFrameCount,[NSString stringWithFormat:@"%@ | PiP:%@ | %@ | BgFrames:%lu",self.busy?@" | Working":@"",self.playback.pictureInPictureActive?@"on":@"off",self.mediaURL.lastPathComponent?:@"",(unsigned long)self.playback.backgroundFrameCount],(self.lastActionError?:self.playback.error)?[NSString stringWithFormat:@" | Error: %@",(self.lastActionError?:self.playback.error).localizedDescription]:@""];
#if SGPLATFORM_TARGET_OS_MAC
    if(self.exportMessage)message=[message stringByAppendingFormat:@" | %@",self.exportMessage];
    [self.statusLabel setStringValue:message];
#else
    if(self.exportMessage)message=[message stringByAppendingFormat:@" | %@",self.exportMessage];
    [self.statusLabel setText:message];
#endif
}
- (void)close {self.exportGeneration++;[self.transcoder cancel];self.transcoder=nil;[self.timer invalidate];self.timer=nil;[self.exporter cancel];[self.HLSStore close];[self.presentation restore];[self.session close];[self.playback close];}
@end
