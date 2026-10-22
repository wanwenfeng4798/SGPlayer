#import "SGPlaybackController.h"
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
@property (nonatomic) NSUInteger generation;
@property (nonatomic) NSUInteger subtitleGeneration;
@property (nonatomic) CMTime lastOutputTime;
@end

@implementation SGPlaybackController
- (instancetype)initWithKernel:(SGPlaybackKernel)kernel view:(SGPLFView *)view {
    NSAssert(NSThread.isMainThread,@"Playback controller is main-thread only");
    if ((self = [super init])) {
        _kernel = kernel; _view = view; _rate = 1; _selectedSubtitleTrack = -1; _subtitleTracks = @[];
        _effects = [[SGMediaEffects alloc] init]; _effects.kernel = kernel;
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
        self.nativePlayer.automaticallyWaitsToMinimizeStalling = YES;
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
- (void)replaceWithURL:(NSURL *)URL {
    NSAssert(NSThread.isMainThread,@"Main thread required");
    self.generation++; self.subtitleGeneration++; self.URL = URL; self.controllerError = nil;
    self.subtitleTracks = @[]; self.selectedSubtitleTrack = -1; self.effects.subtitles = @[]; self.effects.subtitleTrack = nil;
    self.presentedFrameCount = 0; self.lastOutputTime = kCMTimeInvalid; self.lastBuffer = nil; self.nativeSourceBuffer = nil;
    [self.effects flush]; [self.displayLayer flushAndRemoveImage];
    if (self.kernel == SGPlaybackKernelFFmpeg) [self.ffmpegPlayer replaceWithURL:URL];
    else {
        AVPlayerItem *item = [AVPlayerItem playerItemWithURL:URL];
        self.nativeOutput = [[AVPlayerItemVideoOutput alloc] initWithPixelBufferAttributes:@{(id)kCVPixelBufferPixelFormatTypeKey:@(kCVPixelFormatType_32BGRA),(id)kCVPixelBufferIOSurfacePropertiesKey:@{}}];
        [item addOutput:self.nativeOutput];
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
- (void)switchToKernel:(SGPlaybackKernel)kernel completion:(void (^)(BOOL))completion {
    if (kernel == self.kernel) { completion(YES); return; }
    CMTime time = self.currentTime; BOOL playing = self.playing; NSURL *URL = self.URL;
    [self.ffmpegPlayer replaceWithPlayerItem:nil]; [self.nativePlayer pause];
    self.ffmpegPlayer.videoRenderer.composedFrameOutput = nil;
    self.ffmpegPlayer = nil; self.nativePlayer = nil; self.nativeOutput = nil;
    self.kernel = kernel; self.effects.kernel = kernel; [self.effects flush]; [self setupBackend];
    NSArray *tracks = self.subtitleTracks; NSInteger selected = self.selectedSubtitleTrack;
    if (!URL) { completion(YES); return; }
    self.playing = NO; [self replaceWithURL:URL]; self.subtitleTracks = tracks; [self selectSubtitleTrack:selected];
    NSUInteger generation = self.generation;
    // Readiness is polled on the main run loop with a bounded deadline.
    __weak SGPlaybackController *weakSelf = self;
    NSTimeInterval deadline = NSDate.timeIntervalSinceReferenceDate + 20;
    NSTimer *timer = [NSTimer timerWithTimeInterval:0.05 repeats:YES block:^(NSTimer *timer) {
        SGPlaybackController *self = weakSelf;
        if (!self || self.generation != generation) { [timer invalidate]; completion(NO); return; }
        BOOL ready = self.kernel == SGPlaybackKernelFFmpeg ? self.ffmpegPlayer.sstateInfo.player == SGPlayerStateReady : self.nativePlayer.currentItem.status == AVPlayerItemStatusReadyToPlay;
        if (self.error || NSDate.timeIntervalSinceReferenceDate > deadline) { [timer invalidate]; completion(NO); return; }
        if (ready) { [timer invalidate]; [self seekToTime:CMTIME_IS_NUMERIC(time) ? time : kCMTimeZero completion:^(BOOL success) { if (playing) [self play]; completion(success); }]; }
    }];
    [NSRunLoop.mainRunLoop addTimer:timer forMode:NSRunLoopCommonModes];
}
- (void)loadSubtitlesFromURL:(NSURL *)URL completion:(void (^)(NSError *))completion {
    NSUInteger generation = ++self.subtitleGeneration;
    __weak SGPlaybackController *weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0), ^{
        NSError *error = nil; NSArray *tracks = [SGSubtitleReader readURL:URL error:&error];
        dispatch_async(dispatch_get_main_queue(), ^{
            SGPlaybackController *self = weakSelf;
            if (!self || generation != self.subtitleGeneration) { completion([NSError errorWithDomain:NSCocoaErrorDomain code:NSUserCancelledError userInfo:nil]); return; }
            if (!error) { self.subtitleTracks = tracks; self.selectedSubtitleTrack = -1; self.effects.subtitles = @[]; self.effects.subtitleTrack = nil; }
            completion(error);
        });
    });
}
- (BOOL)selectSubtitleTrack:(NSInteger)index {
    if (index == -1) { self.selectedSubtitleTrack = -1; self.effects.subtitles = @[]; self.effects.subtitleTrack = nil; return YES; }
    for (SGSubtitleTrack *track in self.subtitleTracks) if (track.index == index) { self.selectedSubtitleTrack = index; self.effects.subtitles = track.cues; self.effects.subtitleTrack = track; return YES; }
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
    self.background=NO;
    self.effects.softwareRendering=NO;
    self.ffmpegPlayer.videoRenderer.backgroundOutputEnabled=NO;
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
