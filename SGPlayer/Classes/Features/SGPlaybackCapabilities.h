#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
/// Runtime capability inventory, not a performance guarantee. Query on the device that will play media.
@interface SGPlaybackCapabilities : NSObject
+ (NSDictionary<NSString *, id> *)snapshot;
@end
NS_ASSUME_NONNULL_END
