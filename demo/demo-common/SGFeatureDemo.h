#import <SGPlayer/SGPlayer.h>

@interface SGFeatureDemo : NSObject
- (instancetype)initWithView:(SGPLFView *)view;
@property (nonatomic, strong, readonly) SGPlaybackController *playback;
@property (nonatomic, copy, readonly) NSDictionary<NSString *, id> *buttons;
@property (nonatomic, readonly) BOOL busy;
@property (nonatomic, strong, readonly) NSError *lastActionError;
@property (nonatomic, strong, readonly) NSURL *exportedGIF;
- (void)activateAction:(NSString *)identifier;
- (void)close;
@end
