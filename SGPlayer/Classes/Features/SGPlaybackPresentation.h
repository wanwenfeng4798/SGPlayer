#import "SGPLFView.h"
NS_ASSUME_NONNULL_BEGIN
typedef NS_ENUM(NSInteger, SGPlaybackPresentationMode) {
    SGPlaybackPresentationModeInline,
    SGPlaybackPresentationModeFloating,
    SGPlaybackPresentationModeFullScreen,
};
/// Reparents the same rendering surface. Decoder, effects, playback time and PiP source stay attached.
/// FullScreen fills the supplied container; a host may additionally enter a system full-screen window.
@interface SGPlaybackPresentation : NSObject
- (instancetype)initWithSurface:(SGPLFView *)surface;
@property(nonatomic, readonly) SGPlaybackPresentationMode mode;
/// Optional host action for the restore button; direct restore never invokes it.
@property(nonatomic, copy, nullable) void (^dismissalRequested)(void);
- (BOOL)showFloatingInView:(SGPLFView *)container frame:(CGRect)frame;
- (BOOL)showFullScreenInView:(SGPLFView *)container;
- (void)restore;
@end
NS_ASSUME_NONNULL_END
