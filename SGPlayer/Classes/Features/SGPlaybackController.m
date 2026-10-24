#import "SGPlaybackController.h"
#import "SGPlayer.h"
#import <QuartzCore/QuartzCore.h>
#import <CoreMedia/CoreMedia.h>

@interface SGPlaybackController () <AVPictureInPictureSampleBufferPlaybackDelegate, AVPictureInPictureControllerDelegate>
@property (nonatomic, readwrite) SGPlaybackKernel kernel;
@property (nonatomic, strong, readwrite) SGMediaEffects *effects;
@property (nonatomic, strong, readwrite) SGPlayer *ffmpegPlayer;
@property (nonatomic, strong, readwrite) AVPlayer *nativePlayer;
@property (nonatomic, strong) AVPlayerItemVideoOutput *nativeOutput;
@property (nonatomic, strong) id nativeSourceBuffer;
@property (nonatomic, strong) SGPLFView *view;
@property (nonatomic, strong) NSURL *URL;
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic, strong) AVSampleBufferDisplayLayer *displayLayer;
@property (nonatomic, strong, readwrite) AVPictureInPictureController *pictureInPictureController;
@property (nonatomic, readwrite) BOOL playing;
@property (nonatomic, readwrite) NSUInteger presentedFrameCount;
@property (nonatomic, readwrite) NSUInteger backgroundFrameCount;
@property (nonatomic) BOOL background;
@property (nonatomic) BOOL previousVideoBackgroundPolicy;
@property (nonatomic, strong) id lastBuffer;
@property (nonatomic, strong) CIContext *context;
@property (nonatomic, strong) NSError *controllerError;
@property (nonatomic, copy, readwrite) NSArray<SGSubtitleTrack *> *subtitleTracks;
@property (nonatomic, readwrite) NSInteger selectedSubtitleTrack;
@property (nonatomic, readwrite) NSInteger selectedSecondarySubtitleTrack;
@property (nonatomic) NSUInteger generation;
@property (nonatomic) NSUInteger subtitleGeneration;
@property (nonatomic) CMTime lastOutputTime;
@property (nonatomic) NSUInteger foregroundRevision;
@property (nonatomic, strong) AVMediaSelectionGroup *nativeAudioGroup;
@property (nonatomic, copy, readwrite) SGNativePlaybackPolicy *nativePlaybackPolicy;
@end

@implementation SGPlaybackController
- (instancetype)initWithKernel:(SGPlaybackKernel)kernel view:(SGPLFView *)view {
    NSAssert(NSThread.isMainThread,@"Playback controller is main-thread only");
    if ((self = [super init])) {
        _kernel = kernel; _view = view; _rate = 1; _volume=1; _sourceLoadingTimeout=20; _selectedSubtitleTrack = -1; _selectedSecondarySubtitleTrack=-1; _subtitleTracks = @[];
        _effects = [[SGMediaEffects alloc] init]; _effects.kernel = kernel;
        _nativePlaybackPolicy=[SGNativePlaybackPolicy new];
        _context = [CIContext contextWithOptions:@{kCIContextCacheIntermediates:@NO}];
        _displayLayer = [[AVSampleBufferDisplayLayer alloc] init];
        _displayLayer.videoGravity = AVLayerVideoGravityResizeAspect;
#if SGPLATFORM_TARGET_OS_MAC
        view.wantsLayer = YES;
#endif
        _displayLayer.frame = view.bounds;
#if SGPLATFORM_TARGET_OS_MAC
        _displayLayer.autoresizingMask = kCALayerWidthSizable | kCALayerHeightSizable;
#endif
        [view.layer insertSublayer:_displayLayer atIndex:0];
        CMTimebaseRef timebase = NULL;
        CMTimebaseCreateWithSourceClock(NULL,CMClockGetHostTimeClock(),&timebase);
        _displayLayer.controlTimebase = timebase;
        if (timebase) CFRelease(timebase);
        AVPictureInPictureControllerContentSource *source = [[AVPictureInPictureControllerContentSource alloc] initWithSampleBufferDisplayLayer:_displayLayer playbackDelegate:self];
        _pictureInPictureController = [[AVPictureInPictureController alloc] initWithContentSource:source];
        _pictureInPictureController.delegate = self;
#if SGPLATFORM_TARGET_OS_IPHONE_OR_TV
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(didEnterBackground:) name:UIApplicationDidEnterBackgroundNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(willEnterForeground:) name:UIApplicationWillEnterForegroundNotification object:nil];
#endif
        [self setupBackend];
        __weak SGPlaybackController *weakSelf = self;
        _timer = [NSTimer timerWithTimeInterval:1.0/30 repeats:YES block:^(NSTimer *timer) { [weakSelf tick]; }];
        [NSRunLoop.mainRunLoop addTimer:_timer forMode:NSRunLoopCommonModes];
    } return self;
}
- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_timer invalidate];
    [_ffmpegPlayer replaceWithPlayerItem:nil];
    [_nativePlayer pause];
    [_displayLayer removeFromSuperlayer];
}
- (void)setupBackend {
    if (self.kernel == SGPlaybackKernelFFmpeg) {
        self.ffmpegPlayer = [[SGPlayer alloc] init];
        self.ffmpegPlayer.videoRenderer.view = self.view;
        self.ffmpegPlayer.videoRenderer.effects = self.effects;
        self.ffmpegPlayer.rate = self.rate;
        self.ffmpegPlayer.audioRenderer.volume=self.volume;
        __weak SGPlaybackController *weakSelf = self;
        self.ffmpegPlayer.videoRenderer.frameOutput = ^(SGVideoFrame *frame) {
            SGPlaybackController *self=weakSelf;
            if (!self.background || !self.pictureInPictureActive) return;
            CIImage *source=nil;
            if (frame.pixelBuffer) source=[CIImage imageWithCVPixelBuffer:frame.pixelBuffer];
            else {
                SGPLFImage *image=frame.image;
#if SGPLATFORM_TARGET_OS_MAC
                CGImageRef cg=[image CGImageForProposedRect:NULL context:nil hints:nil];
#else
                CGImageRef cg=image.CGImage;
#endif
                if (cg) source=[CIImage imageWithCGImage:cg];
            }
            [self composeBackgroundImage:source time:frame.timeStamp];
        };
        self.ffmpegPlayer.videoRenderer.composedFrameOutput = ^(CVPixelBufferRef buffer, CMTime time) { [weakSelf enqueueBuffer:buffer time:time]; };
    } else {
        self.nativePlayer = [[AVPlayer alloc] init];
        self.nativePlayer.automaticallyWaitsToMinimizeStalling = self.nativePlaybackPolicy.automaticallyWaitsToMinimizeStalling;
        self.nativePlayer.volume=self.volume;
        self.nativePlayer.allowsExternalPlayback=YES;
    }
}
- (CMTime)currentTime { return self.kernel == SGPlaybackKernelFFmpeg ? self.ffmpegPlayer.timeInfo.playback : self.nativePlayer.currentTime; }
- (CMTime)duration { return self.kernel == SGPlaybackKernelFFmpeg ? self.ffmpegPlayer.timeInfo.duration : self.nativePlayer.currentItem.duration; }
- (NSError *)error { return self.controllerError ?: self.effects.lastError ?: (self.kernel == SGPlaybackKernelFFmpeg ? self.ffmpegPlayer.error : self.nativePlayer.currentItem.error ?: self.nativePlayer.error); }
- (BOOL)pictureInPictureActive { return self.pictureInPictureController.isPictureInPictureActive; }
- (void)setRate:(float)rate {
    if (!isfinite(rate) || rate <= 0 || rate > 4) { self.controllerError = [NSError errorWithDomain:@"SGPlayback" code:1 userInfo:@{NSLocalizedDescriptionKey:@"Rate must be in (0,4]"}]; return; }
    _rate = rate;
    self.ffmpegPlayer.rate = rate;
    if (self.playing && self.nativePlayer.currentItem.status == AVPlayerItemStatusReadyToPlay) [self.nativePlayer playImmediatelyAtRate:rate];
    [self updatePiPClock];
}
- (SGNativePlaybackPolicy *)nativePlaybackPolicy { return [_nativePlaybackPolicy copy]; }
- (void)configureNativeItem:(AVPlayerItem *)item {
    SGNativePlaybackPolicy *policy=self.nativePlaybackPolicy;
    item.preferredPeakBitRate=policy.preferredPeakBitRate;
    item.preferredMaximumResolution=policy.preferredMaximumResolution;
    item.preferredForwardBufferDuration=policy.preferredForwardBufferDuration;
    item.canUseNetworkResourcesForLiveStreamingWhilePaused=policy.allowsNetworkWhilePaused;
}
- (BOOL)applyNativePlaybackPolicy:(SGNativePlaybackPolicy *)policy error:(NSError **)error {
    NSAssert(NSThread.isMainThread,@"Playback policy is main-thread only");
    SGNativePlaybackPolicy *snapshot=[policy copy];
    if(!snapshot||![snapshot validate:error])return NO;
    self.nativePlaybackPolicy=snapshot;
    self.nativePlayer.automaticallyWaitsToMinimizeStalling=snapshot.automaticallyWaitsToMinimizeStalling;
    [self configureNativeItem:self.nativePlayer.currentItem];return YES;
}
- (NSDictionary<NSString *,NSNumber *> *)nativePlaybackMetrics {
    NSAssert(NSThread.isMainThread,@"Playback metrics are main-thread only");
    AVPlayerItemAccessLogEvent *event=self.nativePlayer.currentItem.accessLog.events.lastObject;
    if(self.kernel!=SGPlaybackKernelNative||!event)return @{};
    NSMutableDictionary *metrics=[NSMutableDictionary dictionary];
    NSDictionary *values=@{@"observedBitrate":@(event.observedBitrate),@"indicatedBitrate":@(event.indicatedBitrate),@"bytesTransferred":@(event.numberOfBytesTransferred),@"mediaSecondsDownloaded":@(event.segmentsDownloadedDuration),@"droppedVideoFrames":@(event.numberOfDroppedVideoFrames),@"stalls":@(event.numberOfStalls)};
    [values enumerateKeysAndObjectsUsingBlock:^(NSString *key,NSNumber *value,BOOL *stop){if(isfinite(value.doubleValue)&&value.doubleValue>=0)metrics[key]=value;}];return metrics;
}
- (void)setVolume:(float)volume {
    if(!isfinite(volume))return;_volume=MIN(1,MAX(0,volume));self.ffmpegPlayer.audioRenderer.volume=_volume;self.nativePlayer.volume=_volume;
}
- (NSArray<NSString *> *)audioTrackTitles {
    if(self.kernel==SGPlaybackKernelNative){NSMutableArray *titles=[NSMutableArray array];for(AVMediaSelectionOption *option in self.nativeAudioGroup.options)[titles addObject:option.displayName];return titles;}
    NSMutableArray *titles=[NSMutableArray array];for(SGTrack *track in [SGTrack tracksWithTracks:self.ffmpegPlayer.currentItem.tracks type:SGMediaTypeAudio])[titles addObject:[NSString stringWithFormat:@"Audio %ld",(long)track.index]];return titles;
}
- (NSInteger)selectedAudioTrack {
    if(self.kernel==SGPlaybackKernelNative&&!self.nativeAudioGroup)return -1;
    if(self.kernel==SGPlaybackKernelNative){AVMediaSelectionOption *option=[self.nativePlayer.currentItem.currentMediaSelection selectedMediaOptionInMediaSelectionGroup:self.nativeAudioGroup];NSUInteger index=[self.nativeAudioGroup.options indexOfObject:option];return index==NSNotFound?-1:(NSInteger)index;}
    NSArray *tracks=[SGTrack tracksWithTracks:self.ffmpegPlayer.currentItem.tracks type:SGMediaTypeAudio];SGTrack *selected=self.ffmpegPlayer.currentItem.audioSelection.tracks.firstObject;if(!selected)return -1;
    for(NSUInteger i=0;i<tracks.count;i++)if(((SGTrack *)tracks[i]).index==selected.index)return i;return -1;
}
- (BOOL)selectAudioTrackAtIndex:(NSInteger)index {
    if(index<0||index>=(NSInteger)self.audioTrackTitles.count)return NO;
    if(self.kernel==SGPlaybackKernelNative)[self.nativePlayer.currentItem selectMediaOption:self.nativeAudioGroup.options[index] inMediaSelectionGroup:self.nativeAudioGroup];
    else {NSArray *tracks=[SGTrack tracksWithTracks:self.ffmpegPlayer.currentItem.tracks type:SGMediaTypeAudio];SGTrackSelection *selection=[SGTrackSelection new];selection.tracks=@[tracks[index]];selection.weights=@[@1];[self.ffmpegPlayer.currentItem setAudioSelection:selection action:SGTrackSelectionActionTracks|SGTrackSelectionActionWeights];}
    return YES;
}
- (void)replaceWithURL:(NSURL *)URL {
    NSAssert(NSThread.isMainThread,@"Main thread required");
    self.generation++; self.subtitleGeneration++; self.URL = URL; self.controllerError = nil;
    self.subtitleTracks = @[]; self.selectedSubtitleTrack = -1; self.effects.subtitles = @[]; self.effects.subtitleTrack = nil;
    self.selectedSecondarySubtitleTrack=-1;self.effects.secondarySubtitleTrack=nil;
    self.presentedFrameCount = 0; self.lastOutputTime = kCMTimeInvalid; self.lastBuffer = nil; self.nativeSourceBuffer = nil;
    [self.effects flush]; [self.displayLayer flushAndRemoveImage];
    if (self.kernel == SGPlaybackKernelFFmpeg) [self.ffmpegPlayer replaceWithURL:URL];
    else {
        AVPlayerItem *item = [AVPlayerItem playerItemWithURL:URL];
        self.nativeAudioGroup=nil;__weak typeof(self) weakSelf=self;
        [item.asset loadMediaSelectionGroupForMediaCharacteristic:AVMediaCharacteristicAudible completionHandler:^(AVMediaSelectionGroup *group,NSError *error){dispatch_async(dispatch_get_main_queue(),^{if(weakSelf.nativePlayer.currentItem==item)weakSelf.nativeAudioGroup=group;});}];
        self.nativeOutput = [[AVPlayerItemVideoOutput alloc] initWithPixelBufferAttributes:@{(id)kCVPixelBufferPixelFormatTypeKey:@(kCVPixelFormatType_32BGRA),(id)kCVPixelBufferIOSurfacePropertiesKey:@{}}];
        [item addOutput:self.nativeOutput];
        [self configureNativeItem:item];
        [self.nativePlayer replaceCurrentItemWithPlayerItem:item];
    }
    if (self.playing) [self play];
    [self updatePiPClock];
}
- (void)play { self.playing = YES; if (self.kernel == SGPlaybackKernelFFmpeg) [self.ffmpegPlayer play]; else if (self.nativePlayer.currentItem.status == AVPlayerItemStatusReadyToPlay) [self.nativePlayer playImmediatelyAtRate:self.rate]; else self.nativePlayer.rate = self.rate; [self updatePiPClock]; }
- (void)pause { self.playing = NO; [self.ffmpegPlayer pause]; [self.nativePlayer pause]; [self updatePiPClock]; }
- (void)updatePiPClock {
    CMTime time = self.currentTime;
    CMTimebaseRef base = self.displayLayer.controlTimebase;
    if (base && CMTIME_IS_NUMERIC(time)) {
        CMTimebaseSetTime(base,time); CMTimebaseSetRate(base,self.playing ? self.rate : 0);
    }
    [self.pictureInPictureController invalidatePlaybackState];
}
- (void)seekToTime:(CMTime)time completion:(void (^)(BOOL))completion {
    if (!CMTIME_IS_NUMERIC(time) || CMTimeCompare(time,kCMTimeZero)<0) { completion(NO); return; }
    self.generation++; NSUInteger generation = self.generation;
    [self.effects flush]; [self.displayLayer flushAndRemoveImage]; self.lastOutputTime = kCMTimeInvalid; self.lastBuffer = nil; self.nativeSourceBuffer = nil;
    __weak SGPlaybackController *weakSelf = self;
    void (^done)(BOOL) = ^(BOOL success) {
        dispatch_async(dispatch_get_main_queue(), ^{ SGPlaybackController *self = weakSelf; if (!self || self.generation != generation) { completion(NO); return; } [self updatePiPClock]; completion(success); });
    };
    if (self.kernel == SGPlaybackKernelFFmpeg) [self.ffmpegPlayer seekToTime:time toleranceBefor:kCMTimeZero toleranceAfter:kCMTimeZero result:^(CMTime value,NSError *error){done(!error);}];
    else [self.nativePlayer seekToTime:time toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero completionHandler:done];
}
- (void)replaceWithURL:(NSURL *)URL atTime:(CMTime)time completion:(void (^)(BOOL))completion {
    [self replaceWithURL:URL atTime:time preservingSubtitles:NO completion:completion];
}
- (void)replaceWithURL:(NSURL *)URL atTime:(CMTime)time preservingSubtitles:(BOOL)preserve completion:(void (^)(BOOL))completion {
    NSArray *tracks=preserve?self.subtitleTracks:nil;NSInteger primary=self.selectedSubtitleTrack,secondary=self.selectedSecondarySubtitleTrack;
    [self replaceWithURL:URL];
    if(preserve){self.subtitleTracks=tracks;[self selectSubtitleTrack:primary];[self selectSecondarySubtitleTrack:secondary];}
    NSUInteger generation=self.generation;
    __weak SGPlaybackController *weakSelf=self;
    double timeout=isfinite(self.sourceLoadingTimeout)?MIN(120,MAX(1,self.sourceLoadingTimeout)):20;
    __block NSTimeInterval deadline=CACurrentMediaTime()+timeout;__block NSUInteger foregroundRevision=self.foregroundRevision;
    NSTimer *timer=[NSTimer timerWithTimeInterval:0.05 repeats:YES block:^(NSTimer *timer) {
        SGPlaybackController *self=weakSelf;
        if(!self||self.generation!=generation){[timer invalidate];completion(NO);return;}
        if(foregroundRevision!=self.foregroundRevision){foregroundRevision=self.foregroundRevision;deadline=CACurrentMediaTime()+timeout;}
        BOOL ready=self.kernel==SGPlaybackKernelFFmpeg ? self.ffmpegPlayer.sstateInfo.player==SGPlayerStateReady : self.nativePlayer.currentItem.status==AVPlayerItemStatusReadyToPlay;
        if(self.error||(!ready&&CACurrentMediaTime()>deadline)){
            [timer invalidate];
            if(!self.error)self.controllerError=[NSError errorWithDomain:@"SGPlayback" code:2 userInfo:@{NSLocalizedDescriptionKey:@"Source readiness timed out"}];
            completion(NO);return;
        }
        if(!ready)return;
        [timer invalidate];
        CMTime target=CMTIME_IS_NUMERIC(time)?CMTimeMaximum(kCMTimeZero,time):kCMTimeZero;
        if(CMTIME_IS_NUMERIC(self.duration)&&CMTimeCompare(self.duration,kCMTimeZero)>0)
            target=CMTimeMinimum(target,CMTimeMaximum(kCMTimeZero,CMTimeSubtract(self.duration,CMTimeMake(1,10))));
        // Zero needs no seek, which also allows unseekable live inputs to start.
        if(CMTimeCompare(target,kCMTimeZero)==0){completion(YES);return;}
        [self seekToTime:target completion:completion];
    }];
    [NSRunLoop.mainRunLoop addTimer:timer forMode:NSRunLoopCommonModes];
}
- (void)resetToKernel:(SGPlaybackKernel)kernel {
    NSAssert(NSThread.isMainThread,@"Main thread required");
    self.generation++;self.subtitleGeneration++;
    self.ffmpegPlayer.videoRenderer.composedFrameOutput=nil;
    self.ffmpegPlayer.videoRenderer.frameOutput=nil;
    [self.ffmpegPlayer replaceWithPlayerItem:nil];[self.nativePlayer pause];
    [self.nativePlayer replaceCurrentItemWithPlayerItem:nil];
    self.ffmpegPlayer=nil;self.nativePlayer=nil;self.nativeOutput=nil;self.nativeAudioGroup=nil;self.URL=nil;
    self.kernel=kernel;self.effects.kernel=kernel;[self.effects flush];
    self.lastBuffer=nil;self.nativeSourceBuffer=nil;self.controllerError=nil;
    [self.displayLayer flushAndRemoveImage];[self setupBackend];
}
- (void)switchToKernel:(SGPlaybackKernel)kernel completion:(void (^)(BOOL))completion {
    if(kernel==self.kernel){completion(YES);return;}
    CMTime time=self.currentTime;NSURL *URL=self.URL;
    NSArray *tracks=self.subtitleTracks;NSInteger selected=self.selectedSubtitleTrack,secondary=self.selectedSecondarySubtitleTrack;
    [self resetToKernel:kernel];
    if(!URL){completion(YES);return;}
    [self replaceWithURL:URL atTime:time completion:completion];
    self.subtitleTracks=tracks;[self selectSubtitleTrack:selected];[self selectSecondarySubtitleTrack:secondary];
}
- (void)loadSubtitlesFromURL:(NSURL *)URL completion:(void (^)(NSError *))completion {
    NSUInteger generation = ++self.subtitleGeneration;
    __weak SGPlaybackController *weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0), ^{
        NSError *error = nil; NSArray *tracks = [SGSubtitleReader readURL:URL error:&error];
        dispatch_async(dispatch_get_main_queue(), ^{
            SGPlaybackController *self = weakSelf;
            if (!self || generation != self.subtitleGeneration) { completion([NSError errorWithDomain:NSCocoaErrorDomain code:NSUserCancelledError userInfo:nil]); return; }
            if (!error) { self.subtitleTracks = tracks; self.selectedSubtitleTrack = -1; self.effects.subtitles = @[]; self.effects.subtitleTrack = nil; self.selectedSecondarySubtitleTrack=-1;self.effects.secondarySubtitleTrack=nil; }
            completion(error);
        });
    });
}
- (BOOL)selectSubtitleTrack:(NSInteger)index {
    if (index == -1) { self.selectedSubtitleTrack = -1; self.effects.subtitles = @[]; self.effects.subtitleTrack = nil; return YES; }
    for (SGSubtitleTrack *track in self.subtitleTracks) if (track.index == index) { self.selectedSubtitleTrack = index; self.effects.subtitles = track.cues; self.effects.subtitleTrack = track; return YES; }
    return NO;
}
- (BOOL)selectSecondarySubtitleTrack:(NSInteger)index {
    if(index==-1){self.selectedSecondarySubtitleTrack=-1;self.effects.secondarySubtitleTrack=nil;return YES;}
    for(SGSubtitleTrack *track in self.subtitleTracks)if(track.index==index){self.selectedSecondarySubtitleTrack=index;self.effects.secondarySubtitleTrack=track;return YES;}
    return NO;
}
- (void)tick {
    self.displayLayer.frame = self.view.bounds;
    if (self.playing && self.kernel == SGPlaybackKernelFFmpeg && (self.ffmpegPlayer.sstateInfo.playback & SGPlaybackStateFinished)) { self.playing = NO; [self updatePiPClock]; }
    if (self.playing && self.kernel == SGPlaybackKernelNative && self.nativePlayer.currentItem.status == AVPlayerItemStatusReadyToPlay && self.nativePlayer.rate == 0 && CMTIME_IS_NUMERIC(self.duration) && CMTimeCompare(self.currentTime,self.duration)>=0) { self.playing = NO; [self updatePiPClock]; }
    if (self.kernel != SGPlaybackKernelNative || !self.nativeOutput) return;
    CMTime time = self.nativePlayer.currentTime;
    BOOL fresh=[self.nativeOutput hasNewPixelBufferForItemTime:time];
    CVPixelBufferRef source = fresh ? [self.nativeOutput copyPixelBufferForItemTime:time itemTimeForDisplay:NULL] : (!self.playing && self.nativeSourceBuffer ? CVPixelBufferRetain((__bridge CVPixelBufferRef)self.nativeSourceBuffer) : NULL);
    if (fresh && source) self.nativeSourceBuffer=CFBridgingRelease(CVPixelBufferRetain(source));
    if (source) {
        CVPixelBufferRef composed = [self.effects copyPixelBufferForImage:[CIImage imageWithCVPixelBuffer:source] atTime:time];
        if (composed) { [self enqueueBuffer:composed time:time]; CVPixelBufferRelease(composed); }
        CVPixelBufferRelease(source);
    }
}
- (void)didEnterBackground:(NSNotification *)notification {
    self.background=YES;
    self.effects.softwareRendering=YES;
    self.ffmpegPlayer.videoRenderer.backgroundOutputEnabled=YES;
}
- (void)willEnterForeground:(NSNotification *)notification {
    self.foregroundRevision++;
    self.background=NO;
    self.effects.softwareRendering=NO;
    self.ffmpegPlayer.videoRenderer.backgroundOutputEnabled=NO;
    if(self.playing)[self play];
    [self updatePiPClock];
}
- (void)composeBackgroundImage:(CIImage *)source time:(CMTime)time {
    if (!source) return;
    CGFloat scale=MIN(1,640/MAX(source.extent.size.width,source.extent.size.height));
    source=[source imageByApplyingTransform:CGAffineTransformMakeScale(scale,scale)];
    CVPixelBufferRef buffer=[self.effects copyPixelBufferForImage:source atTime:time];
    if(buffer){[self enqueueBuffer:buffer time:time];CVPixelBufferRelease(buffer);}
}
- (void)enqueueBuffer:(CVPixelBufferRef)buffer time:(CMTime)time {
    if (!CMTIME_IS_NUMERIC(time)) return;
    CMVideoFormatDescriptionRef format = NULL; CMSampleBufferRef sample = NULL;
    if (CMVideoFormatDescriptionCreateForImageBuffer(NULL,buffer,&format) != noErr) return;
    CMSampleTimingInfo timing = {CMTimeMake(1,30),time,kCMTimeInvalid};
    OSStatus status = CMSampleBufferCreateReadyWithImageBuffer(NULL,buffer,format,&timing,&sample);
    CFRelease(format);
    if (status != noErr) return;
    CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sample,YES);
    if (attachments && CFArrayGetCount(attachments)) CFDictionarySetValue((CFMutableDictionaryRef)CFArrayGetValueAtIndex(attachments,0),kCMSampleAttachmentKey_DisplayImmediately,kCFBooleanTrue);
    if (self.displayLayer.status == AVQueuedSampleBufferRenderingStatusFailed) [self.displayLayer flush];
    if (self.displayLayer.readyForMoreMediaData) {
        [self.displayLayer enqueueSampleBuffer:sample];
        self.presentedFrameCount++;
        if (self.background) self.backgroundFrameCount++;
    }
    CFRelease(sample);
    self.lastOutputTime = time;
    self.lastBuffer = CFBridgingRelease(CVPixelBufferRetain(buffer));
}
- (SGPLFImage *)currentImage {
    if (!self.lastBuffer) return self.ffmpegPlayer.videoRenderer.currentImage;
    CVPixelBufferRef buffer=(__bridge CVPixelBufferRef)self.lastBuffer;
    CIImage *source=[CIImage imageWithCVPixelBuffer:buffer];
    CGImageRef image=[self.context createCGImage:source fromRect:source.extent];
    if (!image) return nil;
#if SGPLATFORM_TARGET_OS_MAC
    SGPLFImage *result=[[NSImage alloc]initWithCGImage:image size:NSZeroSize];
#else
    SGPLFImage *result=[UIImage imageWithCGImage:image];
#endif
    CGImageRelease(image);return result;
}

- (BOOL)startPictureInPicture:(NSError **)error {
    if (![AVPictureInPictureController isPictureInPictureSupported]) {
        if (error) *error = [NSError errorWithDomain:@"SGPictureInPicture" code:1 userInfo:@{NSLocalizedDescriptionKey:@"Picture in Picture is unsupported on this system/device"}]; return NO;
    }
    if (!self.pictureInPictureController.isPictureInPicturePossible) {
        if (error) *error = [NSError errorWithDomain:@"SGPictureInPicture" code:1 userInfo:@{NSLocalizedDescriptionKey:@"Picture in Picture is not ready for the visible playback source"}]; return NO;
    }
    [self updatePiPClock]; [self.pictureInPictureController startPictureInPicture]; return YES;
}
- (void)stopPictureInPicture { [self.pictureInPictureController stopPictureInPicture]; }
- (void)close { self.generation++; self.subtitleGeneration++; [self pause]; [self stopPictureInPicture]; [_timer invalidate]; _timer = nil; self.ffmpegPlayer.videoRenderer.composedFrameOutput = nil; [self.ffmpegPlayer replaceWithPlayerItem:nil]; [self.nativePlayer replaceCurrentItemWithPlayerItem:nil]; [self.displayLayer flushAndRemoveImage]; [self.displayLayer removeFromSuperlayer]; self.lastBuffer = nil; self.nativeSourceBuffer = nil; [self.effects flush]; }
- (void)pictureInPictureController:(AVPictureInPictureController *)controller setPlaying:(BOOL)playing { if (playing) [self play]; else [self pause]; }
- (CMTimeRange)pictureInPictureControllerTimeRangeForPlayback:(AVPictureInPictureController *)controller { CMTime duration = self.duration; return CMTIME_IS_NUMERIC(duration) ? CMTimeRangeMake(kCMTimeZero,duration) : CMTimeRangeMake(kCMTimeZero,kCMTimePositiveInfinity); }
- (BOOL)pictureInPictureControllerIsPlaybackPaused:(AVPictureInPictureController *)controller { return !self.playing; }
- (void)pictureInPictureController:(AVPictureInPictureController *)controller didTransitionToRenderSize:(CMVideoDimensions)size {}
- (void)pictureInPictureController:(AVPictureInPictureController *)controller skipByInterval:(CMTime)interval completionHandler:(void (^)(void))completion { CMTime target = CMTimeMaximum(kCMTimeZero,CMTimeAdd(self.currentTime,interval)); if (CMTIME_IS_NUMERIC(self.duration)) target = CMTimeMinimum(target,self.duration); [self seekToTime:target completion:^(BOOL success){completion();}]; }
- (void)pictureInPictureControllerDidStartPictureInPicture:(AVPictureInPictureController *)controller {
#if SGPLATFORM_TARGET_OS_IPHONE_OR_TV
    self.previousVideoBackgroundPolicy=self.ffmpegPlayer.pausesWhenEnteredBackgroundIfNoAudioTrack;
    self.ffmpegPlayer.pausesWhenEnteredBackgroundIfNoAudioTrack=NO;
#endif
    if (self.pictureInPictureChanged) self.pictureInPictureChanged(YES,nil); }
- (void)pictureInPictureControllerDidStopPictureInPicture:(AVPictureInPictureController *)controller {
#if SGPLATFORM_TARGET_OS_IPHONE_OR_TV
    self.ffmpegPlayer.pausesWhenEnteredBackgroundIfNoAudioTrack=self.previousVideoBackgroundPolicy;
#endif
    if (self.pictureInPictureChanged) self.pictureInPictureChanged(NO,nil); }
- (void)pictureInPictureController:(AVPictureInPictureController *)controller failedToStartPictureInPictureWithError:(NSError *)error { self.controllerError = error; if (self.pictureInPictureChanged) self.pictureInPictureChanged(NO,error); }
- (void)pictureInPictureController:(AVPictureInPictureController *)controller restoreUserInterfaceForPictureInPictureStopWithCompletionHandler:(void (^)(BOOL))completion { if (self.restoreInterface) self.restoreInterface(completion); else completion(YES); }
@end
