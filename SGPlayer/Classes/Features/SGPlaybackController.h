#import <Foundation/Foundation.h>
#import "SGMediaEffects.h"
#import "SGNativePlaybackPolicy.h"
#import "SGPLFView.h"
#import "SGPLFImage.h"
#import <AVKit/AVKit.h>

NS_ASSUME_NONNULL_BEGIN
@class SGPlayer;
// Main-thread controller with explicit backend selection and common effects/PiP.
@interface SGPlaybackController : NSObject
- (instancetype)initWithKernel:(SGPlaybackKernel)kernel view:(SGPLFView *)view;
@property (nonatomic, readonly) SGPlaybackKernel kernel;
@property (nonatomic, strong, readonly) SGMediaEffects *effects;
@property (nonatomic, strong, readonly, nullable) SGPlayer *ffmpegPlayer;
@property (nonatomic, strong, readonly, nullable) AVPlayer *nativePlayer;
@property (nonatomic) float rate;
/// Snapshot of the accepted native policy, retained across sources and kernel switches.
@property (nonatomic, copy, readonly) SGNativePlaybackPolicy *nativePlaybackPolicy;
- (BOOL)applyNativePlaybackPolicy:(SGNativePlaybackPolicy *)policy error:(NSError * _Nullable * _Nullable)error;
/// Real counters from the most recent AVPlayer access-log event; empty without a native log.
/// Bitrates are bits/second; transferred bytes and downloaded media seconds refer to that event.
@property (nonatomic, copy, readonly) NSDictionary<NSString *, NSNumber *> *nativePlaybackMetrics;
@property (nonatomic, copy) AVLayerVideoGravity videoGravity; // aspect fit / aspect fill / stretch, shared by both kernels
@property (nonatomic) float volume; // 0...1, applies to both backends
@property (nonatomic) NSTimeInterval sourceLoadingTimeout; // 20 seconds; finite, 1...120
@property (nonatomic, readonly) BOOL playing;
@property (nonatomic, readonly) CMTime currentTime;
@property (nonatomic, readonly) CMTime duration;
@property (nonatomic, readonly, nullable) NSError *error;
@property (nonatomic, readonly) NSUInteger presentedFrameCount;
@property (nonatomic, readonly) NSUInteger backgroundFrameCount;
/// iOS uses AVKit PiP; macOS uses a native nonactivating floating panel.
@property (nonatomic, readonly) BOOL pictureInPictureActive;
/// Composite view to move on macOS (include controls/transforms); nil uses the rendering view.
@property (nonatomic, weak, nullable) SGPLFView *pictureInPictureView;
/// Opt-in primary-player automatic PiP on app background/minimization.
@property (nonatomic) BOOL automaticPictureInPictureEnabled;
@property (nonatomic, strong, readonly) AVPictureInPictureController *pictureInPictureController;
@property (nonatomic, copy, nullable) void (^pictureInPictureChanged)(BOOL active, NSError * _Nullable error);
@property (nonatomic, copy, nullable) void (^restoreInterface)(void (^completion)(BOOL restored));
@property (nonatomic, copy, readonly) NSArray<SGSubtitleTrack *> *subtitleTracks;
@property (nonatomic, readonly) NSInteger selectedSubtitleTrack;
@property (nonatomic, readonly) NSInteger selectedSecondarySubtitleTrack;
- (void)replaceWithURL:(NSURL *)URL;
// Waits for readiness, clamps a saved position to the known duration and performs an accurate seek.
// Completion is on the main thread; superseded requests complete with NO.
- (void)replaceWithURL:(NSURL *)URL atTime:(CMTime)time completion:(void (^)(BOOL success))completion;
- (void)replaceWithURL:(NSURL *)URL atTime:(CMTime)time preservingSubtitles:(BOOL)preserve completion:(void (^)(BOOL success))completion;
// Tears down the backend and clears its source while preserving play intent and effects.
- (void)resetToKernel:(SGPlaybackKernel)kernel;
- (void)play;
- (void)pause;
- (void)seekToTime:(CMTime)time completion:(void (^)(BOOL success))completion;
- (void)switchToKernel:(SGPlaybackKernel)kernel completion:(void (^)(BOOL success))completion;
- (void)loadDanmakuFromURL:(NSURL *)URL completion:(void (^)(NSError * _Nullable error))completion;
- (void)loadSubtitlesFromURL:(NSURL *)URL completion:(void (^)(NSError * _Nullable error))completion;
- (BOOL)selectSubtitleTrack:(NSInteger)index; // -1 disables subtitles
- (BOOL)selectSecondarySubtitleTrack:(NSInteger)index; // -1 disables the second track
@property (nonatomic, copy, readonly) NSArray<NSString *> *audioTrackTitles;
@property (nonatomic, readonly) NSInteger selectedAudioTrack;
- (BOOL)selectAudioTrackAtIndex:(NSInteger)index;
- (BOOL)startPictureInPicture:(NSError **)error;
- (void)stopPictureInPicture;
- (nullable SGPLFImage *)currentImage;
- (void)close;
@end
NS_ASSUME_NONNULL_END
