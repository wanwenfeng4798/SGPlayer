#import "SGPlaybackCover.h"
#import "SGPlaybackSession.h"
NS_ASSUME_NONNULL_BEGIN
#if SGPLATFORM_TARGET_OS_MAC
@interface SGPlaybackControls : NSView
#else
@interface SGPlaybackControls : UIView
#endif
@property(nonatomic) NSUInteger progressColorARGB;
@property(nonatomic) NSUInteger volumeColorARGB;
- (instancetype)initWithSession:(SGPlaybackSession *)session;
@property(nonatomic, strong, readonly) SGPlaybackSession *session;
@property(nonatomic) BOOL controlsLocked;
/// Disabling controls disables playback gestures/shortcuts; Escape can still dismiss a presentation.
@property(nonatomic) BOOL controlsEnabled;
@property(nonatomic) BOOL showsVolumeControl;
@property(nonatomic) BOOL showsSettingsControl;
@property(nonatomic) BOOL showsFullscreenControl;
@property(nonatomic) BOOL showsLockControl;
@property(nonatomic) BOOL keepLastFrameWhenComplete;
@property(nonatomic) BOOL coverEnabled;
@property(nonatomic, copy, nullable) void (^screenshotCaptured)(SGPLFImage *image);
/// Advanced debugging override. Hidden by default; normal playback selects automatically.
@property(nonatomic) BOOL showsKernelSelection;
/// Replace/detach the cover on the video surface; nil removes it.
- (void)setCoverImage:(nullable SGPLFImage *)image forView:(SGPLFView *)view;
/// WebVTT sprite preview; relative image URLs are resolved against the VTT file.
- (void)loadTimelineSpritesFromURL:(nullable NSURL *)URL completion:(void (^)(NSError * _Nullable error))completion;
- (void)timelineImageAtTime:(CMTime)time completion:(void (^)(SGPLFImage * _Nullable image, NSError * _Nullable error))completion;
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
