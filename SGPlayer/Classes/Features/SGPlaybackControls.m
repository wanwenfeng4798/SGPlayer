#import "SGPlaybackControls.h"
#import "SGPlaybackGestures.h"
#import <QuartzCore/QuartzCore.h>
#if SGPLATFORM_TARGET_OS_TV
@interface SGPlaybackControls (RemoteInput)
- (void)remotePlayPause;
@end
@interface SGPlaybackRemoteSurface : UIView
@property(nonatomic, weak) SGPlaybackControls *owner;
@end
@implementation SGPlaybackRemoteSurface
- (BOOL)canBecomeFocused {
    return self.owner && self.owner.hidden;
}
- (BOOL)canBecomeFirstResponder {
    return YES;
}
- (void)pressesEnded:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    for (UIPress *press in presses) {
        if (press.type == UIPressTypePlayPause) {
            [self.owner remotePlayPause];
            return;
        }
        if (press.type == UIPressTypeSelect || press.type == UIPressTypeMenu || press.type == UIPressTypeUpArrow ||
            press.type == UIPressTypeDownArrow || press.type == UIPressTypeLeftArrow ||
            press.type == UIPressTypeRightArrow) {
            [self.owner revealControls];
            return;
        }
    }
    [super pressesEnded:presses withEvent:event];
}
@end
#endif
@interface SGPlaybackControls ()
@property(nonatomic, strong, readwrite) SGPlaybackSession *session;
@property(nonatomic, strong) NSMutableArray *buttons;
@property(nonatomic, strong) id status;
@property(nonatomic, strong) id progress;
@property(nonatomic, strong) AVRoutePickerView *routePicker;
@property(nonatomic, strong) NSTimer *timer;
@property(nonatomic) BOOL changingKernel;
#if SGPLATFORM_TARGET_OS_MAC
@property(nonatomic, weak) NSView *keyboardSurface;
@property(nonatomic, strong) id keyboardMonitor;
@property(nonatomic) float keyboardSavedVolume;
@property(nonatomic) BOOL keyboardActive;
@property(nonatomic, strong) NSTrackingArea *keyboardTrackingArea;
#endif
@property(nonatomic, strong) SGPlaybackCover *cover;
@property(nonatomic) CFTimeInterval lastInteraction;
@property(nonatomic) SGPlaybackSessionState previousSessionState;
#if SGPLATFORM_TARGET_OS_TV
@property(nonatomic, strong) SGPlaybackRemoteSurface *remoteSurface;
#endif
#if SGPLATFORM_TARGET_OS_IPHONE
@property(nonatomic, strong) SGPlaybackGestures *gestures;
#endif
@end
@implementation SGPlaybackControls
- (instancetype)initWithSession:(SGPlaybackSession *)session {
    if ((self = [super initWithFrame:CGRectZero])) {
        _session = session;
        _buttons = [NSMutableArray array];
        NSArray *titles = @[
            @"▶︎ / Ⅱ", @"−10s", @"+10s", @"Previous", @"Next", @"Kernel", @"Audio", @"Subtitles", @"Quality", @"Speed",
            @"Retry", @"Lock", @"PiP", @"Full screen", @"Mini player"
        ];
        NSArray *identifiers = @[
            @"play", @"back", @"forward", @"previous", @"next", @"kernel", @"audio", @"subtitles", @"quality", @"speed",
            @"retry", @"lock", @"pip", @"fullscreen", @"floating"
        ];
        for (NSUInteger i = 0; i < titles.count; i++) {
#if SGPLATFORM_TARGET_OS_MAC
            NSButton *button = [NSButton buttonWithTitle:titles[i] target:self action:@selector(pressed:)];
            button.tag = i;
            button.accessibilityIdentifier = [@"session." stringByAppendingString:identifiers[i]];
#else
            UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
            [button setTitle:titles[i] forState:UIControlStateNormal];
            button.tag = i;
            button.titleLabel.font = [UIFont systemFontOfSize:14];
            [button addTarget:self action:@selector(pressed:) forControlEvents:UIControlEventPrimaryActionTriggered];
            button.accessibilityIdentifier = [@"session." stringByAppendingString:identifiers[i]];
#endif
            [self.buttons addObject:button];
            [self addSubview:button];
        }
#if SGPLATFORM_TARGET_OS_MAC
        self.wantsLayer = YES;
        self.layer.backgroundColor = NSColor.windowBackgroundColor.CGColor;
        NSTextField *status = [NSTextField labelWithString:@""];
        status.font = [NSFont systemFontOfSize:11];
        status.accessibilityIdentifier = @"session.status";
        self.status = status;
        NSSlider *progress = [NSSlider sliderWithValue:0 minValue:0 maxValue:1 target:self action:@selector(scrub:)];
        progress.continuous = NO;
        progress.accessibilityIdentifier = @"session.progress";
        self.progress = progress;
#else
        self.backgroundColor = [UIColor colorWithWhite:0 alpha:.85];
        UILabel *status = [UILabel new];
        status.textColor = UIColor.whiteColor;
        status.font = [UIFont systemFontOfSize:11];
        status.numberOfLines = 2;
        status.accessibilityIdentifier = @"session.status";
        self.status = status;
#if !SGPLATFORM_TARGET_OS_TV
        UISlider *progress = [UISlider new];
        progress.minimumValue = 0;
        progress.maximumValue = 1;
        progress.accessibilityIdentifier = @"session.progress";
        [progress addTarget:self
                      action:@selector(scrub:)
            forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside];
        [progress addTarget:self action:@selector(sliderValueChanged:) forControlEvents:UIControlEventValueChanged];
        self.progress = progress;
#endif
#endif
        [self addSubview:self.status];
        if (self.progress)
            [self addSubview:self.progress];
        self.routePicker = [[AVRoutePickerView alloc] initWithFrame:CGRectZero];
        [self addSubview:self.routePicker];
        __weak typeof(self) weakSelf = self;
        self.timer = [NSTimer timerWithTimeInterval:.25
                                            repeats:YES
                                              block:^(NSTimer *timer) {
                                                  [weakSelf refresh];
                                              }];
        [NSRunLoop.mainRunLoop addTimer:self.timer forMode:NSRunLoopCommonModes];
        [self refresh];
    }
    return self;
}
- (void)dealloc {
    [_timer invalidate];
    [_cover close];
#if SGPLATFORM_TARGET_OS_MAC
    if (_keyboardMonitor)
        [NSEvent removeMonitor:_keyboardMonitor];
    if (_keyboardTrackingArea)
        [_keyboardSurface removeTrackingArea:_keyboardTrackingArea];
#endif
#if SGPLATFORM_TARGET_OS_IPHONE
    [_gestures close];
#endif
#if SGPLATFORM_TARGET_OS_TV
    [_remoteSurface removeFromSuperview];
#endif
}
- (void)setAutoHideInterval:(NSTimeInterval)interval {
    _autoHideInterval = isfinite(interval) ? MIN(120, MAX(0, interval)) : 0;
    [self revealControls];
}
- (void)revealControls {
    self.lastInteraction = CACurrentMediaTime();
    [self setControlsPresentedHidden:NO];
}
#if SGPLATFORM_TARGET_OS_IPHONE
- (void)attachGesturesToView:(UIView *)view {
    [self.gestures close];
    self.gestures = [[SGPlaybackGestures alloc] initWithSession:self.session view:view];
    self.gestures.locked = self.controlsLocked;
    __weak typeof(self) weakSelf = self;
    self.gestures.singleTap = ^{
        SGPlaybackControls *self = weakSelf;
        if (!self || self.autoHideInterval <= 0)
            return;
        if (self.hidden)
            [self revealControls];
        else if (self.session.controller.playing)
            self.hidden = YES;
    };
    self.gestures.interaction = ^{
        [weakSelf revealControls];
    };
}
#endif
- (void)setControlsPresentedHidden:(BOOL)hidden {
    if (self.hidden == hidden)
        return;
#if SGPLATFORM_TARGET_OS_TV
    BOOL wasRemoteFocused = self.remoteSurface.isFocused;
#endif
    self.hidden = hidden;
#if SGPLATFORM_TARGET_OS_TV
    self.remoteSurface.hidden = !hidden;
    UIFocusSystem *focus = [UIFocusSystem focusSystemForEnvironment:self.remoteSurface];
    if (hidden) {
        [self.remoteSurface becomeFirstResponder];
        [focus requestFocusUpdateToEnvironment:self.remoteSurface];
    } else if (wasRemoteFocused) {
        [self.remoteSurface resignFirstResponder];
        [focus requestFocusUpdateToEnvironment:self.controlsLocked ? self.buttons[11] : self.buttons.firstObject];
    }
    [focus updateFocusIfNeeded];
#endif
}
#if SGPLATFORM_TARGET_OS_TV
- (void)attachRemoteToView:(UIView *)view {
    [self revealControls];
    [self.remoteSurface removeFromSuperview];
    self.remoteSurface = nil;
    if (!view)
        return;
    SGPlaybackRemoteSurface *surface = [[SGPlaybackRemoteSurface alloc] initWithFrame:view.bounds];
    surface.owner = self;
    surface.hidden = YES;
    surface.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    surface.isAccessibilityElement = YES;
    surface.accessibilityIdentifier = @"session.remote-surface";
    surface.accessibilityLabel = @"Show playback controls";
    surface.accessibilityTraits = UIAccessibilityTraitButton;
    [view addSubview:surface];
    self.remoteSurface = surface;
}
- (void)remotePlayPause {
    [self pressed:self.buttons.firstObject];
}
- (void)didUpdateFocusInContext:(UIFocusUpdateContext *)context
       withAnimationCoordinator:(UIFocusAnimationCoordinator *)coordinator {
    [super didUpdateFocusInContext:context withAnimationCoordinator:coordinator];
    if ([context.nextFocusedView isDescendantOfView:self])
        [self revealControls];
}
#endif
- (void)setCoverImage:(SGPLFImage *)image forView:(SGPLFView *)view {
    [self.cover close];
    self.cover = image ? [[SGPlaybackCover alloc] initWithSession:self.session view:view image:image] : nil;
}
- (void)setControlsLocked:(BOOL)controlsLocked {
    _controlsLocked = controlsLocked;
#if SGPLATFORM_TARGET_OS_IPHONE
    self.gestures.locked = controlsLocked;
#endif
    [self revealControls];
    [self refresh];
}
- (void)arrange {
    CGFloat width = self.bounds.size.width, height = self.bounds.size.height, row = MAX(28, (height - 62) / 4);
    for (NSUInteger i = 0; i < self.buttons.count; i++) {
#if SGPLATFORM_TARGET_OS_MAC
        CGFloat y = height - 62 - (i / 4 + 1) * row;
#else
        CGFloat y = 62 + (i / 4) * row;
#endif
        [self.buttons[i] setFrame:CGRectMake((i % 4) * width / 4 + 2, y, width / 4 - 4, row - 4)];
    }
#if SGPLATFORM_TARGET_OS_MAC
    [self.status setFrame:CGRectMake(8, height - 28, width - 16, 24)];
    [self.progress setFrame:CGRectMake(8, height - 58, width - 16, 26)];
    self.routePicker.frame = CGRectMake(3 * width / 4 + 2, 0, width / 4 - 4, row - 4);
#else
    [self.status setFrame:CGRectMake(8, 0, width - 16, 28)];
    [self.progress setFrame:CGRectMake(8, 30, width - 16, 28)];
    self.routePicker.frame = CGRectMake(3 * width / 4 + 2, 62 + 3 * row, width / 4 - 4, row - 4);
#endif
}
#if SGPLATFORM_TARGET_OS_MAC
- (void)resizeSubviewsWithOldSize:(NSSize)size {
    [super resizeSubviewsWithOldSize:size];
    [self arrange];
}
- (BOOL)acceptsFirstResponder {
    return YES;
}
- (void)attachKeyboardToView:(NSView *)view {
    if (self.keyboardMonitor)
        [NSEvent removeMonitor:self.keyboardMonitor];
    self.keyboardMonitor = nil;
    if (self.keyboardTrackingArea)
        [self.keyboardSurface removeTrackingArea:self.keyboardTrackingArea];
    self.keyboardTrackingArea = nil;
    self.keyboardActive = NO;
    self.keyboardSurface = view;
    if (!view)
        return;
    self.keyboardTrackingArea = [[NSTrackingArea alloc]
        initWithRect:NSZeroRect
             options:NSTrackingMouseMoved | NSTrackingActiveInKeyWindow | NSTrackingInVisibleRect
               owner:self
            userInfo:nil];
    [view addTrackingArea:self.keyboardTrackingArea];
    __weak typeof(self) weakSelf = self;
    self.keyboardMonitor = [NSEvent
        addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown | NSEventMaskLeftMouseDown
                                     handler:^NSEvent *(NSEvent *event) {
                                         SGPlaybackControls *self = weakSelf;
                                         NSView *surface = self.keyboardSurface;

                                         if (!self || !surface.window || event.window != surface.window ||
                                             self.window != surface.window)
                                             return event;
                                         if (event.type == NSEventTypeLeftMouseDown) {
                                             self.keyboardActive =
                                                 !self.hidden && NSPointInRect([self convertPoint:event.locationInWindow
                                                                                         fromView:nil],
                                                                               self.bounds);
                                             if (!surface.hiddenOrHasHiddenAncestor &&
                                                 NSPointInRect([surface convertPoint:event.locationInWindow
                                                                            fromView:nil],
                                                               surface.bounds)) {
                                                 NSPoint point = [surface.superview convertPoint:event.locationInWindow
                                                                                        fromView:nil];
                                                 NSView *hit = [surface hitTest:point];
                                                 for (NSView *node = hit; node && node != surface;
                                                      node = node.superview)
                                                     if ([node isKindOfClass:NSControl.class] ||
                                                         [node isKindOfClass:NSTextView.class])
                                                         return event;
                                                 self.keyboardActive = YES;
                                                 [self revealControls];
                                                 [surface.window makeFirstResponder:self];
                                             }
                                             return event;
                                         }
                                         NSResponder *responder = surface.window.firstResponder;
                                         if (self.hidden && self.keyboardActive && responder == surface.window)
                                             return [self handleKeyEvent:event] ? nil : event;
                                         if (![responder isKindOfClass:NSView.class] ||
                                             [responder isKindOfClass:NSTextView.class] ||
                                             [responder isKindOfClass:NSControl.class])
                                             return event;
                                         NSView *focus = (NSView *)responder;
                                         if (![focus isDescendantOf:self] && ![focus isDescendantOf:surface])
                                             return event;
                                         return [self handleKeyEvent:event] ? nil : event;
                                     }];
}
- (BOOL)handleKeyEvent:(NSEvent *)event {
    if (event.type != NSEventTypeKeyDown ||
        (event.modifierFlags & (NSEventModifierFlagCommand | NSEventModifierFlagControl | NSEventModifierFlagOption)))
        return NO;
    NSString *key = (event.characters.length ? event.characters : event.charactersIgnoringModifiers).lowercaseString;
    BOOL space = [key isEqual:@" "];
    BOOL lock = [key isEqual:@"l"];
    BOOL mapped = lock || space || (event.keyCode >= 123 && event.keyCode <= 126) ||
                  [@[ @"m", @"f", @"[", @"]" ] containsObject:key] || event.keyCode == 53;
    if (!mapped)
        return NO;
    self.keyboardActive = YES;
    [self revealControls];
    if (lock) {
        if (!event.isARepeat)
            self.controlsLocked = !self.controlsLocked;
        return YES;
    }
    if (self.controlsLocked)
        return YES;
    SGPlaybackController *controller = self.session.controller;
    if (space) {
        if (!event.isARepeat)
            [self pressed:self.buttons[0]];
        return YES;
    }
    if (event.keyCode == 123 || event.keyCode == 124) {
        double delta = (event.modifierFlags & NSEventModifierFlagShift) ? 30 : 10;
        return [self seekBySeconds:event.keyCode == 123 ? -delta : delta];
    }
    if (event.keyCode == 125 || event.keyCode == 126) {
        controller.volume = MIN(1, MAX(0, controller.volume + (event.keyCode == 126 ? .1 : -.1)));
        if (controller.volume > 0)
            self.keyboardSavedVolume = controller.volume;
        return YES;
    }
    if ([key isEqual:@"m"]) {
        if (!event.isARepeat) {
            if (controller.volume > 0) {
                self.keyboardSavedVolume = controller.volume;
                controller.volume = 0;
            } else
                controller.volume = self.keyboardSavedVolume > 0 ? self.keyboardSavedVolume : 1;
        }
        return YES;
    }
    if ([key isEqual:@"["] || [key isEqual:@"]"]) {
        controller.rate = MIN(4, MAX(.25, controller.rate + ([key isEqual:@"]"] ? .25 : -.25)));
        return YES;
    }
    if (event.keyCode == 53) {
        if (!self.dismissPresentation)
            return NO;
        if (!event.isARepeat)
            self.dismissPresentation();
        return YES;
    }
    if ([key isEqual:@"f"]) {
        if (!self.toggleFullScreen)
            return NO;
        if (!event.isARepeat)
            self.toggleFullScreen();
        return YES;
    }
    return NO;
}
- (void)mouseMoved:(NSEvent *)event {
    [self revealControls];
    if (self.keyboardActive && self.keyboardSurface.window.firstResponder == self.keyboardSurface.window)
        [self.keyboardSurface.window makeFirstResponder:self];
}
- (void)keyDown:(NSEvent *)event {
    if (![self handleKeyEvent:event])
        [super keyDown:event];
}
#else
- (void)layoutSubviews {
    [super layoutSubviews];
    [self arrange];
}
#if SGPLATFORM_TARGET_OS_TV
- (void)pressesEnded:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    for (UIPress *press in presses)
        if (press.type == UIPressTypePlayPause && !self.controlsLocked) {
            [self pressed:self.buttons[0]];
            return;
        }
    [super pressesEnded:presses withEvent:event];
}
#endif
#endif
- (BOOL)seekBySeconds:(double)seconds {
    if (self.controlsLocked || !isfinite(seconds))
        return NO;
    double now = CMTimeGetSeconds(self.session.controller.currentTime),
           duration = CMTimeGetSeconds(self.session.controller.duration);
    if (!isfinite(now) || !isfinite(duration) || duration <= 0)
        return NO;
    [self.session.controller seekToTime:CMTimeMakeWithSeconds(MIN(MAX(0, now + seconds), MAX(0, duration - .1)), 1000)
                             completion:^(BOOL success){
                             }];
    return YES;
}
- (void)scrub:(id)sender {
    [self revealControls];
    if (self.controlsLocked)
        return;
#if SGPLATFORM_TARGET_OS_MAC
    double fraction = [sender doubleValue];
#elif !SGPLATFORM_TARGET_OS_TV
    double fraction = ((UISlider *)sender).value;
#else
    return;
    double fraction = 0;
#endif
    double duration = CMTimeGetSeconds(self.session.controller.duration);
    if (!isfinite(duration) || duration <= 0)
        return;
    [self.session.controller seekToTime:CMTimeMakeWithSeconds(MIN(MAX(0, fraction), 1) * MAX(0, duration - .1), 1000)
                             completion:^(BOOL success){
                             }];
}
- (void)pressed:(id)sender {
    [self revealControls];
    NSInteger action = [sender tag];
    if (self.controlsLocked && action != 11)
        return;
    SGPlaybackController *controller = self.session.controller;
    switch (action) {
    case 0:
        if (controller.playing)
            [self.session pause];
        else
            [self.session play];
        break;
    case 1:
        [self seekBySeconds:-10];
        break;
    case 2:
        [self seekBySeconds:10];
        break;
    case 3:
        [self.session previous];
        break;
    case 4:
        [self.session next];
        break;
    case 5:
        if (!self.changingKernel) {
            self.session.kernelPolicy = SGKernelSelectionPolicyManual;
            self.changingKernel = YES;
            __weak typeof(self) weakSelf = self;
            [self.session switchToKernel:controller.kernel == SGPlaybackKernelNative ? SGPlaybackKernelFFmpeg
                                                                                     : SGPlaybackKernelNative
                              completion:^(BOOL success) {
                                  weakSelf.changingKernel = NO;
                              }];
        }
        break;
    case 6:
        if (controller.audioTrackTitles.count)
            [controller
                selectAudioTrackAtIndex:(controller.selectedAudioTrack + 1) % controller.audioTrackTitles.count];
        break;
    case 7: {
        NSInteger next = -1;
        NSArray *tracks = controller.subtitleTracks;
        for (NSUInteger i = 0; i < tracks.count; i++)
            if (controller.selectedSubtitleTrack < 0 ||
                ((SGSubtitleTrack *)tracks[i]).index == controller.selectedSubtitleTrack) {
                NSUInteger candidate = controller.selectedSubtitleTrack < 0 ? 0 : i + 1;
                if (candidate < tracks.count)
                    next = ((SGSubtitleTrack *)tracks[candidate]).index;
                break;
            }
        [controller selectSubtitleTrack:next];
        break;
    }
    case 8: {
        if (self.session.selectedIndex == NSNotFound)
            break;
        SGPlaybackItem *item = self.session.items[self.session.selectedIndex];
        if (item.renditions.count)
            [self.session selectRenditionAtIndex:(self.session.selectedRendition + 1) % item.renditions.count
                                      completion:^(BOOL success){
                                      }];
        break;
    }
    case 9:
        controller.rate = controller.rate == 1 ? 1.5 : controller.rate == 1.5 ? 2 : controller.rate == 2 ? .5 : 1;
        break;
    case 10:
        [self.session retry];
        break;
    case 11:
        self.controlsLocked = !self.controlsLocked;
        break;
    case 12:
        if (controller.pictureInPictureActive)
            [controller stopPictureInPicture];
        else
            [controller startPictureInPicture:nil];
        break;
    case 13:
        if (self.toggleFullScreen)
            self.toggleFullScreen();
        break;
    case 14:
        if (self.toggleFloatingWindow)
            self.toggleFloatingWindow();
        break;
    }
    [self refresh];
}
#if SGPLATFORM_TARGET_OS_IPHONE
- (void)sliderValueChanged:(UISlider *)slider {
    // Touch drags commit on release; accessibility adjustments have no touch-up event.
    if (slider.tracking)
        [self revealControls];
    else
        [self scrub:slider];
}
#endif
- (void)refresh {
    [self.cover refresh];
#if SGPLATFORM_TARGET_OS_MAC
    BOOL sliderTracking = ((NSSlider *)self.progress).cell.highlighted;
    if (sliderTracking ||
        (self.window && self.window == NSApp.keyWindow && self.keyboardActive && (NSEvent.pressedMouseButtons & 1)))
        self.lastInteraction = CACurrentMediaTime();
#elif SGPLATFORM_TARGET_OS_IPHONE
    if (((UISlider *)self.progress).tracking || self.gestures.interacting)
        self.lastInteraction = CACurrentMediaTime();
#endif
    if (self.previousSessionState != self.session.state) {
        self.previousSessionState = self.session.state;
        self.lastInteraction = CACurrentMediaTime();
    }
    if (self.session.state != SGPlaybackSessionStatePlaying || self.controlsLocked)
        [self setControlsPresentedHidden:NO];
#if !SGPLATFORM_TARGET_OS_MAC
    else if (UIAccessibilityIsVoiceOverRunning())
        [self setControlsPresentedHidden:NO];
#endif
#if SGPLATFORM_TARGET_OS_TV
    else if (!self.remoteSurface.window)
        [self setControlsPresentedHidden:NO];
#endif
    else if (self.autoHideInterval > 0 && CACurrentMediaTime() - self.lastInteraction >= self.autoHideInterval)
        [self setControlsPresentedHidden:YES];
    SGPlaybackController *controller = self.session.controller;
    double time = CMTimeGetSeconds(controller.currentTime), duration = CMTimeGetSeconds(controller.duration);
    NSArray *states = @[ @"Idle", @"Loading…", @"Playing", @"Paused", @"Buffering…", @"Ended", @"Failed — Retry" ];
    NSString *message =
        [NSString stringWithFormat:@"%@  %.1f / %.1fs  %.1f×  %@ | %lu frames", states[self.session.state],
                                   isfinite(time) ? time : 0, isfinite(duration) ? duration : 0, controller.rate,
                                   controller.kernel == SGPlaybackKernelFFmpeg ? @"FFmpeg" : @"Native",
                                   (unsigned long)controller.presentedFrameCount];
#if SGPLATFORM_TARGET_OS_MAC
    [self.status setStringValue:message];
    if (!sliderTracking)
        [self.progress setDoubleValue:isfinite(time) && isfinite(duration) && duration > 0 ? time / duration : 0];
    self.routePicker.player = controller.nativePlayer;
#else
    [self.status setText:message];
#if !SGPLATFORM_TARGET_OS_TV
    UISlider *slider = self.progress;
    if (!slider.tracking)
        slider.value = isfinite(time) && isfinite(duration) && duration > 0 ? time / duration : 0;
#endif
#endif
    for (NSUInteger i = 0; i < self.buttons.count; i++)
        [self.buttons[i] setHidden:self.controlsLocked && i != 11];
    BOOL loading = self.session.state == SGPlaybackSessionStateLoading;
    [self.buttons[1] setEnabled:!loading];
    [self.buttons[2] setEnabled:!loading];
    [self.buttons[5] setEnabled:!loading && !self.changingKernel];
    [self.buttons[6] setEnabled:!loading && controller.audioTrackTitles.count > 0];
    [self.buttons[7] setEnabled:!loading && controller.subtitleTracks.count > 0];
    NSUInteger variants =
        self.session.selectedIndex != NSNotFound ? self.session.items[self.session.selectedIndex].renditions.count : 0;
    [self.buttons[8] setEnabled:!loading && variants > 1];
    [self.buttons[12] setEnabled:!loading && [AVPictureInPictureController isPictureInPictureSupported]];
    [self.buttons[13] setEnabled:self.toggleFullScreen != nil];
    [self.buttons[14] setEnabled:self.toggleFloatingWindow != nil];
    [self.progress setEnabled:!loading];
    [self.status setHidden:self.controlsLocked];
    [self.progress setHidden:self.controlsLocked];
    // AirPlay receives the original AVPlayer source; custom FFmpeg/effect output requires a cast provider.
    self.routePicker.hidden = self.controlsLocked || controller.kernel != SGPlaybackKernelNative;
}
@end
