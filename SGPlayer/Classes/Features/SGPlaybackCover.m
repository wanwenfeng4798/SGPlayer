#import "SGPlaybackCover.h"
@interface SGPlaybackCover ()
@property(nonatomic, weak) SGPlaybackSession *session;
@property(nonatomic, weak) SGPLFView *surface;
@property(nonatomic, copy) NSString *originalAccessibilityLabel;
#if SGPLATFORM_TARGET_OS_MAC
@property(nonatomic, strong) NSImageView *imageView;
#else
@property(nonatomic, strong) UIImageView *imageView;
#endif
@property(nonatomic, strong) NSTimer *timer;
@end
@implementation SGPlaybackCover
- (instancetype)initWithSession:(SGPlaybackSession *)session view:(SGPLFView *)view image:(SGPLFImage *)image {
    NSParameterAssert(session);
    NSParameterAssert(view);
    NSAssert(NSThread.isMainThread, @"Main thread required");
    if ((self = [super init])) {
        _session = session;
        _surface = view;
        _originalAccessibilityLabel = [view.accessibilityLabel copy];
#if SGPLATFORM_TARGET_OS_MAC
        _imageView = [[NSImageView alloc] initWithFrame:view.bounds];
        _imageView.imageScaling = NSImageScaleProportionallyUpOrDown;
        _imageView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        _imageView.accessibilityElement = YES;
        _imageView.accessibilityLabel = @"Video cover";
        _imageView.wantsLayer = YES;
        _imageView.layer.backgroundColor = NSColor.blackColor.CGColor;
#else
        _imageView = [[UIImageView alloc] initWithFrame:view.bounds];
        _imageView.contentMode = UIViewContentModeScaleAspectFit;
        _imageView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _imageView.userInteractionEnabled = NO;
        _imageView.isAccessibilityElement = YES;
        _imageView.accessibilityLabel = @"Video cover";
        _imageView.backgroundColor = UIColor.blackColor;
#endif
        _imageView.accessibilityIdentifier = @"session.cover";
        [view addSubview:_imageView];
        self.image = image;
        __weak typeof(self) weakSelf = self;
        _timer = [NSTimer timerWithTimeInterval:.1
                                        repeats:YES
                                          block:^(NSTimer *timer) {
                                              [weakSelf refresh];
                                          }];
        [NSRunLoop.mainRunLoop addTimer:_timer forMode:NSRunLoopCommonModes];
        [self refresh];
    }
    return self;
}
- (void)dealloc {
    [_timer invalidate];
    if ([_surface.accessibilityLabel isEqual:@"Video cover"])
        _surface.accessibilityLabel = _originalAccessibilityLabel;
    [_imageView removeFromSuperview];
}
- (void)setImage:(SGPLFImage *)image {
    _image = image;
    self.imageView.image = image;
}
- (BOOL)visible {
    return self.imageView && !self.imageView.hidden && self.imageView.superview != nil;
}
- (void)refresh {
    NSAssert(NSThread.isMainThread, @"Main thread required");
    SGPlaybackSession *session = self.session;
    if (!session) {
        [self close];
        return;
    }
    BOOL waiting = session.state == SGPlaybackSessionStateIdle || session.state == SGPlaybackSessionStateLoading ||
                   session.state == SGPlaybackSessionStateFailed || session.controller.presentedFrameCount == 0;
    BOOL show = session.state == SGPlaybackSessionStateEnded ? !self.keepLastFrameWhenComplete : (self.image != nil && waiting);
    self.imageView.hidden = !show;
    if (show)
        self.surface.accessibilityLabel = @"Video cover";
    else if ([self.surface.accessibilityLabel isEqual:@"Video cover"])
        self.surface.accessibilityLabel = self.originalAccessibilityLabel;
}
- (void)close {
    if ([self.surface.accessibilityLabel isEqual:@"Video cover"])
        self.surface.accessibilityLabel = self.originalAccessibilityLabel;
    self.surface = nil;
    [_timer invalidate];
    _timer = nil;
    [_imageView removeFromSuperview];
    _imageView = nil;
    _session = nil;
}
@end
