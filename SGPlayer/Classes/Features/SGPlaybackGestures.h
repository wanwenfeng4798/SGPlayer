#import "SGPlaybackSession.h"
#if SGPLATFORM_TARGET_OS_IPHONE
NS_ASSUME_NONNULL_BEGIN
/// iPhone touch controls: double-tap play/pause, horizontal seek preview/commit,
/// right-side vertical player volume, left-side screen brightness. Main thread only.
/// Seeking is disabled on non-finite timelines. Locking cancels an active gesture.
@interface SGPlaybackGestures : NSObject
- (instancetype)initWithSession:(SGPlaybackSession *)session view:(UIView *)view;
@property(nonatomic) BOOL locked;
/// Whether an active pan still belongs to the current source.
@property(nonatomic, readonly) BOOL interacting;
@property(nonatomic, copy, nullable) void (^singleTap)(void);
@property(nonatomic, copy, nullable) void (^interaction)(void);
- (void)close; // detach gestures and conditionally restore brightness owned by this instance
@end
NS_ASSUME_NONNULL_END
#endif
