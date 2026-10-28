#import "SGPlaybackSession.h"
#import "SGPlayer.h"
#import <QuartzCore/QuartzCore.h>
#import "SGFFmpeg.h"

@implementation SGPlaybackRendition
- (instancetype)initWithIdentifier:(NSString *)identifier title:(NSString *)title URL:(NSURL *)URL {
    NSParameterAssert(identifier.length && URL);
    if ((self = [super init])) {
        _identifier = [identifier copy];
        _title = [title copy];
        _URL = [URL copy];
    }
    return self;
}
@end
@implementation SGPlaybackItem
- (instancetype)initWithIdentifier:(NSString *)identifier
                             title:(NSString *)title
                        renditions:(NSArray<SGPlaybackRendition *> *)renditions {
    NSParameterAssert(identifier.length && renditions.count);
    if ((self = [super init])) {
        _identifier = [identifier copy];
        _title = [title copy];
        _renditions = [renditions copy];
    }
    return self;
}
@end

static NSError *SGSessionError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:@"SGPlaybackSession" code:code userInfo:@{NSLocalizedDescriptionKey : message}];
}
@interface SGPlaybackSession ()
@property(nonatomic, strong, readwrite) SGPlaybackController *controller;
@property(nonatomic, copy, readwrite) NSArray<SGPlaybackItem *> *items;
@property(nonatomic, readwrite) NSInteger selectedIndex;
@property(nonatomic, readwrite) NSInteger selectedRendition;
@property(nonatomic, readwrite) SGPlaybackSessionState state;
@property(nonatomic, strong, readwrite) NSError *error;
@property(nonatomic, readwrite) CMTimeRange loopRange;
@property(nonatomic, strong) NSUserDefaults *resumeStore;
@property(nonatomic, strong) NSTimer *timer;
@property(nonatomic, strong) NSMutableArray<NSDictionary *> *events;
@property(nonatomic) CFTimeInterval openedAt;
@property(nonatomic) CFTimeInterval firstFrameAt;
@property(nonatomic) CFTimeInterval lastProgressAt;
@property(nonatomic) CFTimeInterval stalledAt;
@property(nonatomic) CFTimeInterval stalledDuration;
@property(nonatomic) CFTimeInterval lastSavedAt;
@property(nonatomic) double lastPosition;
@property(nonatomic) double recoveryPosition;
@property(nonatomic) NSUInteger stallCount;
@property(nonatomic) NSUInteger fallbackCount;
@property(nonatomic) NSUInteger revision;
@property(nonatomic) BOOL transitioning;
@property(nonatomic) BOOL looping;
@property(nonatomic) BOOL closed;
@property(nonatomic, strong) AVURLAsset *selectionAsset;
@end

@implementation SGPlaybackSession
- (instancetype)initWithController:(SGPlaybackController *)controller resumeStore:(NSUserDefaults *)store {
    NSAssert(NSThread.isMainThread, @"Main thread required");
    NSParameterAssert(controller);
    if ((self = [super init])) {
        _controller = controller;
        _kernelPolicy = SGKernelSelectionPolicyAutomatic;
        _resumeStore = store;
        _items = @[];
        _events = [NSMutableArray array];
        _selectedIndex = NSNotFound;
        _selectedRendition = NSNotFound;
        _loopRange = kCMTimeRangeInvalid;
        _loadingTimeout = 20;
        _resumeEnabled = YES;
        _automaticAdvance = YES;
#if SGPLATFORM_TARGET_OS_IPHONE_OR_TV
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(resumeMonitoring:)
                                                     name:UIApplicationWillEnterForegroundNotification
                                                   object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(suspendMonitoring:)
                                                     name:UIApplicationDidEnterBackgroundNotification
                                                   object:nil];
#endif
        __weak typeof(self) weakSelf = self;
        _timer = [NSTimer timerWithTimeInterval:0.1
                                        repeats:YES
                                          block:^(NSTimer *timer) {
                                              [weakSelf tick];
                                          }];
        [NSRunLoop.mainRunLoop addTimer:_timer forMode:NSRunLoopCommonModes];
    }
    return self;
}
- (void)dealloc {
    [_timer invalidate];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}
- (void)resumeMonitoring:(NSNotification *)notification {
    self.lastProgressAt = CACurrentMediaTime();
    self.stalledAt = 0;
}
- (void)suspendMonitoring:(NSNotification *)notification {
    if (self.stalledAt) {
        self.stalledDuration += CACurrentMediaTime() - self.stalledAt;
        self.stalledAt = 0;
    }
}
- (void)event:(NSString *)name details:(NSDictionary *)details {
    NSMutableDictionary *event = [details mutableCopy];
    event[@"event"] = name;
    event[@"elapsedSeconds"] = @(MAX(0, CACurrentMediaTime() - self.openedAt));
    [self.events addObject:event];
    if (self.events.count > 128)
        [self.events removeObjectAtIndex:0];
}
- (void)updateState:(SGPlaybackSessionState)state {
    if (self.state == state)
        return;
    self.state = state;
    [self event:@"state" details:@{@"value" : @(state)}];
    if (self.changed)
        self.changed(self);
}
- (BOOL)loadItems:(NSArray<SGPlaybackItem *> *)items
       startIndex:(NSInteger)index
         autoPlay:(BOOL)autoPlay
            error:(NSError **)error {
    NSAssert(NSThread.isMainThread, @"Main thread required");
    NSMutableSet *identifiers = [NSMutableSet set];
    BOOL valid = items.count && index >= 0 && index < (NSInteger)items.count && !self.closed;
    for (SGPlaybackItem *item in items) {
        if (![item isKindOfClass:SGPlaybackItem.class] || !item.identifier.length || !item.renditions.count ||
            [identifiers containsObject:item.identifier]) {
            valid = NO;
            break;
        }
        [identifiers addObject:item.identifier];
        NSMutableSet *variants = [NSMutableSet set];
        for (SGPlaybackRendition *variant in item.renditions) {
            if (![variant isKindOfClass:SGPlaybackRendition.class] || !variant.URL.scheme.length ||
                !variant.identifier.length || [variants containsObject:variant.identifier]) {
                valid = NO;
                break;
            }
            [variants addObject:variant.identifier];
        }
    }
    if (!valid) {
        if (error)
            *error = SGSessionError(1, @"Playlist requires unique identifiers, valid URLs and an in-range start index");
        return NO;
    }
    [self saveResumePosition];
    self.items = items;
    self.selectedIndex = NSNotFound;
    if (autoPlay)
        [self.controller play];
    else
        [self.controller pause];
    return [self selectItemAtIndex:index];
}
- (SGPlaybackItem *)currentItem {
    return self.selectedIndex >= 0 && self.selectedIndex < (NSInteger)self.items.count ? self.items[self.selectedIndex]
                                                                                       : nil;
}
- (double)savedPosition {
    if (!self.resumeEnabled || !self.resumeStore)
        return 0;
    NSDictionary *entry = [self.resumeStore dictionaryForKey:@"SGPlayer.resume.v1"][[self currentItem].identifier];
    if (![entry isKindOfClass:NSDictionary.class])
        return 0;
    double value = [entry[@"seconds"] doubleValue];
    return isfinite(value) && value > 0 ? value : 0;
}
- (BOOL)selectItemAtIndex:(NSInteger)index {
    NSAssert(NSThread.isMainThread, @"Main thread required");
    if (self.closed || index < 0 || index >= (NSInteger)self.items.count)
        return NO;
    [self saveResumePosition];
    self.selectedIndex = index;
    self.selectedRendition = 0;
    self.loopRange = kCMTimeRangeInvalid;
    self.looping = NO;
    self.fallbackCount = 0;
    self.stallCount = 0;
    self.openedAt = CACurrentMediaTime();
    self.firstFrameAt = 0;
    self.stalledAt = 0;
    self.stalledDuration = 0;
    self.lastPosition = -1;
    self.lastProgressAt = self.openedAt;
    self.error = nil;
    [self event:@"item" details:@{@"index" : @(index)}];
    [self openURL:[self currentItem].renditions.firstObject.URL
            position:[self savedPosition]
        chooseKernel:YES
          completion:^(BOOL success){
          }];
    return YES;
}
- (void)openURL:(NSURL *)URL position:(double)position chooseKernel:(BOOL)choose completion:(void (^)(BOOL))completion {
    self.controller.sourceLoadingTimeout = self.loadingTimeout;
    NSUInteger revision = ++self.revision;
    self.transitioning = YES;
    self.looping = NO;
    self.error = nil;
    self.recoveryPosition = MAX(0, position);
    self.lastProgressAt = CACurrentMediaTime();
    [self updateState:SGPlaybackSessionStateLoading];
    __weak typeof(self) weakSelf = self;
    void (^replace)(void) = ^{
        SGPlaybackSession *self = weakSelf;
        if (!self || self.closed || revision != self.revision) {
            completion(NO);
            return;
        }
        [self.controller replaceWithURL:URL
                                 atTime:CMTimeMakeWithSeconds(MAX(0, position), 1000)
                    preservingSubtitles:!choose
                             completion:^(BOOL success) {
                                 SGPlaybackSession *self = weakSelf;
                                 if (!self || self.closed || revision != self.revision) {
                                     completion(NO);
                                     return;
                                 }
                                 self.transitioning = NO;
                                 self.lastProgressAt = CACurrentMediaTime();
                                 self.error = success ? nil
                                                      : (self.controller.error
                                                             ?: SGSessionError(2, @"Source did not become ready"));
                                 if (success)
                                     [self updateState:self.controller.playing ? SGPlaybackSessionStatePlaying
                                                                               : SGPlaybackSessionStatePaused];
                                 completion(success);
                             }];
    };
    [self.selectionAsset cancelLoading];
    self.selectionAsset = nil;
    void (^select)(SGPlaybackKernel) = ^(SGPlaybackKernel kernel) {
        SGPlaybackSession *self = weakSelf;
        if (!self || self.closed || revision != self.revision) { completion(NO); return; }
        if (kernel != self.controller.kernel) [self.controller resetToKernel:kernel];
        replace();
    };
    if (!choose || self.kernelPolicy == SGKernelSelectionPolicyManual) {
        select(self.controller.kernel);
    } else if (self.requiresFFmpeg || self.kernelPolicy == SGKernelSelectionPolicyPreferFFmpeg) {
        select(SGPlaybackKernelFFmpeg);
    } else {
        [self.controller resetToKernel:self.controller.kernel];
        // AVFoundation inspects the container and codecs on this device, including URLs without extensions.
        AVURLAsset *asset = [AVURLAsset URLAssetWithURL:URL options:nil];
        self.selectionAsset = asset;
        __block BOOL finished = NO;
        void (^finish)(BOOL) = ^(BOOL native) {
            if (finished) return;
            finished = YES;
            [asset cancelLoading];
            select(native ? SGPlaybackKernelNative : SGPlaybackKernelFFmpeg);
        };
        [asset loadValuesAsynchronouslyForKeys:@[@"playable", @"tracks"] completionHandler:^{
            dispatch_async(dispatch_get_main_queue(), ^{
                BOOL native = [asset statusOfValueForKey:@"playable" error:nil] == AVKeyValueStatusLoaded &&
                              [asset statusOfValueForKey:@"tracks" error:nil] == AVKeyValueStatusLoaded && asset.playable;
                if (native) for (AVAssetTrack *track in asset.tracks) {
                    if (([track.mediaType isEqual:AVMediaTypeVideo] || [track.mediaType isEqual:AVMediaTypeAudio]) &&
                        !track.decodable) { native = NO; break; }
                }
                finish(native);
            });
        }];
        double timeout = isfinite(self.loadingTimeout) ? MIN(5, MAX(1, self.loadingTimeout)) : 5;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ finish(NO); });
    }
}

- (BOOL)next {
    if (![self currentItem])
        return NO;
    NSInteger index = self.selectedIndex + 1;
    if (index >= (NSInteger)self.items.count) {
        if (self.loopMode != SGPlaybackLoopModeAll)
            return NO;
        index = 0;
    }
    return [self selectItemAtIndex:index];
}
- (BOOL)previous {
    return [self selectItemAtIndex:self.selectedIndex - 1];
}
- (void)selectRenditionAtIndex:(NSInteger)index completion:(void (^)(BOOL))completion {
    SGPlaybackItem *item = [self currentItem];
    if (self.closed || self.transitioning || index < 0 || index >= (NSInteger)item.renditions.count) {
        completion(NO);
        return;
    }
    if (index == self.selectedRendition) {
        completion(YES);
        return;
    }
    NSInteger previous = self.selectedRendition;
    double time = CMTimeGetSeconds(self.controller.currentTime);
    self.selectedRendition = index;
    self.fallbackCount = 0;
    [self event:@"rendition" details:@{@"from" : @(previous), @"to" : @(index)}];
    [self openURL:item.renditions[index].URL position:isfinite(time) ? time : 0 chooseKernel:NO completion:completion];
}
- (BOOL)setLoopFrom:(CMTime)start to:(CMTime)end {
    double a = CMTimeGetSeconds(start), b = CMTimeGetSeconds(end),
           duration = CMTimeGetSeconds(self.controller.duration);
    if (!isfinite(a) || !isfinite(b) || a < 0 || b <= a || (isfinite(duration) && duration > 0 && b > duration))
        return NO;
    self.loopRange = CMTimeRangeFromTimeToTime(start, end);
    self.looping = NO;
    return YES;
}
- (void)switchToKernel:(SGPlaybackKernel)kernel completion:(void (^)(BOOL))completion {
    if (self.closed || self.transitioning) {
        completion(NO);
        return;
    }
    self.transitioning = YES;
    self.looping = NO;
    NSUInteger revision = ++self.revision;
    self.error = nil;
    [self updateState:SGPlaybackSessionStateLoading];
    [self.controller switchToKernel:kernel
                         completion:^(BOOL success) {
                             if (self.closed || revision != self.revision) {
                                 completion(NO);
                                 return;
                             }
                             self.transitioning = NO;
                             self.lastProgressAt = CACurrentMediaTime();
                             self.error =
                                 success ? nil : (self.controller.error ?: SGSessionError(2, @"Kernel switch failed"));
                             if (success)
                                 [self updateState:self.controller.playing ? SGPlaybackSessionStatePlaying
                                                                           : SGPlaybackSessionStatePaused];
                             completion(success);
                         }];
}
- (void)clearLoop {
    self.loopRange = kCMTimeRangeInvalid;
    self.looping = NO;
}
- (void)play {
    if (!self.closed)
        [self.controller play];
}
- (void)pause {
    [self.controller pause];
    if (!self.transitioning && [self currentItem])
        [self updateState:SGPlaybackSessionStatePaused];
    [self saveResumePosition];
}
- (void)retry {
    if (![self currentItem] || self.closed)
        return;
    double time = CMTimeGetSeconds(self.controller.currentTime);
    self.fallbackCount = 0;
    self.error = nil;
    [self openURL:[self currentItem].renditions[self.selectedRendition].URL
            position:isfinite(time) ? time : self.recoveryPosition
        chooseKernel:YES
          completion:^(BOOL success){
          }];
}
- (void)saveResumePosition {
    SGPlaybackItem *item = [self currentItem];
    if (!item || !self.resumeEnabled || !self.resumeStore || self.transitioning)
        return;
    double time = CMTimeGetSeconds(self.controller.currentTime), duration = CMTimeGetSeconds(self.controller.duration);
    if (!isfinite(time) || time < 0)
        return;
    NSMutableDictionary *positions =
        [[self.resumeStore dictionaryForKey:@"SGPlayer.resume.v1"] mutableCopy] ?: [NSMutableDictionary dictionary];
    if (isfinite(duration) && duration > 0 && time >= duration - 0.5)
        [positions removeObjectForKey:item.identifier];
    else
        positions[item.identifier] = @{@"seconds" : @(time), @"updated" : @(NSDate.timeIntervalSinceReferenceDate)};
    if (positions.count > 512) {
        NSArray *keys =
            [positions keysSortedByValueUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
                return [a[@"updated"] compare:b[@"updated"]];
            }];
        [positions removeObjectForKey:keys.firstObject];
    }
    [self.resumeStore setObject:positions forKey:@"SGPlayer.resume.v1"];
    self.lastSavedAt = CACurrentMediaTime();
}
- (BOOL)isCompatibilityError:(NSError *)error {
    if ([error.domain isEqual:AVFoundationErrorDomain])
        return error.code == AVErrorFileFormatNotRecognized || error.code == AVErrorDecoderNotFound ||
               error.code == AVErrorDecodeFailed;
    if ([error.domain hasPrefix:@"SGPlayer-Error-FFmpeg"])
        return error.code == AVERROR_DECODER_NOT_FOUND || error.code == AVERROR_DEMUXER_NOT_FOUND ||
               error.code == AVERROR_INVALIDDATA || error.code == AVERROR(ENOSYS);
    return [error.domain isEqual:@"SGPlayer-Error-SGErrorCode"] && error.code == SGErrorCodeNoValidFormat;
}
- (void)tick {
    if (self.closed || ![self currentItem])
        return;
    if (self.state == SGPlaybackSessionStateFailed)
        return;
#if SGPLATFORM_TARGET_OS_IPHONE_OR_TV
    if (UIApplication.sharedApplication.applicationState == UIApplicationStateBackground &&
        !self.controller.pictureInPictureActive)
        return;
#endif
    CFTimeInterval now = CACurrentMediaTime();
    NSError *error = self.error ?: self.controller.error;
    if (error && !self.transitioning && self.state != SGPlaybackSessionStateFailed) {
        if (self.kernelPolicy != SGKernelSelectionPolicyManual && self.fallbackCount == 0 && !self.requiresFFmpeg &&
            [self isCompatibilityError:error]) {
            self.fallbackCount++;
            [self event:@"fallback" details:@{@"from" : @(self.controller.kernel), @"code" : @(error.code)}];
            SGPlaybackKernel target = self.controller.kernel == SGPlaybackKernelNative ? SGPlaybackKernelFFmpeg : SGPlaybackKernelNative;
            [self switchToKernel:target completion:^(BOOL success) {}];

        } else {
            self.error = error;
            [self.controller pause];
            [self updateState:SGPlaybackSessionStateFailed];
        }
        return;
    }
    if (self.transitioning)
        return;
    double time = CMTimeGetSeconds(self.controller.currentTime), duration = CMTimeGetSeconds(self.controller.duration);
    if (!self.firstFrameAt && self.controller.presentedFrameCount)
        self.firstFrameAt = now;
    if (isfinite(time) && (self.lastPosition < 0 || fabs(time - self.lastPosition) > 0.01)) {
        self.lastPosition = time;
        self.lastProgressAt = now;
        if (self.stalledAt) {
            self.stalledDuration += now - self.stalledAt;
            self.stalledAt = 0;
        }
    }
    BOOL ended = isfinite(time) && isfinite(duration) && duration > 0 && time >= duration - 0.05;
    if (self.controller.kernel == SGPlaybackKernelFFmpeg)
        ended |= (self.controller.ffmpegPlayer.sstateInfo.playback & SGPlaybackStateFinished) != 0;
    BOOL endWasPlaying =
        ended && (self.state == SGPlaybackSessionStatePlaying || self.state == SGPlaybackSessionStateBuffering);
    if (!self.looping && (self.controller.playing || endWasPlaying) && CMTIMERANGE_IS_VALID(self.loopRange) &&
        (ended || (isfinite(time) && time >= CMTimeGetSeconds(CMTimeRangeGetEnd(self.loopRange))))) {
        self.looping = YES;
        NSUInteger revision = self.revision;
        [self.controller seekToTime:self.loopRange.start
                         completion:^(BOOL success) {
                             if (revision != self.revision)
                                 return;
                             self.looping = NO;
                             if (success) {
                                 if (self.state != SGPlaybackSessionStatePaused)
                                     [self play];
                             } else {
                                 self.error = SGSessionError(3, @"A–B loop seek failed");
                                 [self clearLoop];
                             }
                         }];
        return;
    }
    if (ended && (self.controller.playing || endWasPlaying) && self.state != SGPlaybackSessionStateEnded &&
        !self.looping) {
        [self saveResumePosition];
        if (self.loopMode == SGPlaybackLoopModeOne) {
            self.looping = YES;
            NSUInteger revision = self.revision;
            [self.controller seekToTime:kCMTimeZero
                             completion:^(BOOL success) {
                                 if (revision != self.revision)
                                     return;
                                 self.looping = NO;
                                 if (success) {
                                     if (self.state != SGPlaybackSessionStatePaused)
                                         [self play];
                                 } else
                                     self.error = SGSessionError(3, @"Loop seek failed");
                             }];
        } else if (self.automaticAdvance && [self next])
            [self play];
        else
            [self updateState:SGPlaybackSessionStateEnded];
        return;
    }
    if (!self.controller.playing) {
        if (self.stalledAt) {
            self.stalledDuration += now - self.stalledAt;
            self.stalledAt = 0;
        }
        if (self.state != SGPlaybackSessionStateEnded)
            [self updateState:SGPlaybackSessionStatePaused];
        self.lastProgressAt = now;
        return;
    }
    if (now - self.lastProgressAt > 1) {
        if (!self.stalledAt) {
            self.stalledAt = self.lastProgressAt;
            self.stallCount++;
        }
        [self updateState:SGPlaybackSessionStateBuffering];
        double timeout = isfinite(self.loadingTimeout) ? MIN(120, MAX(1, self.loadingTimeout)) : 20;
        if (now - self.lastProgressAt > timeout)
            self.error = SGSessionError(4, @"Playback made no progress before the session deadline");
    } else
        [self updateState:SGPlaybackSessionStatePlaying];
    if (now - self.lastSavedAt > 5)
        [self saveResumePosition];
}
- (NSDictionary<NSString *, id> *)diagnostics {
    CFTimeInterval now = CACurrentMediaTime();
    return @{
        @"schema" : @1,
        @"state" : @(self.state),
        @"itemIndex" : @(self.selectedIndex),
        @"renditionIndex" : @(self.selectedRendition),
        @"kernel" : @(self.controller.kernel),
        @"nativeAccessLog" : self.controller.nativePlaybackMetrics,
        @"presentedFrames" : @(self.controller.presentedFrameCount),
        @"firstFrameSeconds" : self.firstFrameAt ? @(MAX(0, self.firstFrameAt - self.openedAt)) : NSNull.null,
        @"stallCount" : @(self.stallCount),
        @"stallSeconds" : @(self.stalledDuration + (self.stalledAt ? now - self.stalledAt : 0)),
        @"fallbackCount" : @(self.fallbackCount),
        @"errorCode" : self.error ? @(self.error.code) : NSNull.null,
        @"events" : [self.events copy]
    };
}
- (BOOL)exportDiagnosticsToURL:(NSURL *)URL error:(NSError **)error {
    NSData *data = [NSJSONSerialization dataWithJSONObject:[self diagnostics]
                                                   options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys
                                                     error:error];
    return data && [data writeToURL:URL options:NSDataWritingAtomic error:error];
}
- (void)close {
    [self.selectionAsset cancelLoading];
    self.selectionAsset = nil;
    if (self.closed)
        return;
    [self saveResumePosition];
    self.closed = YES;
    self.revision++;
    [self.timer invalidate];
    self.timer = nil;
    [self.controller close];
    self.changed = nil;
}
@end

@interface SGPlaybackCoordinator ()
@property(nonatomic, strong) NSHashTable<SGPlaybackSession *> *sessions;
@end
@implementation SGPlaybackCoordinator
- (instancetype)init {
    if ((self = [super init]))
        _sessions = [NSHashTable weakObjectsHashTable];
    return self;
}
- (void)registerSession:(SGPlaybackSession *)session {
    NSAssert(NSThread.isMainThread, @"Main thread required");
    [self.sessions addObject:session];
}
- (void)unregisterSession:(SGPlaybackSession *)session {
    [self.sessions removeObject:session];
}
- (void)activateSession:(SGPlaybackSession *)session {
    [self registerSession:session];
    for (SGPlaybackSession *other in self.sessions.allObjects)
        if (other != session)
            [other pause];
    [session play];
}
- (void)pauseAll {
    for (SGPlaybackSession *session in self.sessions.allObjects)
        [session pause];
}
@end
