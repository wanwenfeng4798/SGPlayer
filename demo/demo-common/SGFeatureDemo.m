#import "SGFeatureDemo.h"
#import <ImageIO/ImageIO.h>

@interface SGFeatureDemo ()
@property (nonatomic, strong, readwrite) SGPlaybackController *playback;
@property (nonatomic, copy, readwrite) NSDictionary<NSString *,id> *buttons;
@property (nonatomic, readwrite) BOOL busy;
@property (nonatomic, strong, readwrite) NSError *lastActionError;
@property (nonatomic, strong, readwrite) NSURL *exportedGIF;
@property (nonatomic, strong) SGPLFView *view;
@property (nonatomic, strong) SGPLFView *videoView;
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic, strong) id statusLabel;
@property (nonatomic, strong) NSURL *mediaURL;
@property (nonatomic, strong) SGGIFExporter *exporter;
@property (nonatomic) NSUInteger filterIndex;
@property (nonatomic) NSUInteger sourceIndex;
@property (nonatomic, copy) NSArray<NSURL *> *sources;
@end
@implementation SGFeatureDemo
- (instancetype)initWithView:(SGPLFView *)view {
    if ((self=[super init])) {
        self.view=view;
        CGFloat width=MAX(320,view.bounds.size.width),height=MAX(480,view.bounds.size.height);
        CGFloat controls=210;
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
        if (self.mediaURL) [self.playback replaceWithURL:self.mediaURL];
        NSArray *actions=@[@"play",@"pause",@"seek",@"kernel",@"subtitles",@"danmaku",@"watermark",@"filter",@"sticker",@"pip",@"export",@"stop",@"source",@"vr",@"rate",@"screenshot"];
        NSArray *titles=@[@"播放 Play",@"暂停 Pause",@"跳转 Seek",@"内核 Kernel",@"字幕 Subs",@"弹幕 Danmaku",@"水印 Mark",@"滤镜 Filter",@"贴纸 Sticker",@"画中画 PiP",@"导出 GIF",@"停止 Stop",@"媒体 Source",@"全景 VR",@"倍速 Rate",@"截图 Capture"];
        NSMutableDictionary *buttons=[NSMutableDictionary dictionary];
        CGFloat rowHeight=(controls-40)/4;
        for (NSUInteger i=0;i<actions.count;i++) {
            CGFloat x=(i%4)*width/4+3;
#if SGPLATFORM_TARGET_OS_MAC
            CGFloat y=controls-40-(i/4+1)*rowHeight;
            NSButton *button=[NSButton buttonWithTitle:titles[i] target:self action:@selector(buttonPressed:)];
            button.frame=NSMakeRect(x,y,width/4-6,rowHeight-4);button.identifier=actions[i];
            button.accessibilityIdentifier=[@"feature." stringByAppendingString:actions[i]];
            button.autoresizingMask=NSViewMinXMargin|NSViewMaxXMargin;
#else
            CGFloat y=height-controls+40+(i/4)*rowHeight;
            UIButton *button=[UIButton buttonWithType:UIButtonTypeSystem];
            button.frame=CGRectMake(x,y,width/4-6,rowHeight-4);[button setTitle:titles[i] forState:UIControlStateNormal];
            button.titleLabel.font=[UIFont systemFontOfSize:12];
            button.accessibilityIdentifier=[@"feature." stringByAppendingString:actions[i]];
            [button addTarget:self action:@selector(buttonPressed:) forControlEvents:UIControlEventPrimaryActionTriggered];
            button.autoresizingMask=UIViewAutoresizingFlexibleTopMargin|UIViewAutoresizingFlexibleLeftMargin|UIViewAutoresizingFlexibleRightMargin;
#endif
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
    }return self;
}
- (void)dealloc {[self.timer invalidate];[self.playback close];[self.exporter cancel];}
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
    } else if ([identifier isEqual:@"export"] && !self.busy) [self exportGIF:NO];
    else if ([identifier isEqual:@"sticker"] && !self.busy) {
        if(effects.sticker)effects.sticker=nil;else [self exportGIF:YES];
    } else if ([identifier isEqual:@"pip"]) {
        if(self.playback.pictureInPictureActive)[self.playback stopPictureInPicture];else{NSError *error=nil;[self.playback startPictureInPicture:&error];self.lastActionError=error;}
    } else if ([identifier isEqual:@"stop"]) { [self.playback pause];[self.exporter cancel];[self.playback stopPictureInPicture]; }
    else if ([identifier isEqual:@"source"] && !self.busy && self.sources.count) {self.sourceIndex=(self.sourceIndex+1)%self.sources.count;self.mediaURL=self.sources[self.sourceIndex];[self.playback replaceWithURL:self.mediaURL];[self.playback play];}
    else if ([identifier isEqual:@"vr"]) {
        if(self.playback.kernel==SGPlaybackKernelFFmpeg){SGVideoRenderer *renderer=self.playback.ffmpegPlayer.videoRenderer;renderer.displayMode=renderer.displayMode==SGDisplayModePlane?SGDisplayModeVR:SGDisplayModePlane;}
        else self.lastActionError=[NSError errorWithDomain:@"SGDemo" code:3 userInfo:@{NSLocalizedDescriptionKey:@"VR projection requires the FFmpeg/Metal backend"}];
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
    SGMediaEffects *effects=sticker?nil:self.playback.effects;
    __weak SGFeatureDemo *weakSelf=self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
        NSError *error=nil;BOOL success=[exporter exportURL:source toURL:destination range:CMTimeRangeMake(kCMTimeZero,CMTimeMake(1,1)) framesPerSecond:10 maximumDimension:320 effects:effects error:&error];
        dispatch_async(dispatch_get_main_queue(),^{SGFeatureDemo *self=weakSelf;if(!self)return;self.busy=NO;self.lastActionError=error;self.exporter=nil;if(success){self.exportedGIF=destination;if(sticker){NSError *stickerError=nil;self.playback.effects.sticker=[SGAnimatedImage imageWithURL:destination maxDecodedBytes:32*1024*1024 error:&stickerError];self.playback.effects.stickerStart=CMTimeGetSeconds(self.playback.currentTime);self.lastActionError=stickerError;}}});
    });
}
- (void)updateStatus {
    NSString *message=[NSString stringWithFormat:@"%@ | %.1fs | %.1fx | %lu frames%@%@",self.playback.kernel==SGPlaybackKernelFFmpeg?@"FFmpeg":@"Native",CMTimeGetSeconds(self.playback.currentTime),self.playback.rate,(unsigned long)self.playback.presentedFrameCount,[NSString stringWithFormat:@"%@ | PiP:%@ | %@ | BgFrames:%lu",self.busy?@" | Working":@"",self.playback.pictureInPictureActive?@"on":@"off",self.mediaURL.lastPathComponent?:@"",(unsigned long)self.playback.backgroundFrameCount],(self.lastActionError?:self.playback.error)?[NSString stringWithFormat:@" | Error: %@",(self.lastActionError?:self.playback.error).localizedDescription]:@""];
#if SGPLATFORM_TARGET_OS_MAC
    [self.statusLabel setStringValue:message];
#else
    [self.statusLabel setText:message];
#endif
}
- (void)close {[self.timer invalidate];self.timer=nil;[self.exporter cancel];[self.playback close];}
@end
