#import "SGPlaybackControls.h"
#import "SGPlayer.h"
#import "SGPlaybackGestures.h"
#import "SGTimelinePreview.h"
#import <QuartzCore/QuartzCore.h>
#if SGPLATFORM_TARGET_OS_IPHONE
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#endif
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
#if SGPLATFORM_TARGET_OS_MAC
@interface SGToolbarSeekSlider : NSSlider
@property(nonatomic) BOOL trackingSeek;
@end
@implementation SGToolbarSeekSlider
- (void)mouseDown:(NSEvent *)event {
    self.trackingSeek=YES;
    @try { [super mouseDown:event]; } @finally { self.trackingSeek=NO; }
    [self sendAction:self.action to:self.target];
}
@end
@interface SGToolbarSliderCell : NSSliderCell
@end
@implementation SGToolbarSliderCell
- (void)drawBarInside:(NSRect)rect flipped:(BOOL)flipped {
    NSRect track=NSMakeRect(rect.origin.x,NSMidY(rect)-2,rect.size.width,4);
    [[NSColor colorWithWhite:1 alpha:.30] setFill];
    [[NSBezierPath bezierPathWithRoundedRect:track xRadius:2 yRadius:2] fill];
    double span=self.maxValue-self.minValue;
    track.size.width *= span>0 ? MIN(1,MAX(0,(self.doubleValue-self.minValue)/span)) : 0;
    [[NSColor colorWithRed:1 green:.36 blue:.62 alpha:1] setFill];
    [[NSBezierPath bezierPathWithRoundedRect:track xRadius:2 yRadius:2] fill];
}
- (void)drawKnob:(NSRect)rect {
    [[NSColor colorWithRed:1 green:.36 blue:.62 alpha:1] setFill];
    [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(NSMidX(rect)-6,NSMidY(rect)-6,12,12)] fill];
}
@end
#endif
#if SGPLATFORM_TARGET_OS_IPHONE
@interface SGPlaybackControls () <UIDocumentPickerDelegate>
#elif SGPLATFORM_TARGET_OS_MAC
@interface SGPlaybackControls () <NSGestureRecognizerDelegate>
#else
@interface SGPlaybackControls ()
#endif
@property(nonatomic, strong, readwrite) SGPlaybackSession *session;
@property(nonatomic, strong) NSMutableArray *buttons;
@property(nonatomic, strong) id status;
@property(nonatomic, strong) id progress;
#if !SGPLATFORM_TARGET_OS_TV
@property(nonatomic, strong) SGPLFView *toolbarBackground;
@property(nonatomic, strong) id durationLabel;
@property(nonatomic, strong) id settingsButton;
@property(nonatomic, strong) id volumeButton;
@property(nonatomic, strong) SGPLFView *volumePanel;
@property(nonatomic, strong) id volumeSlider;
@property(nonatomic, strong) id advertisementButton;
#endif

@property(nonatomic, strong) AVRoutePickerView *routePicker;
@property(nonatomic, strong) NSTimer *timer;
@property(nonatomic) BOOL changingKernel;
#if SGPLATFORM_TARGET_OS_MAC
@property(nonatomic, weak) NSView *keyboardSurface;
@property(nonatomic, strong) id keyboardMonitor;
@property(nonatomic) float keyboardSavedVolume;
@property(nonatomic, strong) NSPanGestureRecognizer *vrPan;
@property(nonatomic) CGPoint startingVR;
@property(nonatomic) BOOL keyboardActive;
@property(nonatomic, strong) NSTrackingArea *keyboardTrackingArea;
#endif
@property(nonatomic, strong) SGPlaybackCover *cover;
@property(nonatomic, strong) SGPLFImage *configuredCoverImage;
@property(nonatomic) NSInteger pickingSourceKind;
@property(nonatomic, strong) SGTimelineSpriteIndex *timelineIndex;
@property(nonatomic, copy) NSURL *timelineURL;
@property(nonatomic, strong) NSCache<NSURL *, NSData *> *timelineImages;
@property(nonatomic, strong) dispatch_queue_t timelineQueue;
@property(nonatomic) NSUInteger timelineRevision;
@property(nonatomic) NSUInteger timelineImageRevision;
#if !SGPLATFORM_TARGET_OS_TV
@property(nonatomic, strong) SGPLFView *timelineImageView;
#endif
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
        _controlsEnabled = YES; _coverEnabled = YES;
        _timelineImages = [NSCache new]; _timelineImages.totalCostLimit = 16*1024*1024;
        _timelineQueue = dispatch_queue_create("org.sgplayer.timeline",DISPATCH_QUEUE_SERIAL);
        _showsVolumeControl = _showsSettingsControl = _showsFullscreenControl = _showsLockControl = YES;
        _buttons = [NSMutableArray array];
        NSArray *titles = @[
            @"▶︎ / Ⅱ", @"−10s", @"+10s", @"Previous", @"Next", @"Kernel", @"Audio", @"Subtitles", @"Quality", @"Speed",
            @"Retry", @"Lock", @"PiP", @"Full screen", @"Mini player"
        ];
        NSArray *identifiers = @[
            @"play", @"back", @"forward", @"previous", @"next", @"kernel", @"audio", @"subtitles", @"quality", @"speed",
            @"retry", @"lock", @"pip", @"fullscreen", @"floating"
        ];
#if !SGPLATFORM_TARGET_OS_TV
        titles = [titles arrayByAddingObjectsFromArray:@[@"加载字幕",@"加载弹幕",@"弹幕开关",@"字幕开关",@"后台画中画",@"保留最后一帧",@"水印开关",@"加载预览 WebVTT",@"画面比例",@"镜像",@"循环",@"截图",@"纯播放",@"封面",@"文字背景"]];
        identifiers = [identifiers arrayByAddingObjectsFromArray:@[@"loadSubtitle",@"loadDanmaku",@"danmaku",@"subtitleVisibility",@"automaticPip",@"keepLastFrame",@"watermark",@"loadTimeline",@"scale",@"mirror",@"loop",@"screenshot",@"purePlay",@"cover",@"textBackground"]];
#endif
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
        SGToolbarSeekSlider *progress = [SGToolbarSeekSlider new];
        progress.minValue=0;progress.maxValue=1;progress.doubleValue=0;progress.target=self;progress.action=@selector(scrub:);
        progress.continuous = YES;
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
        [self installToolbarStyle];
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
- (void)loadTimelineSpritesFromURL:(NSURL *)URL completion:(void (^)(NSError *))completion {
    if (URL && [self.timelineURL isEqual:URL] && self.timelineIndex) { completion(nil); return; }
    self.timelineURL=URL;
    NSUInteger revision = ++self.timelineRevision;
    self.timelineImageRevision++; self.timelineIndex=nil; [self.timelineImages removeAllObjects];
#if !SGPLATFORM_TARGET_OS_TV
    self.timelineImageView.hidden = YES;
#endif
    if (!URL) { completion(nil); return; }
    dispatch_async(self.timelineQueue, ^{
        NSError *error=nil;
        NSString *text=[NSString stringWithContentsOfURL:URL encoding:NSUTF8StringEncoding error:&error];
        SGTimelineSpriteIndex *index=text?[SGTimelineSpriteIndex indexWithWebVTT:text baseURL:URL error:&error]:nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (revision != self.timelineRevision) { completion([NSError errorWithDomain:@"SGTimeline" code:1 userInfo:@{NSLocalizedDescriptionKey:@"Preview source superseded"}]); return; }
            self.timelineIndex=index; completion(error);
        });
    });
}
- (void)timelineImageAtTime:(CMTime)time completion:(void (^)(SGPLFImage *,NSError *))completion {
    SGTimelineSpriteCue *cue=[self.timelineIndex cueAtTime:time];
    if (!cue) { completion(nil,nil); return; }
    dispatch_async(self.timelineQueue, ^{
        NSError *error=nil;NSData *data=[self.timelineImages objectForKey:cue.URL];
        if (!data) { data=[NSData dataWithContentsOfURL:cue.URL options:0 error:&error];if(data.length<=16*1024*1024 && data)[self.timelineImages setObject:data forKey:cue.URL cost:data.length]; }
        CIImage *image=data?[SGTimelineSpriteIndex imageForCue:cue imageData:data maximumDimension:320 error:&error]:nil;
        CGImageRef cg=image?[[CIContext contextWithOptions:nil] createCGImage:image fromRect:image.extent]:nil;
#if SGPLATFORM_TARGET_OS_MAC
        SGPLFImage *result=cg?[[NSImage alloc]initWithCGImage:cg size:NSZeroSize]:nil;
#else
        SGPLFImage *result=cg?[UIImage imageWithCGImage:cg]:nil;
#endif
        if(cg)CGImageRelease(cg);
        dispatch_async(dispatch_get_main_queue(), ^{ completion(result,error); });
    });
}
#if !SGPLATFORM_TARGET_OS_TV
- (void)showTimelineFraction:(double)fraction {
    if (!self.timelineIndex || self.controlsLocked || self.session.advertisementActive) return;
    double duration=CMTimeGetSeconds(self.session.controller.duration);if(!isfinite(duration)||duration<=0)return;
    NSUInteger revision=++self.timelineImageRevision;
    if (!self.timelineImageView) {
#if SGPLATFORM_TARGET_OS_MAC
        NSImageView *view=[NSImageView new];view.imageScaling=NSImageScaleProportionallyUpOrDown;view.wantsLayer=YES;view.layer.backgroundColor=NSColor.blackColor.CGColor;
#else
        UIImageView *view=[UIImageView new];view.contentMode=UIViewContentModeScaleAspectFit;view.backgroundColor=UIColor.blackColor;view.userInteractionEnabled=NO;
#endif
        view.accessibilityIdentifier=@"session.timelinePreview";self.timelineImageView=view;[self addSubview:view];
    }
    CGFloat width=MIN(160,MAX(0,self.bounds.size.width-16)),height=MIN(90,MAX(0,self.bounds.size.height-108));
    CGFloat x=MAX(8,MIN(self.bounds.size.width-width-8,self.bounds.size.width*MIN(1,MAX(0,fraction))-width/2));
#if SGPLATFORM_TARGET_OS_MAC
    CGFloat y=self.toolbarBackground.frame.size.height+4;
#else
    CGFloat y=MAX(self.safeAreaInsets.top,self.toolbarBackground.frame.origin.y-height-4);
#endif
    self.timelineImageView.frame=CGRectMake(x,y,width,height);
    [self timelineImageAtTime:CMTimeMakeWithSeconds(duration*fraction,1000) completion:^(SGPLFImage *image,NSError *error) {
        if(revision!=self.timelineImageRevision)return;
        [(id)self.timelineImageView setImage:image];self.timelineImageView.hidden=image==nil;
    }];
}
#endif
- (void)revealControls {
    if (!self.controlsEnabled) return;
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
    hidden = self.controlsEnabled ? hidden : NO;
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
    self.configuredCoverImage = image;
    _coverEnabled = image != nil;
    [self.cover close];
    self.cover = [[SGPlaybackCover alloc] initWithSession:self.session view:view image:image];
    self.cover.keepLastFrameWhenComplete = self.keepLastFrameWhenComplete;
    [self.cover refresh];
}
- (void)setCoverEnabled:(BOOL)enabled {
    _coverEnabled = enabled;
    self.cover.image = enabled ? self.configuredCoverImage : nil;
    [self.cover refresh];
}
- (void)setControlsEnabled:(BOOL)enabled {
    _controlsEnabled = enabled;
#if SGPLATFORM_TARGET_OS_IPHONE
    self.gestures.locked = !enabled || self.controlsLocked;
#endif
    self.hidden = NO;
    [self refresh];
    if (enabled) [self revealControls];
}
- (void)setKeepLastFrameWhenComplete:(BOOL)enabled {
    _keepLastFrameWhenComplete = enabled;
    self.cover.keepLastFrameWhenComplete = enabled;
    [self.cover refresh];
}
- (void)setControlsLocked:(BOOL)controlsLocked {
    _controlsLocked = controlsLocked;
#if SGPLATFORM_TARGET_OS_IPHONE
    self.gestures.locked = controlsLocked || !self.controlsEnabled;
#endif
    [self revealControls];
    [self refresh];
}

- (void)installToolbarStyle {
#if !SGPLATFORM_TARGET_OS_TV
#if SGPLATFORM_TARGET_OS_MAC
    self.layer.backgroundColor = NSColor.clearColor.CGColor;
    self.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    self.routePicker.routePickerButtonBordered = NO;
    [self.progress setCell:[SGToolbarSliderCell new]];
    [self.progress setMinValue:0]; [self.progress setMaxValue:1];
    [self.progress setTarget:self]; [self.progress setAction:@selector(scrub:)]; [self.progress setContinuous:YES];
    NSView *background = [NSView new];
    background.wantsLayer = YES;
    background.layer.backgroundColor = [NSColor colorWithWhite:0 alpha:.60].CGColor;
    self.durationLabel = [NSTextField labelWithString:@"00:00"];
    self.settingsButton = [NSButton buttonWithTitle:@"" target:self action:@selector(showSettings:)];
    self.volumeButton = [NSButton buttonWithTitle:@"" target:self action:@selector(toggleVolume:)];
    [self.durationLabel setTextColor:NSColor.whiteColor];
    [self.status setTextColor:NSColor.whiteColor];
#else
    self.backgroundColor = UIColor.clearColor;
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    UIView *background = [UIView new];
    background.backgroundColor = [UIColor colorWithWhite:0 alpha:.60];
    background.userInteractionEnabled = NO;
    self.durationLabel = [UILabel new];
    [self.durationLabel setTextColor:UIColor.whiteColor];
    self.settingsButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.volumeButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.volumeButton addTarget:self action:@selector(toggleVolume:) forControlEvents:UIControlEventTouchUpInside];
    [self.progress setMinimumTrackTintColor:[UIColor colorWithRed:1 green:.36 blue:.62 alpha:1]];
    [self.progress setThumbTintColor:[UIColor colorWithRed:1 green:.36 blue:.62 alpha:1]];
#endif
#if SGPLATFORM_TARGET_OS_MAC
    NSView *panel = [NSView new]; panel.wantsLayer = YES;
    panel.layer.backgroundColor = [NSColor colorWithWhite:0 alpha:.9].CGColor;
    self.volumeSlider = [NSSlider sliderWithValue:1 minValue:0 maxValue:1 target:self action:@selector(volumeChanged:)];
    [self.volumeSlider setContinuous:YES];
    [self.volumeSlider setVertical:YES];
#else
    UIView *panel = [UIView new]; panel.backgroundColor = [UIColor colorWithWhite:0 alpha:.9];
    UISlider *volume = [UISlider new]; volume.minimumValue = 0; volume.maximumValue = 1;
    volume.minimumTrackTintColor = [UIColor colorWithRed:1 green:.36 blue:.62 alpha:1];
    [volume addTarget:self action:@selector(volumeChanged:) forControlEvents:UIControlEventValueChanged];
    volume.transform = CGAffineTransformMakeRotation(-M_PI_2);
    self.volumeSlider = volume;
#endif
    panel.layer.cornerRadius = 8; panel.hidden = YES; self.volumePanel = panel;
    [self.volumeSlider setAccessibilityIdentifier:@"session.volume.slider"];
    [panel addSubview:self.volumeSlider]; [self addSubview:panel];
    self.toolbarBackground = background;
#if SGPLATFORM_TARGET_OS_MAC
    [self addSubview:background positioned:NSWindowBelow relativeTo:nil];
#else
    [self insertSubview:background atIndex:0];
#endif
    for (id view in @[self.durationLabel, self.settingsButton, self.volumeButton]) [self addSubview:view];
    [self.settingsButton setAccessibilityIdentifier:@"session.settings"];
    [self.volumeButton setAccessibilityIdentifier:@"session.volume"];
    [self setToolbarSymbol:@"gearshape" title:@"设置" button:self.settingsButton];
    [self setToolbarSymbol:@"speaker.wave.2" title:@"音量" button:self.volumeButton];
#endif
}
#if !SGPLATFORM_TARGET_OS_TV
- (void)setToolbarSymbol:(NSString *)symbol title:(NSString *)title button:(id)button {
#if SGPLATFORM_TARGET_OS_MAC
    [button setTitle:@""];
    [button setImage:[NSImage imageWithSystemSymbolName:symbol accessibilityDescription:title]];
    [button setBordered:NO];
    [button setContentTintColor:NSColor.whiteColor];
    [button setToolTip:title];
#else
    [button setTitle:@"" forState:UIControlStateNormal];
    [button setImage:[UIImage systemImageNamed:symbol] forState:UIControlStateNormal];
    [button setTintColor:UIColor.whiteColor];
    [button setAccessibilityLabel:title];
#endif
}
- (void)toggleVolume:(id)sender {
    [self revealControls];
    self.volumePanel.hidden = !self.volumePanel.hidden;
#if SGPLATFORM_TARGET_OS_MAC
    [self.volumeSlider setDoubleValue:self.session.controller.volume];
#else
    [(UISlider *)self.volumeSlider setValue:self.session.controller.volume];
#endif
    [self arrangeToolbar];
}
- (void)volumeChanged:(id)sender {
    [self revealControls];
#if SGPLATFORM_TARGET_OS_MAC
    self.session.controller.volume = [sender doubleValue];
#else
    self.session.controller.volume = [(UISlider *)sender value];
#endif
}
- (NSArray<NSNumber *> *)settingsActions { return @[@6,@7,@8,@17,@18,@23,@24,@25]; }
- (NSArray<NSNumber *> *)moreSettingsActions { return @[@1,@2,@3,@4,@5,@10,@12,@14,@15,@16,@19,@20,@21,@22,@26,@27,@28,@29]; }

#if SGPLATFORM_TARGET_OS_MAC
- (NSMenu *)settingsMenuForActions:(NSArray<NSNumber *> *)actions {
    NSMenu *menu = [NSMenu new];
    for (NSNumber *index in actions) {
        NSInteger i = index.integerValue;
        if (i == 5 && !self.showsKernelSelection) continue;
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:[self settingsTitle:i] action:@selector(settingsSelected:) keyEquivalent:@""];
        item.target = self; item.tag = i; item.enabled = [self.buttons[i] isEnabled];
        [menu addItem:item];
    }
    menu.autoenablesItems = NO;
    return menu;
}
- (void)showSettings:(id)sender {
    [self revealControls];
    NSMenu *menu = [self settingsMenuForActions:[self settingsActions]];
    NSMenuItem *more=[[NSMenuItem alloc]initWithTitle:@"更多设置" action:nil keyEquivalent:@""];
    more.submenu=[self settingsMenuForActions:[self moreSettingsActions]];
    more.accessibilityIdentifier=@"session.moreSettings";
    [menu addItem:more];
    [menu popUpMenuPositioningItem:nil atLocation:NSMakePoint(0,0) inView:sender];
}
- (void)settingsSelected:(NSMenuItem *)item { [self pressed:self.buttons[item.tag]]; }
#endif
- (NSString *)settingsTitle:(NSInteger)i {
    NSDictionary *names = @{@1:@"后退 10 秒", @2:@"前进 10 秒", @3:@"上一集", @4:@"下一集", @5:@"播放内核", @6:@"切换音轨", @7:@"切换字幕", @8:@"切换清晰度", @10:@"重新加载", @12:@"画中画", @14:@"悬浮播放",@15:@"加载字幕文件",@16:@"加载弹幕 XML",@17:(self.session.controller.effects.danmakuEnabled?@"弹幕：开":@"弹幕：关"),@18:(self.session.controller.effects.subtitlesEnabled?@"字幕：开":@"字幕：关"),@19:(self.session.controller.automaticPictureInPictureEnabled?@"后台画中画：开":@"后台画中画：关"),@20:(self.keepLastFrameWhenComplete?@"保留最后一帧：开":@"保留最后一帧：关"),@21:(self.session.controller.effects.watermarksEnabled?@"水印：开":@"水印：关"),@22:@"加载预览 WebVTT",@23:@"切换画面比例",@24:(self.session.controller.effects.filter.horizontalFlip?@"镜像：开":@"镜像：关"),@25:(self.session.loopMode==SGPlaybackLoopModeNone?@"循环：关":self.session.loopMode==SGPlaybackLoopModeOne?@"单集循环":@"列表循环"),@26:@"截图",@27:@"纯播放",@28:(self.coverEnabled?@"封面：开":@"封面：关"),@29:(self.session.controller.effects.textBackgroundEnabled?@"文字背景：开":@"文字背景：关")};
    return names[@(i)] ?: @"";
}
- (void)skipAdvertisement:(id)sender { [self.session skipAdvertisement]; [self refresh]; }
- (void)refreshToolbar {
    if (!self.advertisementButton) {
#if SGPLATFORM_TARGET_OS_MAC
        NSButton *button = [NSButton buttonWithTitle:@"广告" target:self action:@selector(skipAdvertisement:)];
        button.bezelStyle = NSBezelStyleRounded;
#else
        UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
        button.backgroundColor = [UIColor colorWithWhite:0 alpha:.75];
        button.tintColor = UIColor.whiteColor;
        [button addTarget:self action:@selector(skipAdvertisement:) forControlEvents:UIControlEventTouchUpInside];
#endif
        button.accessibilityIdentifier = @"session.skipAd";
        self.advertisementButton = button;
        [self addSubview:button];
    }
    [self.advertisementButton setHidden:!self.session.advertisementActive];
    NSString *adTitle = self.session.canSkipAdvertisement ? @"广告 · 跳过" : [NSString stringWithFormat:@"广告 · %.0f秒后可跳过", ceil(self.session.advertisementSkipRemaining)];
#if SGPLATFORM_TARGET_OS_MAC
    [self.advertisementButton setTitle:adTitle];
#else
    [self.advertisementButton setTitle:adTitle forState:UIControlStateNormal];
#endif
    [self.advertisementButton setEnabled:self.session.canSkipAdvertisement];
    SGPlaybackController *c = self.session.controller;
    double t = CMTimeGetSeconds(c.currentTime), d = CMTimeGetSeconds(c.duration);
    NSString *(^clock)(double) = ^NSString *(double v) {
        NSInteger n = isfinite(v) && v > 0 ? (NSInteger)v : 0;
        return n >= 3600 ? [NSString stringWithFormat:@"%ld:%02ld:%02ld",(long)(n/3600),(long)(n/60%60),(long)(n%60)] : [NSString stringWithFormat:@"%02ld:%02ld",(long)(n/60),(long)(n%60)];
    };
#if SGPLATFORM_TARGET_OS_MAC
    [self.status setStringValue:clock(t)]; [self.durationLabel setStringValue:clock(d)];
    [self.buttons[9] setTitle:[NSString stringWithFormat:@"%.1fx",c.rate]];
    [self.buttons[9] setBordered:NO]; [self.buttons[9] setContentTintColor:NSColor.whiteColor];
#else
    [self.status setText:clock(t)]; [self.durationLabel setText:clock(d)];
    [self.buttons[9] setTitle:[NSString stringWithFormat:@"%.1fx",c.rate] forState:UIControlStateNormal];
    [self.buttons[9] setTintColor:UIColor.whiteColor];
    NSMutableArray *items = [NSMutableArray array];
    __weak typeof(self) weakSelf = self;
    NSMutableArray *moreItems=[NSMutableArray array];
    for (NSNumber *index in [[self settingsActions] arrayByAddingObjectsFromArray:[self moreSettingsActions]]) {
        NSInteger i = index.integerValue;
        if (i == 5 && !self.showsKernelSelection) continue;
        UIAction *action = [UIAction actionWithTitle:[self settingsTitle:i] image:nil identifier:nil handler:^(UIAction *a) { [weakSelf pressed:weakSelf.buttons[i]]; }];
        if (![self.buttons[i] isEnabled]) action.attributes = UIMenuElementAttributesDisabled;
        if([[self settingsActions] containsObject:index]) [items addObject:action]; else [moreItems addObject:action];
    }
    [items addObject:[UIMenu menuWithTitle:@"更多设置" image:nil identifier:@"session.moreSettings" options:0 children:moreItems]];
    [self.settingsButton setMenu:[UIMenu menuWithChildren:items]];
    [self.settingsButton setShowsMenuAsPrimaryAction:YES];
#endif
    [self setToolbarSymbol:c.playing ? @"pause.fill" : @"play.fill" title:c.playing ? @"暂停" : @"播放" button:self.buttons[0]];
    [self setToolbarSymbol:self.controlsLocked ? @"lock.fill" : @"lock.open.fill" title:self.controlsLocked ? @"解锁" : @"锁定" button:self.buttons[11]];
    [self setToolbarSymbol:@"arrow.up.left.and.arrow.down.right" title:@"全屏" button:self.buttons[13]];
    [self setToolbarSymbol:c.volume > 0 ? @"speaker.wave.2" : @"speaker.slash" title:@"音量" button:self.volumeButton];
    for (NSInteger i = 0; i < self.buttons.count; i++) [self.buttons[i] setHidden:self.controlsLocked ? i != 11 : !(i == 0 || i == 9 || i == 11 || i == 13)];
    [self.settingsButton setHidden:self.controlsLocked || !self.showsSettingsControl]; [self.volumeButton setHidden:self.controlsLocked || !self.showsVolumeControl];
    [self.buttons[13] setHidden:self.controlsLocked || !self.showsFullscreenControl];
    [self.buttons[11] setHidden:!self.showsLockControl && !self.controlsLocked];
    [self.durationLabel setHidden:self.controlsLocked]; self.toolbarBackground.hidden = self.controlsLocked;
    if (!self.controlsEnabled) {
        for (NSInteger i=0;i<self.buttons.count;i++) [self.buttons[i] setHidden:i!=0];
        for(id view in @[self.status,self.progress,self.durationLabel,self.settingsButton,self.volumeButton,self.routePicker,self.volumePanel,self.toolbarBackground]) [view setHidden:YES];
    }
    [self arrangeToolbar];
}
- (void)arrangeToolbar {
    CGFloat w = self.bounds.size.width, h = self.bounds.size.height;
#if !SGPLATFORM_TARGET_OS_MAC
    UIEdgeInsets safe = self.safeAreaInsets;
    w = MAX(0,w-safe.left-safe.right); h = MAX(0,h-safe.top-safe.bottom);
#endif
#if SGPLATFORM_TARGET_OS_MAC
    [self.advertisementButton setFrame:CGRectMake(MAX(0,w-180),MAX(0,h-48),176,44)];
#else
    [self.advertisementButton setFrame:CGRectMake(safe.left+MAX(0,w-180),safe.top+4,176,44)];
#endif
    BOOL narrow = w < 560;
    CGFloat bar = narrow ? 92 : 48, hit = MIN(44, MAX(28,w/8));
#if SGPLATFORM_TARGET_OS_MAC
    CGFloat base = 0, seekY = narrow ? 46 : 2;
#else
    CGFloat base = MAX(0,h-bar), seekY = base + 2;
#endif
    self.toolbarBackground.frame = CGRectMake(0,base,w,bar);
    CGFloat start = narrow ? 8 : hit+8, end = narrow ? w-64 : w-5*hit-64;
    [self.status setFrame:CGRectMake(start,seekY+13,48,18)];
    [self.progress setFrame:CGRectMake(start+48,seekY,MAX(16,end-start-48),44)];
    [self.durationLabel setFrame:CGRectMake(end,seekY+13,56,18)];
    CGFloat actionY;
#if SGPLATFORM_TARGET_OS_MAC
    actionY = 2;
#else
    actionY = narrow ? base+46 : base+2;
#endif
    [self.buttons[0] setFrame:CGRectMake(4,actionY,hit,44)];
    NSArray *actions = @[self.buttons[9],self.settingsButton,self.volumeButton,self.routePicker,self.buttons[13]];
    for (NSInteger i=0;i<actions.count;i++) [actions[i] setFrame:CGRectMake(w-(5-i)*hit,actionY,hit,44)];
    [self.buttons[11] setFrame:CGRectMake(MAX(0,w-64),MAX(0,(h-44)/2),44,44)];
    self.routePicker.hidden = self.controlsLocked || self.session.controller.kernel != SGPlaybackKernelNative;
    CGFloat panelHeight = MIN(152,MAX(64,h-bar-12));
#if SGPLATFORM_TARGET_OS_MAC
    CGFloat panelY = bar+4;
#else
    CGFloat panelY = MAX(0,base-panelHeight-4);
#endif
    self.volumePanel.frame = CGRectMake(MIN(MAX(8,w-3*hit+(hit-48)/2),MAX(8,w-56)),panelY,48,panelHeight);
#if SGPLATFORM_TARGET_OS_MAC
    [self.volumeSlider setFrame:CGRectMake(8,8,32,panelHeight-16)];
#else
    UISlider *vertical=self.volumeSlider;
    vertical.bounds=CGRectMake(0,0,panelHeight-16,32);
    vertical.center=CGPointMake(24,panelHeight/2);
#endif
    if (self.controlsLocked || !self.controlsEnabled) self.volumePanel.hidden = YES;
#if !SGPLATFORM_TARGET_OS_MAC
    for (id item in @[self.status,self.progress,self.durationLabel,self.buttons[0],self.buttons[9],self.buttons[11],self.buttons[13],self.settingsButton,self.volumeButton,self.routePicker,self.volumePanel]) {
        CGRect frame=[item frame]; frame.origin.x+=safe.left; frame.origin.y+=safe.top; [item setFrame:frame];
    }
    self.toolbarBackground.frame=CGRectMake(0,base+safe.top,self.bounds.size.width,bar+safe.bottom);
#endif


}
#if SGPLATFORM_TARGET_OS_MAC
- (NSView *)hitTest:(NSPoint)point { NSView *hit = [super hitTest:point]; return hit == self || hit == self.toolbarBackground ? nil : hit; }
#else
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event { UIView *hit = [super hitTest:point withEvent:event]; return hit == self ? nil : hit; }
#endif
#endif
- (void)arrange {
#if !SGPLATFORM_TARGET_OS_TV
    [self arrangeToolbar];
    return;
#endif
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
    [self.vrPan.view removeGestureRecognizer:self.vrPan];self.vrPan=nil;
    self.keyboardSurface = view;
    if (!view)
        return;
    self.vrPan=[[NSPanGestureRecognizer alloc]initWithTarget:self action:@selector(panVR:)];self.vrPan.delegate=self;[view addGestureRecognizer:self.vrPan];
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
- (BOOL)gestureRecognizer:(NSGestureRecognizer *)gesture shouldAttemptToRecognizeWithEvent:(NSEvent *)event {
    if(gesture!=self.vrPan)return YES;
    if(!self.controlsEnabled || self.controlsLocked || self.session.controller.kernel!=SGPlaybackKernelFFmpeg || self.session.controller.ffmpegPlayer.videoRenderer.displayMode==SGDisplayModePlane)return NO;
    NSView *surface=self.keyboardSurface;
    NSPoint point=[surface.superview convertPoint:event.locationInWindow fromView:nil];
    for(NSView *hit=[surface hitTest:point];hit&&hit!=surface;hit=hit.superview) if([hit isKindOfClass:NSControl.class])return NO;
    return YES;
}
- (void)panVR:(NSPanGestureRecognizer *)gesture {
    SGVRViewport *viewport=self.session.controller.ffmpegPlayer.videoRenderer.viewport;
    if(gesture.state==NSGestureRecognizerStateBegan)self.startingVR=CGPointMake(viewport.x,viewport.y);
    if(gesture.state==NSGestureRecognizerStateBegan || gesture.state==NSGestureRecognizerStateChanged) {
        NSPoint delta=[gesture translationInView:self.keyboardSurface];
        viewport.x=self.startingVR.x-delta.x/MAX(1,self.keyboardSurface.bounds.size.height)*viewport.degress;
        CGFloat sign=self.keyboardSurface.flipped?1:-1;
        viewport.y=MIN(89,MAX(-89,self.startingVR.y+sign*delta.y/MAX(1,self.keyboardSurface.bounds.size.height)*viewport.degress));
        [self revealControls];
    }
}
- (BOOL)handleKeyEvent:(NSEvent *)event {
    if (!self.controlsEnabled) {
        if(event.type==NSEventTypeKeyDown && [event.charactersIgnoringModifiers isEqual:@" "] && !(event.modifierFlags&(NSEventModifierFlagCommand|NSEventModifierFlagControl|NSEventModifierFlagOption))) { if(!event.isARepeat)[self pressed:self.buttons[0]]; return YES; }
        if (event.type==NSEventTypeKeyDown && event.keyCode==53 && self.dismissPresentation) { self.dismissPresentation(); return YES; }
        return NO;
    }
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
    if(self.session.controller.kernel==SGPlaybackKernelFFmpeg && self.session.controller.ffmpegPlayer.videoRenderer.displayMode!=SGDisplayModePlane && event.keyCode>=123 && event.keyCode<=126) {
        SGVRViewport *viewport=self.session.controller.ffmpegPlayer.videoRenderer.viewport;
        if(event.keyCode==123)viewport.x-=5;else if(event.keyCode==124)viewport.x+=5;
        else viewport.y=MIN(89,MAX(-89,viewport.y+(event.keyCode==126?5:-5)));
        return YES;
    }
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
    if (self.controlsLocked || self.session.advertisementActive || !isfinite(seconds))
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
    if (self.controlsLocked || self.session.advertisementActive)
        return;
#if SGPLATFORM_TARGET_OS_MAC
    double fraction = [sender doubleValue];
    if ([sender isKindOfClass:SGToolbarSeekSlider.class] && [(SGToolbarSeekSlider *)sender trackingSeek]) { [self showTimelineFraction:fraction]; return; }
    self.timelineImageView.hidden = YES;
#elif !SGPLATFORM_TARGET_OS_TV
    double fraction = ((UISlider *)sender).value;
#else
    return;
    double fraction = 0;
#endif
#if !SGPLATFORM_TARGET_OS_TV
    self.timelineImageRevision++;
    self.timelineImageView.hidden = YES;
#endif
    double duration = CMTimeGetSeconds(self.session.controller.duration);
    if (!isfinite(duration) || duration <= 0)
        return;
    [self.session.controller seekToTime:CMTimeMakeWithSeconds(MIN(MAX(0, fraction), 1) * MAX(0, duration - .1), 1000)
                             completion:^(BOOL success){
                             }];
}
#if !SGPLATFORM_TARGET_OS_TV
- (void)loadSelectedSource:(NSURL *)URL kind:(NSInteger)kind {
    if (kind != 2) { [self loadSource:URL danmaku:kind == 1]; return; }
    BOOL scoped = [URL startAccessingSecurityScopedResource];
    [self loadTimelineSpritesFromURL:URL completion:^(NSError *failure) { if(scoped)[URL stopAccessingSecurityScopedResource]; }];
}
- (void)loadSource:(NSURL *)URL danmaku:(BOOL)danmaku {
    BOOL scoped = [URL startAccessingSecurityScopedResource];
    __weak typeof(self) weakSelf = self;
    void (^finished)(NSError *) = ^(NSError *failure) {
        if (scoped) [URL stopAccessingSecurityScopedResource];
        if (!failure || !weakSelf.window) return;
#if SGPLATFORM_TARGET_OS_MAC
        NSAlert *alert = [NSAlert new]; alert.messageText = @"加载失败"; alert.informativeText = failure.localizedDescription;
        [alert beginSheetModalForWindow:weakSelf.window completionHandler:nil];
#else
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"加载失败" message:failure.localizedDescription preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
        [[weakSelf sourcePresenter] presentViewController:alert animated:YES completion:nil];
#endif
    };
    if (danmaku) [self.session.controller loadDanmakuFromURL:URL completion:finished];
    else { self.session.controller.effects.subtitlesEnabled = YES; [self.session.controller loadSubtitlesFromURL:URL completion:finished]; }
}
#if SGPLATFORM_TARGET_OS_MAC
- (void)chooseSource:(NSInteger)kind {
    BOOL danmaku = kind == 1;
    NSOpenPanel *panel = [NSOpenPanel openPanel];panel.canChooseDirectories=NO;panel.allowsMultipleSelection=NO;
    panel.allowedFileTypes=kind==2?@[@"vtt"]:danmaku?@[@"xml"]:@[@"vtt",@"srt",@"ass",@"ssa",@"sub",@"sup",@"mks"];
    __weak typeof(self) weakSelf=self;
    [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) { if (response == NSModalResponseOK && panel.URL) [weakSelf loadSelectedSource:panel.URL kind:kind]; }];
}
#else
- (UIViewController *)sourcePresenter {
    UIViewController *presenter = self.window.rootViewController;
    while (presenter.presentedViewController) presenter = presenter.presentedViewController;
    return presenter;
}
- (void)chooseSource:(NSInteger)kind {
    BOOL danmaku = kind == 1;
    self.pickingSourceKind = kind;
    UIDocumentPickerViewController *picker=[[UIDocumentPickerViewController alloc]initForOpeningContentTypes:@[danmaku?UTTypeXML:UTTypeData] asCopy:YES];
    picker.allowsMultipleSelection=NO;picker.delegate=self;
    [[self sourcePresenter] presentViewController:picker animated:YES completion:nil];
}
- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)URLs {
    if (URLs.firstObject) [self loadSelectedSource:URLs.firstObject kind:self.pickingSourceKind];
}
#endif
#endif
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
#if !SGPLATFORM_TARGET_OS_TV
    case 15: [self chooseSource:NO]; break;
    case 16: [self chooseSource:YES]; break;
    case 17: controller.effects.danmakuEnabled = !controller.effects.danmakuEnabled; break;
    case 18: controller.effects.subtitlesEnabled = !controller.effects.subtitlesEnabled; break;
    case 19: controller.automaticPictureInPictureEnabled = !controller.automaticPictureInPictureEnabled; break;
    case 20: self.keepLastFrameWhenComplete = !self.keepLastFrameWhenComplete; break;
    case 21: controller.effects.watermarksEnabled = !controller.effects.watermarksEnabled; break;
    case 22: [self chooseSource:2]; break;
    case 23: controller.videoGravity = [controller.videoGravity isEqual:AVLayerVideoGravityResizeAspect] ? AVLayerVideoGravityResizeAspectFill : [controller.videoGravity isEqual:AVLayerVideoGravityResizeAspectFill] ? AVLayerVideoGravityResize : AVLayerVideoGravityResizeAspect; break;
    case 24: { SGFilterConfiguration *filter=controller.effects.filter.copy;filter.horizontalFlip=!filter.horizontalFlip;controller.effects.filter=filter; break; }
    case 25: self.session.loopMode = (self.session.loopMode+1)%3; break;
    case 26: { SGPLFImage *image=controller.currentImage;if(image&&self.screenshotCaptured)self.screenshotCaptured(image);break; }
    case 27:
#if SGPLATFORM_TARGET_OS_MAC
        self.keyboardActive=YES;[self.window makeFirstResponder:self];
#endif
        self.controlsEnabled=NO;break;
    case 29: controller.effects.textBackgroundEnabled=!controller.effects.textBackgroundEnabled; break;
    case 28: self.coverEnabled=!self.coverEnabled;break;
#endif
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
    if (slider.tracking) {
        [self revealControls];
        [self showTimelineFraction:slider.value];
    }
    else
        [self scrub:slider];
}
#endif
- (void)refresh {
    [self.cover refresh];
    if (!self.controlsEnabled) {
#if !SGPLATFORM_TARGET_OS_TV
        self.hidden = NO; [self refreshToolbar];
#endif
        return;
    }
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
    if (self.session.advertisementActive || self.session.state != SGPlaybackSessionStatePlaying || self.controlsLocked)
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
        [self.buttons[i] setHidden:(self.controlsLocked && i != 11) || (i == 5 && !self.showsKernelSelection)];
    BOOL loading = self.session.state == SGPlaybackSessionStateLoading;
    [self.buttons[1] setEnabled:!loading];
    [self.buttons[2] setEnabled:!loading];
    [self.buttons[5] setEnabled:!loading && !self.changingKernel];
    [self.buttons[6] setEnabled:!loading && controller.audioTrackTitles.count > 0];
    [self.buttons[7] setEnabled:!loading && controller.subtitleTracks.count > 0];
    NSUInteger variants =
        self.session.selectedIndex != NSNotFound ? self.session.items[self.session.selectedIndex].renditions.count : 0;
    [self.buttons[8] setEnabled:!loading && variants > 1];
#if SGPLATFORM_TARGET_OS_MAC
    [self.buttons[12] setEnabled:!loading];
#else
    [self.buttons[12] setEnabled:!loading && [AVPictureInPictureController isPictureInPictureSupported]];
#endif
    [self.buttons[13] setEnabled:self.toggleFullScreen != nil];
    [self.buttons[14] setEnabled:self.toggleFloatingWindow != nil];
#if !SGPLATFORM_TARGET_OS_TV
    [self.buttons[26] setEnabled:self.screenshotCaptured != nil];
#endif
    [self.progress setEnabled:!loading];
    [self.status setHidden:self.controlsLocked];
    [self.progress setHidden:self.controlsLocked];
    // AirPlay receives the original AVPlayer source; custom FFmpeg/effect output requires a cast provider.
    self.routePicker.hidden = self.controlsLocked || controller.kernel != SGPlaybackKernelNative;
#if !SGPLATFORM_TARGET_OS_TV
    [self refreshToolbar];
#endif
}
@end
