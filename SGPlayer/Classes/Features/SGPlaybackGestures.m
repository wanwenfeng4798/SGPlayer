#import "SGPlaybackGestures.h"
#import "SGPlayer.h"
#if SGPLATFORM_TARGET_OS_IPHONE
@interface SGPlaybackGestureTarget : NSObject
@property(nonatomic, weak) SGPlaybackGestures *owner;
- (void)pan:(UIPanGestureRecognizer *)gesture;
- (void)tap:(UITapGestureRecognizer *)gesture;
- (void)single:(UITapGestureRecognizer *)gesture;
@end
@interface SGPlaybackGestures () <UIGestureRecognizerDelegate>
@property(nonatomic, strong) SGPlaybackSession *session;
@property(nonatomic, weak) UIView *view;
@property(nonatomic, strong) SGPlaybackGestureTarget *target;
@property(nonatomic, strong) UIPanGestureRecognizer *pan;
@property(nonatomic, strong) UITapGestureRecognizer *tap;
@property(nonatomic, strong) UITapGestureRecognizer *single;
@property(nonatomic, strong) UILabel *feedback;
@property(nonatomic, weak) UIScreen *brightnessScreen;
@property(nonatomic) CGFloat originalBrightness;
@property(nonatomic) CGFloat lastBrightness;
@property(nonatomic) BOOL changedBrightness;
@property(nonatomic) NSInteger axis;
@property(nonatomic) CGPoint startingVR;
@property(nonatomic) double startingTime;
@property(nonatomic) double targetTime;
@property(nonatomic) double duration;
@property(nonatomic) CGFloat startingLevel;
@property(nonatomic) NSInteger itemIndex;
@property(nonatomic) NSInteger renditionIndex;
@property(nonatomic, strong) SGPlaybackItem *item;
@property(nonatomic) SGPlaybackKernel kernel;
@property(nonatomic) NSUInteger feedbackRevision;
@property(nonatomic) NSUInteger operationRevision;
@property(nonatomic, copy) NSString *originalAccessibilityValue;
@property(nonatomic, copy) NSString *lastFeedback;
- (void)handlePan:(UIPanGestureRecognizer *)gesture;
- (void)handleTap:(UITapGestureRecognizer *)gesture;
@end
@implementation SGPlaybackGestureTarget
- (void)pan:(UIPanGestureRecognizer *)gesture {
    [self.owner handlePan:gesture];
}
- (void)tap:(UITapGestureRecognizer *)gesture {
    [self.owner handleTap:gesture];
}
- (void)single:(UITapGestureRecognizer *)gesture {
    SGPlaybackGestures *owner = self.owner;
    if (!owner.locked && gesture.state == UIGestureRecognizerStateRecognized && owner.singleTap)
        owner.singleTap();
}
@end
@implementation SGPlaybackGestures
- (instancetype)initWithSession:(SGPlaybackSession *)session view:(UIView *)view {
    NSParameterAssert(session);
    NSParameterAssert(view);
    NSAssert(NSThread.isMainThread, @"Main thread required");
    if ((self = [super init])) {
        _session = session;
        _view = view;
        _originalAccessibilityValue = [view.accessibilityValue copy];
        _target = [SGPlaybackGestureTarget new];
        _target.owner = self;
        _pan = [[UIPanGestureRecognizer alloc] initWithTarget:_target action:@selector(pan:)];
        _pan.maximumNumberOfTouches = 1;
        _pan.delegate = self;
        _tap = [[UITapGestureRecognizer alloc] initWithTarget:_target action:@selector(tap:)];
        _tap.numberOfTapsRequired = 2;
        _tap.delegate = self;
        _single = [[UITapGestureRecognizer alloc] initWithTarget:_target action:@selector(single:)];
        _single.delegate = self;
        _single.cancelsTouchesInView = NO;
        [_single requireGestureRecognizerToFail:_tap];
        [view addGestureRecognizer:_pan];
        [view addGestureRecognizer:_tap];
        [view addGestureRecognizer:_single];
        _feedback = [UILabel new];
        _feedback.textColor = UIColor.whiteColor;
        _feedback.backgroundColor = [UIColor colorWithWhite:0 alpha:.8];
        _feedback.textAlignment = NSTextAlignmentCenter;
        _feedback.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
        _feedback.adjustsFontForContentSizeCategory = YES;
        _feedback.hidden = YES;
        _feedback.accessibilityIdentifier = @"session.gesturefeedback";
        _feedback.userInteractionEnabled = NO;
        [view addSubview:_feedback];
    }
    return self;
}
- (void)dealloc {
    [self close];
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)recognizer shouldReceiveTouch:(UITouch *)touch {
    for (UIView *view = touch.view; view && view != self.view; view = view.superview)
        if ([view isKindOfClass:UIControl.class])
            return NO;
    return !UIAccessibilityIsVoiceOverRunning() && !self.locked && self.session.state != SGPlaybackSessionStateLoading;
}
- (void)hideFeedback {
    self.feedbackRevision++;
    self.feedback.hidden = YES;
    if ([self.view.accessibilityValue isEqual:self.lastFeedback])
        self.view.accessibilityValue = self.originalAccessibilityValue;
}
- (void)setLocked:(BOOL)locked {
    _locked = locked;
    if (locked) {
        self.operationRevision++;
        self.axis = 0;
        self.item = nil;
    }
    self.pan.enabled = !locked;
    self.tap.enabled = !locked;
    self.single.enabled = !locked;
    if (locked)
        [self hideFeedback];
}
- (void)show:(NSString *)message {
    self.feedback.frame =
        CGRectMake(8, MAX(8, self.view.safeAreaInsets.top), MAX(0, self.view.bounds.size.width - 16), 44);
    self.feedback.text = message;
    self.feedback.hidden = NO;
    self.lastFeedback = message;
    self.view.accessibilityValue = message;
    NSUInteger revision = ++self.feedbackRevision;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if (weakSelf.feedbackRevision == revision) {
            if (weakSelf.interacting)
                [weakSelf show:weakSelf.lastFeedback];
            else
                [weakSelf hideFeedback];
        }
    });
}
- (void)handleTap:(UITapGestureRecognizer *)gesture {
    if (self.locked || gesture.state != UIGestureRecognizerStateRecognized)
        return;
    if (self.interaction)
        self.interaction();
    if (self.session.controller.playing)
        [self.session pause];
    else
        [self.session play];
    [self hideFeedback];
}
- (BOOL)sourceStillMatches {
    return self.session.selectedIndex == self.itemIndex && self.session.selectedRendition == self.renditionIndex &&
           self.session.controller.kernel == self.kernel && self.session.state != SGPlaybackSessionStateLoading &&
           self.itemIndex >= 0 && self.itemIndex < (NSInteger)self.session.items.count &&
           self.session.items[self.itemIndex] == self.item;
}
- (BOOL)interacting {
    return !self.locked && self.view && self.item &&
           (self.pan.state == UIGestureRecognizerStateBegan || self.pan.state == UIGestureRecognizerStateChanged) &&
           [self sourceStillMatches];
}
- (void)handlePan:(UIPanGestureRecognizer *)gesture {
    if (self.locked)
        return;
    UIView *view = self.view;
    SGPlaybackController *controller = self.session.controller;
    if(controller.kernel==SGPlaybackKernelFFmpeg && controller.ffmpegPlayer.videoRenderer.displayMode!=SGDisplayModePlane) {
        SGVRViewport *viewport=controller.ffmpegPlayer.videoRenderer.viewport;
        if(gesture.state==UIGestureRecognizerStateBegan) self.startingVR=CGPointMake(viewport.x,viewport.y);
        if(gesture.state==UIGestureRecognizerStateBegan || gesture.state==UIGestureRecognizerStateChanged) {
            CGPoint delta=[gesture translationInView:view];
            CGFloat degrees=viewport.degress;
            viewport.x=self.startingVR.x-delta.x/MAX(1,view.bounds.size.height)*degrees;
            viewport.y=MIN(89,MAX(-89,self.startingVR.y+delta.y/MAX(1,view.bounds.size.height)*degrees));
            if(self.interaction)self.interaction();
        }
        return;
    }
    if (gesture.state == UIGestureRecognizerStateBegan) {
        self.operationRevision++;
        if (self.interaction)
            self.interaction();
        CGPoint velocity = [gesture velocityInView:view], location = [gesture locationInView:view];
        self.axis = fabs(velocity.x) >= fabs(velocity.y) ? 1 : (location.x < view.bounds.size.width / 2 ? 2 : 3);
        self.startingTime = CMTimeGetSeconds(controller.currentTime);
        self.duration = CMTimeGetSeconds(controller.duration);
        self.targetTime = self.startingTime;
        self.itemIndex = self.session.selectedIndex;
        self.renditionIndex = self.session.selectedRendition;
        self.item = self.itemIndex >= 0 && self.itemIndex < (NSInteger)self.session.items.count
                        ? self.session.items[self.itemIndex]
                        : nil;
        self.kernel = controller.kernel;
        UIScreen *screen = view.window.windowScene.screen;
        if (self.axis == 2) {
            if (!screen) {
                self.axis = 0;
                return;
            }
            if (self.brightnessScreen != screen ||
                (self.changedBrightness && fabs(screen.brightness - self.lastBrightness) > .005)) {
                self.brightnessScreen = screen;
                self.originalBrightness = screen.brightness;
                self.changedBrightness = NO;
            }
            self.startingLevel = screen.brightness;
        } else
            self.startingLevel = controller.volume;
        if (self.axis == 1 && (!isfinite(self.startingTime) || !isfinite(self.duration) || self.duration <= 0)) {
            self.axis = 0;
            [self show:@"Seeking unavailable"];
        }
    }
    CGPoint delta = [gesture translationInView:view];
    if (gesture.state == UIGestureRecognizerStateBegan || gesture.state == UIGestureRecognizerStateChanged) {
        if (![self sourceStillMatches]) {
            self.axis = 0;
            [self hideFeedback];
            return;
        }
        if (self.axis == 1) {
            self.targetTime =
                MIN(MAX(0, self.startingTime + delta.x / MAX(1, view.bounds.size.width) * MIN(120, self.duration)),
                    MAX(0, self.duration - .1));
            [self show:[NSString stringWithFormat:@"Seek %.1f s", self.targetTime]];
        } else if (self.axis == 2 || self.axis == 3) {
            CGFloat level = MIN(1, MAX(0, self.startingLevel - delta.y / MAX(1, view.bounds.size.height)));
            if (self.axis == 2) {
                self.brightnessScreen.brightness = level;
                self.lastBrightness = level;
                self.changedBrightness = YES;
            } else
                controller.volume = level;
            [self show:[NSString
                           stringWithFormat:@"%@ %.0f%%", self.axis == 2 ? @"Brightness" : @"Volume",
                                            (self.axis == 2 ? self.brightnessScreen.brightness : controller.volume) *
                                                100]];
        }
    }
    if (gesture.state == UIGestureRecognizerStateEnded) {
        BOOL sourceMatches = [self sourceStillMatches];
        if (self.axis == 1 && sourceMatches) {
            __weak typeof(self) weakSelf = self;
            NSUInteger revision = self.operationRevision;
            SGPlaybackItem *item = self.item;
            NSInteger index = self.itemIndex;
            SGPlaybackKernel kernel = self.kernel;
            [controller seekToTime:CMTimeMakeWithSeconds(self.targetTime, 1000)
                        completion:^(BOOL success) {
                            SGPlaybackGestures *self = weakSelf;
                            if (!self || self.locked || self.operationRevision != revision ||
                                self.session.selectedIndex != index || index < 0 ||
                                index >= (NSInteger)self.session.items.count || self.session.items[index] != item ||
                                self.session.controller.kernel != kernel)
                                return;
                            if (!success)
                                [self show:@"Seek failed"];
                        }];
        }
        self.axis = 0;
        self.item = nil;
        if (sourceMatches) {
            if (!self.feedback.hidden)
                [self show:self.lastFeedback];
            if (self.interaction)
                self.interaction();
        } else
            [self hideFeedback];
    } else if (gesture.state == UIGestureRecognizerStateCancelled || gesture.state == UIGestureRecognizerStateFailed) {
        self.axis = 0;
        self.item = nil;
        [self hideFeedback];
    }
}
- (void)close {
    self.operationRevision++;
    _locked = YES;
    self.pan.enabled = NO;
    self.tap.enabled = NO;
    self.single.enabled = NO;
    self.singleTap = nil;
    self.interaction = nil;
    self.item = nil;
    [self hideFeedback];
    [self.view removeGestureRecognizer:self.pan];
    [self.view removeGestureRecognizer:self.tap];
    [self.view removeGestureRecognizer:self.single];
    [self.feedback removeFromSuperview];
    // Do not overwrite a brightness change made outside this gesture controller.
    if (self.changedBrightness && fabs(self.brightnessScreen.brightness - self.lastBrightness) < .005)
        self.brightnessScreen.brightness = self.originalBrightness;
    self.changedBrightness = NO;
    self.target.owner = nil;
    self.view = nil;
}
@end
#endif
