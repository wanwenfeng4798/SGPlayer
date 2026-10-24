#import "SGPLFTargets.h"
#import <AVFoundation/AVFoundation.h>
NS_ASSUME_NONNULL_BEGIN
/// Native background HLS downloads using willDownloadToURL (macOS 14 / iOS 18 and later).
/// Apple does not expose AVAssetDownloadURLSession on tvOS. No deprecated delegate fallback.
/// Main-thread API. Reuse the same background identifier and preferences after application relaunch.
@interface SGHLSAssetStore : NSObject
+ (BOOL)isSupported;
- (nullable instancetype)initWithBackgroundIdentifier:(NSString *)identifier metadataStore:(NSUserDefaults *)store;
@property(nonatomic, copy, nullable) void (^changed)
    (NSString *identifier, NSURL *_Nullable offlineURL, NSError *_Nullable error);
/// Connect this to the completion handler supplied by the host's background-session app delegate callback.
@property(nonatomic, copy, nullable) void (^backgroundEventsFinished)(void);
- (void)restoreTasksWithCompletion:(void (^)(void))completion;
/// Supply an AVURLAsset configured with the application's authorized cookies/resource-loading policy.
/// Keys/tokens are never copied to this store's metadata. DRM license acquisition remains the host's job.
- (BOOL)downloadAsset:(AVURLAsset *)asset
           identifier:(NSString *)identifier
                title:(NSString *)title
                error:(NSError **)error;
- (void)cancelIdentifier:(NSString *)identifier;
- (nullable NSURL *)offlineURLForIdentifier:(NSString *)identifier;
- (NSArray<NSDictionary<NSString *, id> *> *)downloads;
- (BOOL)removeIdentifier:(NSString *)identifier error:(NSError **)error;
/// Detach after finishing active tasks; does not remove downloaded assets.
- (void)close;
@end
NS_ASSUME_NONNULL_END
