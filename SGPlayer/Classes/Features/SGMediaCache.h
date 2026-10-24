#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
/// Complete progressive HTTP(S) downloads, shared by either kernel. HLS requires an asset-download provider.
/// Methods are thread safe; progress/completion run on the main queue. Files remain until quota eviction.
@interface SGMediaCache : NSObject
- (nullable instancetype)initWithDirectory:(NSURL *)directory
                              maximumBytes:(unsigned long long)maximumBytes
                                     error:(NSError **)error;
@property(nonatomic, copy, readonly) NSURL *directory;
@property(nonatomic, readonly) unsigned long long maximumBytes;
@property(nonatomic, readonly) unsigned long long cachedBytes;
- (nullable NSURL *)cachedURLForRequest:(NSURLRequest *)request;
/// expectedSHA256 is optional (64 hex characters). HTTP errors, partial responses and manifests fail.
/// A duplicate active request fails explicitly; callers may share its result at the session layer.
/// At most three downloads run concurrently. Supply Cookie/Authorization explicitly in request headers.
- (nullable NSUUID *)downloadRequest:(NSURLRequest *)request
                      expectedSHA256:(nullable NSString *)SHA256
                            progress:(nullable void (^)(int64_t received, int64_t expected))progress
                          completion:(void (^)(NSURL *_Nullable localURL, NSError *_Nullable error))completion;
- (void)cancelDownload:(NSUUID *)identifier;
/// Pin before handing a cached file to a player; unpin when the item is released.
- (BOOL)pinRequest:(NSURLRequest *)request;
- (void)unpinRequest:(NSURLRequest *)request;
- (void)removeAllUnpinned;
- (void)close;
@end
NS_ASSUME_NONNULL_END
