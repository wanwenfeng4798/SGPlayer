#import "SGHLSAssetStore.h"
static NSError *SGHLSError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:@"SGHLSAssetStore" code:code userInfo:@{NSLocalizedDescriptionKey : message}];
}
#if SGPLATFORM_TARGET_OS_MAC_OR_IPHONE
@interface SGHLSAssetStore () <AVAssetDownloadDelegate>
@property(nonatomic, strong) AVAssetDownloadURLSession *session;
@property(nonatomic, strong) NSMutableDictionary<NSString *, AVAssetDownloadTask *> *tasks;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSDictionary *> *records;
@property(nonatomic, strong) NSUserDefaults *store;
@property(nonatomic, copy) NSString *metadataKey;
@property(nonatomic) BOOL closed;
- (void)recordLocation:(NSURL *)location forTask:(AVAssetDownloadTask *)task;
@end
@interface SGHLSDelegate : NSObject <AVAssetDownloadDelegate>
@property(nonatomic, weak) SGHLSAssetStore *owner;
@end
@implementation SGHLSDelegate
- (void)URLSession:(NSURLSession *)session
    assetDownloadTask:(AVAssetDownloadTask *)task
    willDownloadToURL:(NSURL *)location {
    [self.owner recordLocation:location forTask:task];
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    [self.owner URLSession:session task:task didCompleteWithError:error];
}
- (void)URLSessionDidFinishEventsForBackgroundURLSession:(NSURLSession *)session {
    [self.owner URLSessionDidFinishEventsForBackgroundURLSession:session];
}
@end
@implementation SGHLSAssetStore
+ (BOOL)isSupported {
    if (@available(macOS 14.0, iOS 18.0, *))
        return YES;
    return NO;
}
- (instancetype)initWithBackgroundIdentifier:(NSString *)identifier metadataStore:(NSUserDefaults *)store {
    NSAssert(NSThread.isMainThread, @"Main thread required");
    NSParameterAssert(identifier.length && store);
    if (!self.class.isSupported)
        return nil;
    if ((self = [super init])) {
        _store = store;
        _metadataKey = [@"SGPlayer.HLS.v1." stringByAppendingString:identifier];
        _tasks = [NSMutableDictionary dictionary];
        _records = [[store dictionaryForKey:_metadataKey] mutableCopy] ?: [NSMutableDictionary dictionary];
        NSURLSessionConfiguration *configuration =
            [NSURLSessionConfiguration backgroundSessionConfigurationWithIdentifier:identifier];
        configuration.discretionary = NO;
        SGHLSDelegate *delegate = [SGHLSDelegate new];
        delegate.owner = self;
        _session = [AVAssetDownloadURLSession sessionWithConfiguration:configuration
                                                 assetDownloadDelegate:delegate
                                                         delegateQueue:NSOperationQueue.mainQueue];
    }
    return self;
}
- (void)dealloc {
    [_session finishTasksAndInvalidate];
}
- (void)persist {
    [self.store setObject:[self.records copy] forKey:self.metadataKey];
}
- (void)restoreTasksWithCompletion:(void (^)(void))completion {
    [self.session getAllTasksWithCompletionHandler:^(NSArray<__kindof NSURLSessionTask *> *tasks) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!self.closed) {
                [self.tasks removeAllObjects];
                for (NSURLSessionTask *task in tasks)
                    if ([task isKindOfClass:AVAssetDownloadTask.class] && task.taskDescription.length)
                        self.tasks[task.taskDescription] = (AVAssetDownloadTask *)task;
                for (NSString *key in self.records.allKeys)
                    if ([self.records[key][@"state"] isEqual:@"downloading"] && !self.tasks[key]) {
                        NSMutableDictionary *record = [self.records[key] mutableCopy];
                        NSURL *local = [self localURLForRecord:record];
                        BOOL playable =
                            local && [AVURLAsset URLAssetWithURL:local options:nil].assetCache.isPlayableOffline;
                        if (playable) {
                            NSData *bookmark = [local bookmarkDataWithOptions:NSURLBookmarkCreationMinimalBookmark
                                               includingResourceValuesForKeys:nil
                                                                relativeToURL:nil
                                                                        error:nil];
                            if (bookmark) {
                                record[@"bookmark"] = bookmark;
                                [record removeObjectForKey:@"pendingLocation"];
                            } else
                                playable = NO;
                        }
                        record[@"state"] = playable ? @"complete" : @"interrupted";
                        self.records[key] = record;
                    }
                [self persist];
            }
            completion();
        });
    }];
}
- (BOOL)downloadAsset:(AVURLAsset *)asset
           identifier:(NSString *)identifier
                title:(NSString *)title
                error:(NSError **)error {
    NSAssert(NSThread.isMainThread, @"Main thread required");
    BOOL pending = [self.records[identifier][@"state"] isEqual:@"downloading"];
    if (self.closed || !identifier.length || !title.length ||
        ![@[ @"http", @"https" ] containsObject:asset.URL.scheme.lowercaseString] || self.tasks[identifier] ||
        pending || [self offlineURLForIdentifier:identifier]) {
        if (error)
            *error = SGHLSError(1, @"HLS download requires a unique ID, title, remote asset and an open store");
        return NO;
    }
    AVAssetDownloadConfiguration *configuration = [AVAssetDownloadConfiguration downloadConfigurationWithAsset:asset
                                                                                                         title:title];
    AVAssetDownloadTask *task = [self.session assetDownloadTaskWithConfiguration:configuration];
    if (!task) {
        if (error)
            *error = SGHLSError(2, @"The system could not create an asset download");
        return NO;
    }
    task.taskDescription = identifier;
    self.tasks[identifier] = task;
    self.records[identifier] = @{@"identifier" : identifier, @"state" : @"downloading"};
    [self persist];
    [task resume];
    return YES;
}
- (void)cancelIdentifier:(NSString *)identifier {
    [self.tasks[identifier] cancel];
}
- (NSURL *)offlineURLForIdentifier:(NSString *)identifier {
    NSDictionary *record = self.records[identifier];
    if (![record[@"state"] isEqual:@"complete"])
        return nil;
    return [self localURLForRecord:record];
}
- (NSURL *)localURLForRecord:(NSDictionary *)record {
    NSData *bookmark = record[@"bookmark"];
    NSURL *URL = nil;
    if ([bookmark isKindOfClass:NSData.class]) {
        BOOL stale = NO;
        URL = [NSURL URLByResolvingBookmarkData:bookmark
                                        options:NSURLBookmarkResolutionWithoutUI
                                  relativeToURL:nil
                            bookmarkDataIsStale:&stale
                                          error:nil];
    } else if ([record[@"pendingLocation"] isKindOfClass:NSString.class])
        URL = [NSURL URLWithString:record[@"pendingLocation"]];
    if (!URL.isFileURL || ![NSFileManager.defaultManager fileExistsAtPath:URL.path])
        return nil;
    return URL;
}
- (NSArray<NSDictionary<NSString *, id> *> *)downloads {
    NSMutableArray *result = [NSMutableArray array];
    for (NSString *key in [self.records.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        NSMutableDictionary *record = [self.records[key] mutableCopy];
        AVAssetDownloadTask *task = self.tasks[key];
        double fraction = task.progress.fractionCompleted;
        if (task && isfinite(fraction))
            record[@"progress"] = @(MIN(1, MAX(0, fraction)));
        [record removeObjectForKey:@"bookmark"];
        [record removeObjectForKey:@"pendingLocation"];
        [result addObject:record];
    }
    return result;
}
- (BOOL)removeIdentifier:(NSString *)identifier error:(NSError **)error {
    if (self.tasks[identifier]) {
        if (error)
            *error = SGHLSError(3, @"Cancel the active asset task before deleting it");
        return NO;
    }
    NSURL *URL = [self localURLForRecord:self.records[identifier]];
    if (URL && ![NSFileManager.defaultManager removeItemAtURL:URL error:error])
        return NO;
    [self.records removeObjectForKey:identifier];
    [self persist];
    return YES;
}
- (void)recordLocation:(NSURL *)location forTask:(AVAssetDownloadTask *)task {
    NSString *identifier = task.taskDescription;
    if (!identifier.length)
        return;
    if (!location.isFileURL) {
        [task cancel];
        NSMutableDictionary *record = [self.records[identifier] mutableCopy] ?: [NSMutableDictionary dictionary];
        record[@"state"] = @"failed";
        record[@"errorCode"] = @4;
        self.records[identifier] = record;
        [self persist];
        return;
    }
    NSMutableDictionary *record = [self.records[identifier] mutableCopy] ?: [NSMutableDictionary dictionary];
    // Preserve the system-provided URL, including protected .nofollow mounts. Do not rewrite its path.
    record[@"pendingLocation"] = location.absoluteString;
    record[@"state"] = @"downloading";
    self.records[identifier] = record;
    [self persist];
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    NSString *identifier = task.taskDescription;
    if (!identifier.length)
        return;
    [self.tasks removeObjectForKey:identifier];
    NSMutableDictionary *record = [self.records[identifier] mutableCopy] ?: [NSMutableDictionary dictionary];
    record[@"identifier"] = identifier;
    NSError *failure = error;
    if (!failure && ![self localURLForRecord:record])
        failure = SGHLSError(5, @"Asset download did not produce a local package");
    if (!failure) {
        NSURL *local = [self localURLForRecord:record];
        NSData *bookmark = [local bookmarkDataWithOptions:NSURLBookmarkCreationMinimalBookmark
                           includingResourceValuesForKeys:nil
                                            relativeToURL:nil
                                                    error:&failure];
        if (bookmark) {
            record[@"bookmark"] = bookmark;
            [record removeObjectForKey:@"pendingLocation"];
        }
    }
    record[@"state"] = failure ? (failure.code == NSURLErrorCancelled ? @"cancelled" : @"failed") : @"complete";
    if (failure)
        record[@"errorCode"] = @(failure.code);
    else
        [record removeObjectForKey:@"errorCode"];
    self.records[identifier] = record;
    [self persist];
    if (self.changed)
        self.changed(identifier, [self offlineURLForIdentifier:identifier], failure);
}
- (void)URLSessionDidFinishEventsForBackgroundURLSession:(NSURLSession *)session {
    void (^done)(void) = self.backgroundEventsFinished;
    self.backgroundEventsFinished = nil;
    if (done)
        done();
}
- (void)close {
    self.closed = YES;
    [self.session finishTasksAndInvalidate];
}
@end
#else
@implementation SGHLSAssetStore
+ (BOOL)isSupported {
    return NO;
}
- (instancetype)initWithBackgroundIdentifier:(NSString *)identifier metadataStore:(NSUserDefaults *)store {
    return nil;
}
- (void)restoreTasksWithCompletion:(void (^)(void))completion {
    dispatch_async(dispatch_get_main_queue(), completion);
}
- (BOOL)downloadAsset:(AVURLAsset *)asset
           identifier:(NSString *)identifier
                title:(NSString *)title
                error:(NSError **)error {
    if (error)
        *error = SGHLSError(6, @"Apple's offline HLS asset download session is unavailable on tvOS");
    return NO;
}
- (void)cancelIdentifier:(NSString *)identifier {
}
- (NSURL *)offlineURLForIdentifier:(NSString *)identifier {
    return nil;
}
- (NSArray *)downloads {
    return @[];
}
- (BOOL)removeIdentifier:(NSString *)identifier error:(NSError **)error {
    if (error)
        *error = SGHLSError(6, @"Offline HLS asset downloads are unavailable on this platform");
    return NO;
}
- (void)close {
}
@end
#endif
