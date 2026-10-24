#import "SGPlaybackCover.h"
#import "SGPlaybackSession.h"
NS_ASSUME_NONNULL_BEGIN
#if SGPLATFORM_TARGET_OS_MAC
@interface SGPlaybackControls : NSView
#else
@interface SGPlaybackControls : UIView
#endif
- (instancetype)initWithSession:(SGPlaybackSession *)session;
@property(nonatomic, strong, readonly) SGPlaybackSession *session;
@property(nonatomic) BOOL controlsLocked;
/// Replace/detach the cover on the video surface; nil removes it.
- (void)setCoverImage:(nullable SGPLFImage *)image forView:(SGPLFView *)view;
// Hosts own window, orientation and presentation policy.
@property(nonatomic, copy, nullable) void (^toggleFullScreen)(void);
@property(nonatomic, copy, nullable) void (^toggleFloatingWindow)(void);
/// Restore an existing presentation; Escape never opens a new presentation.
@property(nonatomic, copy, nullable) void (^dismissPresentation)(void);
#if SGPLATFORM_TARGET_OS_MAC
/// Space, arrows, Shift-arrows, M, F, L, brackets and Escape; command/control/option are preserved.
- (BOOL)handleKeyEvent:(NSEvent *)event;
/// Scope shortcuts to this video surface/controls; text editors and other players keep their keys.
- (void)attachKeyboardToView:(nullable NSView *)view;
#endif
/// Relative seeks are clamped to a finite timeline; live non-seekable inputs return NO.
- (BOOL)seekBySeconds:(double)seconds;
/// Zero disables automatic hiding. Positive values hide idle controls during playback.
@property(nonatomic) NSTimeInterval autoHideInterval;
- (void)revealControls;
#if SGPLATFORM_TARGET_OS_TV
/// Bind a focusable remote receiver before enabling automatic hiding. Nil detaches.
- (void)attachRemoteToView:(nullable UIView *)view;
#endif
#if SGPLATFORM_TARGET_OS_IPHONE
/// Installs gestures on the separate video surface. Replacing it detaches the previous surface.
- (void)attachGesturesToView:(UIView *)view;
#endif
- (void)refresh;
@end
NS_ASSUME_NONNULL_END
