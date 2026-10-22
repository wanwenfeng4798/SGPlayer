#import "SGPlayer.h"
#import "SGMediaEffects.h"
#import "SGPLFView.h"
#import "SGPLFImage.h"
#import <AVKit/AVKit.h>

NS_ASSUME_NONNULL_BEGIN
// Main-thread controller with explicit backend selection and common effects/PiP.
@interface SGPlaybackController : NSObject
- (instancetype)initWithKernel:(SGPlaybackKernel)kernel view:(SGPLFView *)view;
@property (nonatomic, readonly) SGPlaybackKernel kernel;
@property (nonatomic, strong, readonly) SGMediaEffects *effects;
@property (nonatomic, strong, readonly, nullable) SGPlayer *ffmpegPlayer;
@property (nonatomic, strong, readonly, nullable) AVPlayer *nativePlayer;
@property (nonatomic) float rate;
@property (nonatomic, readonly) BOOL playing;
@property (nonatomic, readonly) CMTime currentTime;
@property (nonatomic, readonly) CMTime duration;
@property (nonatomic, readonly, nullable) NSError *error;
@property (nonatomic, readonly) NSUInteger presentedFrameCount;
@property (nonatomic, readonly) NSUInteger backgroundFrameCount;
@property (nonatomic, readonly) BOOL pictureInPictureActive;
@property (nonatomic, strong, readonly) AVPictureInPictureController *pictureInPictureController;
@property (nonatomic, copy, nullable) void (^pictureInPictureChanged)(BOOL active, NSError * _Nullable error);
@property (nonatomic, copy, nullable) void (^restoreInterface)(void (^completion)(BOOL restored));
@property (nonatomic, copy, readonly) NSArray<SGSubtitleTrack *> *subtitleTracks;
@property (nonatomic, readonly) NSInteger selectedSubtitleTrack;
- (void)replaceWithURL:(NSURL *)URL;
- (void)play;
- (void)pause;
- (void)seekToTime:(CMTime)time completion:(void (^)(BOOL success))completion;
- (void)switchToKernel:(SGPlaybackKernel)kernel completion:(void (^)(BOOL success))completion;
- (void)loadSubtitlesFromURL:(NSURL *)URL completion:(void (^)(NSError * _Nullable error))completion;
- (BOOL)selectSubtitleTrack:(NSInteger)index; // -1 disables subtitles
- (BOOL)startPictureInPicture:(NSError **)error;
- (void)stopPictureInPicture;
- (nullable SGPLFImage *)currentImage;
- (void)close;
@end
NS_ASSUME_NONNULL_END
