#import "SGPLFImage.h"
#import "SGPlaybackSession.h"
NS_ASSUME_NONNULL_BEGIN
/// Presentation cover, shown before the first presented frame and on idle/loading/failure.
/// It follows the video surface's bounds. Main thread only; call close when finished.
@interface SGPlaybackCover : NSObject
- (instancetype)initWithSession:(SGPlaybackSession *)session view:(SGPLFView *)view image:(nullable SGPLFImage *)image;
@property(nonatomic, strong, nullable) SGPLFImage *image;
@property(nonatomic) BOOL keepLastFrameWhenComplete;
@property(nonatomic, readonly) BOOL visible;
- (void)refresh;
- (void)close;
@end
NS_ASSUME_NONNULL_END
