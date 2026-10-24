#import "SGMediaCache.h"
#import <CommonCrypto/CommonDigest.h>

static NSString *SGCacheDigest(NSData *data) {
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *result = [NSMutableString string];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++)
        [result appendFormat:@"%02x", digest[i]];
    return result;
}
static NSString *SGCacheKey(NSURLRequest *request) {
    // Headers participate in identity to prevent cross-account reuse. No raw URL/header is written to disk.
    NSMutableArray *parts =
        [NSMutableArray arrayWithObjects:request.URL.absoluteString ?: @"", request.HTTPMethod ?: @"GET", nil];
    for (NSString *key in
         [request.allHTTPHeaderFields.allKeys sortedArrayUsingSelector:@selector(caseInsensitiveCompare:)])
        [parts addObject:[NSString stringWithFormat:@"%@:%@", key.lowercaseString, request.allHTTPHeaderFields[key]]];
    NSData *data = [NSJSONSerialization dataWithJSONObject:parts options:0 error:nil];
    return SGCacheDigest(data);
}
static NSError *SGCacheError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:@"SGMediaCache" code:code userInfo:@{NSLocalizedDescriptionKey : message}];
}
static NSString *SGCacheFileKey(NSURL *URL) {
    return [URL.lastPathComponent componentsSeparatedByString:@".sgcache."].firstObject;
}
@interface SGCacheDownload : NSObject
@property(nonatomic, strong) NSUUID *identifier;
@property(nonatomic, strong) NSURLSessionDownloadTask *task;
@property(nonatomic, copy) NSString *key;
@property(nonatomic, copy) NSString *SHA256;
@property(nonatomic, copy) void (^progress)(int64_t, int64_t);
@property(nonatomic, copy) void (^completion)(NSURL *, NSError *);
@property(nonatomic, strong) NSError *failure;
@property(nonatomic, strong) NSURL *result;
@end
@implementation SGCacheDownload
@end

@class SGCacheDelegate;
@interface SGMediaCache () <NSURLSessionDownloadDelegate>
@property(nonatomic, copy, readwrite) NSURL *directory;
@property(nonatomic, readwrite) unsigned long long maximumBytes;
@property(nonatomic, strong) NSURLSession *session;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, SGCacheDownload *> *downloads;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *pins;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSURL *> *entries;
@property(nonatomic) BOOL closed;
@end
/// URLSession retains its delegate; the proxy prevents a cache/session retain cycle.
@interface SGCacheDelegate : NSObject <NSURLSessionDownloadDelegate>
@property(nonatomic, weak) SGMediaCache *owner;
@end
@implementation SGCacheDelegate
- (void)URLSession:(NSURLSession *)session
                 downloadTask:(NSURLSessionDownloadTask *)task
                 didWriteData:(int64_t)bytes
            totalBytesWritten:(int64_t)total
    totalBytesExpectedToWrite:(int64_t)expected {
    [self.owner URLSession:session
                     downloadTask:task
                     didWriteData:bytes
                totalBytesWritten:total
        totalBytesExpectedToWrite:expected];
}
- (void)URLSession:(NSURLSession *)session
                 downloadTask:(NSURLSessionDownloadTask *)task
    didFinishDownloadingToURL:(NSURL *)location {
    [self.owner URLSession:session downloadTask:task didFinishDownloadingToURL:location];
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    [self.owner URLSession:session task:task didCompleteWithError:error];
}
@end

@implementation SGMediaCache
- (instancetype)initWithDirectory:(NSURL *)directory
                     maximumBytes:(unsigned long long)maximumBytes
                            error:(NSError **)error {
    if (!directory.isFileURL || !maximumBytes) {
        if (error)
            *error = SGCacheError(1, @"A file directory and positive quota are required");
        return nil;
    }
    if (![NSFileManager.defaultManager createDirectoryAtURL:directory
                                withIntermediateDirectories:YES
                                                 attributes:nil
                                                      error:error])
        return nil;
    if ((self = [super init])) {
        _directory = [directory copy];
        _maximumBytes = maximumBytes;
        _downloads = [NSMutableDictionary dictionary];
        _pins = [NSMutableDictionary dictionary];
        _entries = [NSMutableDictionary dictionary];
        for (NSURL *URL in [self mediaFiles])
            self.entries[SGCacheFileKey(URL)] = URL;
        NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.ephemeralSessionConfiguration;
        configuration.URLCache = nil;
        configuration.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
        configuration.HTTPShouldSetCookies = NO;
        configuration.URLCredentialStorage = nil;
        configuration.timeoutIntervalForRequest = 20;
        configuration.timeoutIntervalForResource = 3600;
        SGCacheDelegate *delegate = [SGCacheDelegate new];
        delegate.owner = self;
        NSOperationQueue *queue = [NSOperationQueue new];
        queue.maxConcurrentOperationCount = 1;
        _session = [NSURLSession sessionWithConfiguration:configuration delegate:delegate delegateQueue:queue];
        [self trimForIncomingBytes:0];
    }
    return self;
}
- (void)dealloc {
    [_session invalidateAndCancel];
}
- (NSArray<NSURL *> *)mediaFiles {
    NSArray *files =
        [NSFileManager.defaultManager contentsOfDirectoryAtURL:self.directory
                                    includingPropertiesForKeys:@[ NSURLFileSizeKey, NSURLContentModificationDateKey ]
                                                       options:NSDirectoryEnumerationSkipsHiddenFiles
                                                         error:nil];
    return
        [files filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSURL *URL, NSDictionary *bindings) {
                   return [URL.lastPathComponent rangeOfString:@".sgcache."].location == 64;
               }]];
}
- (unsigned long long)sizeOfURL:(NSURL *)URL {
    NSNumber *size = nil;
    [URL getResourceValue:&size forKey:NSURLFileSizeKey error:nil];
    return size.unsignedLongLongValue;
}
- (unsigned long long)cachedBytes {
    @synchronized(self) {
        unsigned long long total = 0;
        for (NSURL *URL in [self mediaFiles])
            total += [self sizeOfURL:URL];
        return total;
    }
}
- (NSURL *)URLForKey:(NSString *)key response:(NSURLResponse *)response request:(NSURLRequest *)request {
    NSDictionary *types = @{
        @"video/mp4" : @"mp4",
        @"audio/mp4" : @"m4a",
        @"video/quicktime" : @"mov",
        @"audio/mpeg" : @"mp3",
        @"video/x-matroska" : @"mkv",
        @"video/mp2t" : @"ts",
        @"image/gif" : @"gif",
        @"video/webm" : @"webm",
        @"audio/aac" : @"aac",
        @"audio/wav" : @"wav"
    };
    NSString *extension = types[response.MIMEType.lowercaseString ?: @""] ?: request.URL.pathExtension.lowercaseString;
    NSSet *allowed = [NSSet setWithArray:@[
        @"mp4", @"m4v", @"mov", @"m4a", @"mp3", @"aac",  @"wav", @"aiff", @"caf",  @"mkv",  @"avi",
        @"flv", @"ts",  @"asf", @"nut", @"gif", @"webm", @"ogg", @"opus", @"flac", @"mpeg", @"mpg"
    ]];
    if (![allowed containsObject:extension ?: @""])
        extension = @"bin";
    return [self.directory URLByAppendingPathComponent:[NSString stringWithFormat:@"%@.sgcache.%@", key, extension]];
}
- (NSURL *)cachedURLForRequest:(NSURLRequest *)request {
    @synchronized(self) {
        if (self.closed)
            return nil;
        NSString *key = SGCacheKey(request);
        NSURL *URL = self.entries[key];
        if (!URL || ![NSFileManager.defaultManager fileExistsAtPath:URL.path]) {
            [self.entries removeObjectForKey:key];
            return nil;
        }
        [NSFileManager.defaultManager setAttributes:@{NSFileModificationDate : NSDate.date}
                                       ofItemAtPath:URL.path
                                              error:nil];
        return URL;
    }
}
- (BOOL)trimForIncomingBytes:(unsigned long long)incoming {
    if (incoming > self.maximumBytes)
        return NO;
    unsigned long long total = self.cachedBytes;
    NSArray *files = [[self mediaFiles] sortedArrayUsingComparator:^NSComparisonResult(NSURL *a, NSURL *b) {
        NSDate *ad = nil, *bd = nil;
        [a getResourceValue:&ad forKey:NSURLContentModificationDateKey error:nil];
        [b getResourceValue:&bd forKey:NSURLContentModificationDateKey error:nil];
        return [ad ?: NSDate.distantPast compare:bd ?: NSDate.distantPast];
    }];
    for (NSURL *URL in files) {
        if (total <= self.maximumBytes - incoming)
            break;
        if (self.pins[SGCacheFileKey(URL)].unsignedIntegerValue)
            continue;
        unsigned long long size = [self sizeOfURL:URL];
        if ([NSFileManager.defaultManager removeItemAtURL:URL error:nil]) {
            total -= MIN(total, size);
            [self.entries removeObjectForKey:SGCacheFileKey(URL)];
        }
    }
    return total <= self.maximumBytes - incoming;
}
- (NSUUID *)downloadRequest:(NSURLRequest *)request
             expectedSHA256:(NSString *)SHA256
                   progress:(void (^)(int64_t, int64_t))progress
                 completion:(void (^)(NSURL *, NSError *))completion {
    @synchronized(self) {
        NSString *scheme = request.URL.scheme.lowercaseString, *extension = request.URL.pathExtension.lowercaseString;
        BOOL hashValid =
            !SHA256 ||
            (SHA256.length == 64 &&
             [SHA256
                 rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdefABCDEF"]
                                             invertedSet]]
                     .location == NSNotFound);
        NSError *failure = nil;
        NSString *key = SGCacheKey(request);
        if (self.closed || !hashValid || ![@[ @"http", @"https" ] containsObject:scheme] ||
            (request.HTTPMethod && ![request.HTTPMethod isEqual:@"GET"]) || request.HTTPBody.length ||
            request.HTTPBodyStream || [request valueForHTTPHeaderField:@"Range"])
            failure = SGCacheError(2, @"Cache accepts complete HTTP(S) GET requests and optional SHA-256");
        if ([@[ @"m3u8", @"m3u", @"mpd" ] containsObject:extension])
            failure = SGCacheError(3, @"Adaptive manifests require an asset-download provider");
        for (SGCacheDownload *download in self.downloads.allValues)
            if ([download.key isEqual:key])
                failure = SGCacheError(4, @"This request already has an active download");
        if (self.downloads.count >= 3)
            failure = SGCacheError(11, @"At most three complete-file downloads may run concurrently");
        if (failure) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(nil, failure);
            });
            return nil;
        }
        NSURL *cached = [self cachedURLForRequest:request];
        // An explicitly supplied checksum is checked on the downloaded bytes; do not bypass it on cache hits.
        if (cached && !SHA256) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(cached, nil);
            });
            return nil;
        }
        SGCacheDownload *download = [SGCacheDownload new];
        download.identifier = NSUUID.UUID;
        download.key = key;
        download.SHA256 = SHA256.lowercaseString;
        download.progress = progress;
        download.completion = completion;
        NSMutableURLRequest *copy = [request mutableCopy];
        [copy setValue:@"identity" forHTTPHeaderField:@"Accept-Encoding"];
        download.task = [self.session downloadTaskWithRequest:copy];
        self.downloads[@(download.task.taskIdentifier)] = download;
        [download.task resume];
        return download.identifier;
    }
}
- (void)URLSession:(NSURLSession *)session
                 downloadTask:(NSURLSessionDownloadTask *)task
                 didWriteData:(int64_t)bytes
            totalBytesWritten:(int64_t)total
    totalBytesExpectedToWrite:(int64_t)expected {
    @synchronized(self) {
        SGCacheDownload *download = self.downloads[@(task.taskIdentifier)];
        if (total < 0 || (unsigned long long)total > self.maximumBytes ||
            (expected > 0 && (unsigned long long)expected > self.maximumBytes)) {
            download.failure = SGCacheError(5, @"Download exceeds cache quota");
            [task cancel];
            return;
        }
        void (^progress)(int64_t, int64_t) = download.progress;
        if (progress)
            dispatch_async(dispatch_get_main_queue(), ^{
                progress(total, expected);
            });
    }
}
- (void)URLSession:(NSURLSession *)session
                 downloadTask:(NSURLSessionDownloadTask *)task
    didFinishDownloadingToURL:(NSURL *)location {
    @synchronized(self) {
        SGCacheDownload *download = self.downloads[@(task.taskIdentifier)];
        if (!download || download.failure || self.closed)
            return;
        NSHTTPURLResponse *response = (NSHTTPURLResponse *)task.response;
        if (![response isKindOfClass:NSHTTPURLResponse.class] || response.statusCode != 200) {
            download.failure = SGCacheError(6, @"Server did not return a complete successful response");
            return;
        }
        NSString *mime = response.MIMEType.lowercaseString;
        if ([mime containsString:@"mpegurl"] || [mime containsString:@"dash+xml"]) {
            download.failure = SGCacheError(3, @"Adaptive manifests cannot be cached as a media file");
            return;
        }
        unsigned long long size = [self sizeOfURL:location];
        if (!size || size > self.maximumBytes ||
            (response.expectedContentLength >= 0 && size != (unsigned long long)response.expectedContentLength)) {
            download.failure = SGCacheError(7, @"Incomplete download or quota exceeded");
            return;
        }
        if (download.SHA256) {
            NSInputStream *input = [NSInputStream inputStreamWithURL:location];
            [input open];
            CC_SHA256_CTX context;
            CC_SHA256_Init(&context);
            uint8_t buffer[65536];
            NSInteger count;
            while ((count = [input read:buffer maxLength:sizeof(buffer)]) > 0)
                CC_SHA256_Update(&context, buffer, (CC_LONG)count);
            NSError *readError = input.streamError;
            [input close];
            unsigned char digest[CC_SHA256_DIGEST_LENGTH];
            CC_SHA256_Final(digest, &context);
            NSMutableString *actual = [NSMutableString string];
            for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++)
                [actual appendFormat:@"%02x", digest[i]];
            if (count < 0 || readError || ![actual isEqual:download.SHA256]) {
                download.failure = SGCacheError(8, @"Downloaded bytes do not match SHA-256");
                return;
            }
        }
        // Reject disguised manifests as well as the normal manifest MIME types.
        NSFileHandle *reader = [NSFileHandle fileHandleForReadingAtPath:location.path];
        NSData *prefix = [reader readDataOfLength:256];
        [reader closeFile];
        NSString *text = [[NSString alloc] initWithData:prefix encoding:NSUTF8StringEncoding];
        if ([text containsString:@"#EXTM3U"] || [text containsString:@"<MPD"]) {
            download.failure = SGCacheError(3, @"Manifest content requires an asset-download provider");
            return;
        }
        NSURL *destination =
            self.entries[download.key] ?: [self URLForKey:download.key response:response request:task.originalRequest];
        if (self.pins[download.key].unsignedIntegerValue) {
            download.failure = SGCacheError(9, @"Cannot replace a pinned cache entry");
            return;
        }
        if ([NSFileManager.defaultManager fileExistsAtPath:destination.path]) {
            // Preserve a valid existing entry until the new download has passed all checks.
            unsigned long long oldSize = [self sizeOfURL:destination];
            self.pins[download.key] = @1;
            BOOL fits = [self trimForIncomingBytes:size > oldSize ? size - oldSize : 0];
            [self.pins removeObjectForKey:download.key];
            if (!fits) {
                download.failure = SGCacheError(5, @"Pinned cache entries prevent quota eviction");
                return;
            }
            NSError *replaceError = nil;
            if (![NSFileManager.defaultManager replaceItemAtURL:destination
                                                  withItemAtURL:location
                                                 backupItemName:nil
                                                        options:0
                                               resultingItemURL:nil
                                                          error:&replaceError]) {
                download.failure = replaceError;
                return;
            }
        } else {
            if (![self trimForIncomingBytes:size]) {
                download.failure = SGCacheError(5, @"Pinned cache entries prevent quota eviction");
                return;
            }
            NSError *moveError = nil;
            if (![NSFileManager.defaultManager moveItemAtURL:location toURL:destination error:&moveError]) {
                download.failure = moveError;
                return;
            }
        }
        self.entries[download.key] = destination;
        [self trimForIncomingBytes:0];
        download.result = destination;
    }
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    SGCacheDownload *download;
    @synchronized(self) {
        download = self.downloads[@(task.taskIdentifier)];
        [self.downloads removeObjectForKey:@(task.taskIdentifier)];
    }
    if (!download)
        return;
    NSError *failure = download.failure ?: error;
    if (!download.result && !failure)
        failure = SGCacheError(10, @"Download did not produce a cache entry");
    dispatch_async(dispatch_get_main_queue(), ^{
        download.completion(failure ? nil : download.result, failure);
    });
}
- (void)cancelDownload:(NSUUID *)identifier {
    @synchronized(self) {
        for (SGCacheDownload *download in self.downloads.allValues)
            if ([download.identifier isEqual:identifier]) {
                download.failure = [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCancelled userInfo:nil];
                [download.task cancel];
            }
    }
}
- (BOOL)pinRequest:(NSURLRequest *)request {
    @synchronized(self) {
        if (![self cachedURLForRequest:request])
            return NO;
        NSString *key = SGCacheKey(request);
        self.pins[key] = @(self.pins[key].unsignedIntegerValue + 1);
        return YES;
    }
}
- (void)unpinRequest:(NSURLRequest *)request {
    @synchronized(self) {
        NSString *key = SGCacheKey(request);
        NSUInteger count = self.pins[key].unsignedIntegerValue;
        if (count > 1)
            self.pins[key] = @(count - 1);
        else
            [self.pins removeObjectForKey:key];
    }
}
- (void)removeAllUnpinned {
    @synchronized(self) {
        for (NSURL *URL in [self mediaFiles])
            if (!self.pins[SGCacheFileKey(URL)].unsignedIntegerValue) {
                [NSFileManager.defaultManager removeItemAtURL:URL error:nil];
                [self.entries removeObjectForKey:SGCacheFileKey(URL)];
            }
    }
}
- (void)close {
    @synchronized(self) {
        if (self.closed)
            return;
        self.closed = YES;
        for (SGCacheDownload *download in self.downloads.allValues) {
            download.failure = [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCancelled userInfo:nil];
            [download.task cancel];
        }
        [self.session invalidateAndCancel];
    }
}
@end
