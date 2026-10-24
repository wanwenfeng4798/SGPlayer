#import <SGPlayer/SGPlayer.h>

typedef NS_ENUM(NSInteger, SGFeatureExportMode) { SGFeatureExportNone, SGFeatureExportVideo, SGFeatureExportAudio };

@interface SGFeatureDemo : NSObject
- (instancetype)initWithView:(SGPLFView *)view;
- (instancetype)initWithView:(SGPLFView *)view sessionControls:(BOOL)sessionControls;
- (instancetype)initWithView:(SGPLFView *)view sessionControls:(BOOL)sessionControls exportMode:(SGFeatureExportMode)exportMode;
@property (nonatomic, strong, readonly) SGPlaybackController *playback;
@property (nonatomic, copy, readonly) NSDictionary<NSString *, id> *buttons;
@property (nonatomic, readonly) BOOL busy;
@property (nonatomic, strong, readonly) NSError *lastActionError;
@property (nonatomic, strong, readonly) NSURL *exportedGIF;
@property (nonatomic, strong, readonly) NSURL *exportedVideo;
- (void)activateAction:(NSString *)identifier;
- (void)close;
@end
