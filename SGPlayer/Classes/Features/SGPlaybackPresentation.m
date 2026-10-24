#import "SGPlaybackPresentation.h"
#if SGPLATFORM_TARGET_OS_TV
@interface SGPresentationHost : UIView
@property(nonatomic, weak) UIView *preferredControl;
@end
@implementation SGPresentationHost
- (NSArray<id<UIFocusEnvironment>> *)preferredFocusEnvironments {
    return self.preferredControl ? @[ self.preferredControl ] : super.preferredFocusEnvironments;
}
@end
#endif
@interface SGPlaybackPresentation ()
@property(nonatomic, strong) SGPLFView *surface;
@property(nonatomic, weak) SGPLFView *originalParent;
@property(nonatomic) CGRect originalFrame;
@property(nonatomic) NSUInteger originalMask;
@property(nonatomic) NSUInteger originalIndex;
@property(nonatomic, strong) SGPLFView *host;
@property(nonatomic, readwrite) SGPlaybackPresentationMode mode;
@property(nonatomic) CGRect dragFrame;
#if SGPLATFORM_TARGET_OS_TV
@property(nonatomic, strong) UIFocusGuide *restoreGuide;
#endif
@end
@implementation SGPlaybackPresentation
- (instancetype)initWithSurface:(SGPLFView *)surface {
    NSParameterAssert(surface);
    if ((self = [super init]))
        _surface = surface;
    return self;
}
- (void)dealloc {
    [self restore];
}
- (BOOL)presentIn:(SGPLFView *)container frame:(CGRect)frame mode:(SGPlaybackPresentationMode)mode {
    NSAssert(NSThread.isMainThread, @"Main thread required");
    for (SGPLFView *ancestor = container; ancestor; ancestor = ancestor.superview)
        if (ancestor == self.surface)
            return NO;
    if (!container || !isfinite(frame.origin.x) || !isfinite(frame.origin.y) || !isfinite(frame.size.width) ||
        !isfinite(frame.size.height) || frame.size.width < 160 || frame.size.height < 90 ||
        !CGRectContainsRect(container.bounds, frame))
        return NO;
    [self restore];
    if (!self.surface.superview)
        return NO;
    self.originalParent = self.surface.superview;
    self.originalFrame = self.surface.frame;
    self.originalMask = self.surface.autoresizingMask;
    self.originalIndex = [self.surface.superview.subviews indexOfObject:self.surface];
#if SGPLATFORM_TARGET_OS_TV
    self.host = [[SGPresentationHost alloc] initWithFrame:frame];
#else
    self.host = [[SGPLFView alloc] initWithFrame:frame];
#endif
    self.mode = mode;
#if SGPLATFORM_TARGET_OS_MAC
    self.host.wantsLayer = YES;
    self.host.layer.backgroundColor = NSColor.blackColor.CGColor;
    self.host.autoresizingMask = mode == SGPlaybackPresentationModeFullScreen ? NSViewWidthSizable | NSViewHeightSizable
                                                                              : NSViewMinXMargin | NSViewMinYMargin;
    NSButton *close = [NSButton buttonWithTitle:@"Restore" target:self action:@selector(restore)];
    close.frame = NSMakeRect(0, frame.size.height - 28, 80, 28);
    close.autoresizingMask = NSViewMinYMargin;
    NSPanGestureRecognizer *drag = [[NSPanGestureRecognizer alloc] initWithTarget:self action:@selector(drag:)];
    if (mode == SGPlaybackPresentationModeFloating)
        [self.host addGestureRecognizer:drag];
    [container addSubview:self.host positioned:NSWindowAbove relativeTo:nil];
    [self.surface removeFromSuperview];
    self.surface.frame = NSMakeRect(0, 0, frame.size.width, frame.size.height - 28);
    self.surface.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
#else
    self.host.backgroundColor = UIColor.blackColor;
    self.host.autoresizingMask = mode == SGPlaybackPresentationModeFullScreen
                                     ? UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight
                                     : UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleTopMargin;
    CGFloat header = SGPLATFORM_TARGET_OS_TV ? 60 : 44;
    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    [close setTitle:@"Restore" forState:UIControlStateNormal];
    close.frame = CGRectMake(0, 0, SGPLATFORM_TARGET_OS_TV ? 160 : 100, header);
    [close addTarget:self action:@selector(restore) forControlEvents:UIControlEventPrimaryActionTriggered];
    close.titleLabel.font = [UIFont systemFontOfSize:SGPLATFORM_TARGET_OS_TV ? 24 : 17];
    UIPanGestureRecognizer *drag = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(drag:)];
    if (mode == SGPlaybackPresentationModeFloating)
        [self.host addGestureRecognizer:drag];
    [container addSubview:self.host];
    [self.surface removeFromSuperview];
    self.surface.frame = CGRectMake(0, header, frame.size.width, frame.size.height - header);
    self.surface.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
#endif
    close.accessibilityIdentifier = @"session.restore";
    close.accessibilityLabel = @"Restore playback surface";
    [self.host addSubview:self.surface];
    [self.host addSubview:close];
#if SGPLATFORM_TARGET_OS_TV
    ((SGPresentationHost *)self.host).preferredControl = close;
    // A floating surface can lie diagonally outside the remote's focus cone.
    // Bridge the header across its container so Up can always reach Restore.
    self.restoreGuide = [UIFocusGuide new];
    [container addLayoutGuide:self.restoreGuide];
    self.restoreGuide.preferredFocusEnvironments = @[ close ];
    [NSLayoutConstraint activateConstraints:@[
        [self.restoreGuide.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
        [self.restoreGuide.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],
        [self.restoreGuide.topAnchor constraintEqualToAnchor:self.host.topAnchor],
        [self.restoreGuide.heightAnchor constraintEqualToConstant:header]
    ]];
    SGPLFView *host = self.host;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (weakSelf.host != host)
            return;
        [host layoutIfNeeded];
        UIFocusSystem *focus = [UIFocusSystem focusSystemForEnvironment:host];
        [focus requestFocusUpdateToEnvironment:close];
        [focus updateFocusIfNeeded];
    });
#endif
    return YES;
}
- (BOOL)showFloatingInView:(SGPLFView *)container frame:(CGRect)frame {
#if SGPLATFORM_TARGET_OS_IPHONE_OR_TV
    CGRect safe = UIEdgeInsetsInsetRect(container.bounds, container.safeAreaInsets);
    frame.size.width = MIN(frame.size.width, safe.size.width);
    frame.size.height = MIN(frame.size.height, safe.size.height);
    frame.origin.x = MIN(MAX(CGRectGetMinX(safe), frame.origin.x), CGRectGetMaxX(safe) - frame.size.width);
    frame.origin.y = MIN(MAX(CGRectGetMinY(safe), frame.origin.y), CGRectGetMaxY(safe) - frame.size.height);
#endif
    return [self presentIn:container frame:frame mode:SGPlaybackPresentationModeFloating];
}
- (BOOL)showFullScreenInView:(SGPLFView *)container {
    CGRect bounds = container.bounds;
#if SGPLATFORM_TARGET_OS_IPHONE_OR_TV
    bounds = UIEdgeInsetsInsetRect(bounds, container.safeAreaInsets);
#endif
    return [self presentIn:container frame:bounds mode:SGPlaybackPresentationModeFullScreen];
}
#if SGPLATFORM_TARGET_OS_MAC
- (void)drag:(NSPanGestureRecognizer *)gesture {
    if (gesture.state == NSGestureRecognizerStateBegan)
        self.dragFrame = self.host.frame;
#else
- (void)drag:(UIPanGestureRecognizer *)gesture {
    if (gesture.state == UIGestureRecognizerStateBegan)
        self.dragFrame = self.host.frame;
#endif
    CGPoint translation = [gesture translationInView:self.host.superview];
    CGRect frame = self.dragFrame, bounds = self.host.superview.bounds;
#if SGPLATFORM_TARGET_OS_IPHONE_OR_TV
    bounds = UIEdgeInsetsInsetRect(bounds, self.host.superview.safeAreaInsets);
#endif
    frame.origin.x = MIN(MAX(CGRectGetMinX(bounds), frame.origin.x + translation.x),
                         MAX(CGRectGetMinX(bounds), CGRectGetMaxX(bounds) - frame.size.width));
    frame.origin.y = MIN(MAX(CGRectGetMinY(bounds), frame.origin.y + translation.y),
                         MAX(CGRectGetMinY(bounds), CGRectGetMaxY(bounds) - frame.size.height));
    self.host.frame = frame;
}
- (void)restore {
    if (!self.host)
        return;
#if SGPLATFORM_TARGET_OS_TV
    [self.restoreGuide.owningView removeLayoutGuide:self.restoreGuide];
    self.restoreGuide = nil;
#endif
    [self.surface removeFromSuperview];
    SGPLFView *parent = self.originalParent;
    if (parent) {
#if SGPLATFORM_TARGET_OS_MAC
        NSView *relative = self.originalIndex < parent.subviews.count ? parent.subviews[self.originalIndex] : nil;
        [parent addSubview:self.surface positioned:relative ? NSWindowBelow : NSWindowAbove relativeTo:relative];
#else
        [parent insertSubview:self.surface atIndex:MIN(self.originalIndex, parent.subviews.count)];
#endif
        self.surface.frame = self.originalFrame;
        self.surface.autoresizingMask = self.originalMask;
    }
    [self.host removeFromSuperview];
    self.host = nil;
    self.originalParent = nil;
    self.mode = SGPlaybackPresentationModeInline;
}
@end
