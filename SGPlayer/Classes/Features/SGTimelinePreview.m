#import "SGTimelinePreview.h"
#import "SGPlayer.h"
#import <ImageIO/ImageIO.h>
#import <QuartzCore/QuartzCore.h>
static NSError *SGPreviewError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:@"SGTimelinePreview" code:code userInfo:@{NSLocalizedDescriptionKey : message}];
}
static CIImage *SGPreviewScale(CIImage *image, NSInteger dimension) {
    CGFloat scale = MIN(1, dimension / MAX(image.extent.size.width, image.extent.size.height));
    return [image imageByApplyingTransform:CGAffineTransformMakeScale(scale, scale)];
}
@interface SGTimelinePreview () <SGFrameReaderDelegate>
@property(atomic, readwrite) BOOL cancelled;
@property(nonatomic, copy) NSURL *URL;
@property(nonatomic) CFTimeInterval deadline;
@property(nonatomic, strong) NSCache<NSString *, CIImage *> *cache;
@end
@implementation SGTimelinePreview
- (instancetype)initWithURL:(NSURL *)URL {
    if ((self = [super init])) {
        _URL = [URL copy];
        _cache = [NSCache new];
        _cache.totalCostLimit = 32 * 1024 * 1024;
        _cache.countLimit = 60;
    }
    return self;
}
- (void)cancel {
    self.cancelled = YES;
}
- (BOOL)frameReaderShouldAbortBlockingFunctions:(SGFrameReader *)reader {
    return self.cancelled || CACurrentMediaTime() > self.deadline;
}
- (CIImage *)imageAtTime:(CMTime)time maximumDimension:(NSInteger)dimension error:(NSError **)error {
    @synchronized(self) {
        double seconds = CMTimeGetSeconds(time);
        if (!isfinite(seconds) || seconds < 0 || dimension < 32 || dimension > 1920 || self.cancelled) {
            if (error)
                *error = SGPreviewError(1, @"Invalid preview request or cancelled provider");
            return nil;
        }
        NSString *key = [NSString stringWithFormat:@"%.6f:%ld", seconds, (long)dimension];
        CIImage *cached = [self.cache objectForKey:key];
        if (cached)
            return cached;
        self.deadline = CACurrentMediaTime() + 15;
        SGFrameReader *reader = [[SGFrameReader alloc] initWithAsset:[SGAsset assetWithURL:self.URL]];
        reader.delegate = self;
        SGDecoderOptions *options = [SGOptions sharedOptions].decoder.copy;
        options.hardwareDecodeH264 = NO;
        options.hardwareDecodeH265 = NO;
        reader.decoderOptions = options;
        NSError *failure = [reader open];
        CIImage *result = nil;
        NSArray *tracks = [SGTrack tracksWithTracks:reader.tracks type:SGMediaTypeVideo];
        if (!failure && !tracks.count)
            failure = SGPreviewError(2, @"Source contains no video track");
        if (!failure)
            failure = [reader selectTracks:@[ tracks.firstObject ]];
        if (!failure)
            failure = [reader seekToTime:time toleranceBefor:kCMTimeZero toleranceAfter:kCMTimeZero];
        NSUInteger count = 0;
        while (!failure && !self.cancelled && CACurrentMediaTime() < self.deadline && count++ < 10000) {
            @autoreleasepool {
                SGFrame *frame = nil;
                failure = [reader nextFrame:&frame];
                if (failure)
                    break;
                if ([frame isKindOfClass:SGVideoFrame.class]) {
                    double start = CMTimeGetSeconds(frame.timeStamp), duration = CMTimeGetSeconds(frame.duration);
                    if (isfinite(start) && (start >= seconds || (isfinite(duration) && start + duration > seconds))) {
                        SGPLFImage *platform = ((SGVideoFrame *)frame).image;
                        CGImageRef cg = NULL;
#if SGPLATFORM_TARGET_OS_MAC
                        cg = [platform CGImageForProposedRect:NULL context:nil hints:nil];
#else
                        cg = platform.CGImage;
#endif
                        if (cg)
                            result = SGPreviewScale([CIImage imageWithCGImage:cg], dimension);
                    }
                }
                [frame unlock];
                if (result)
                    break;
            }
        }
        [reader close];
        if (self.cancelled)
            failure = [NSError errorWithDomain:NSCocoaErrorDomain code:NSUserCancelledError userInfo:nil];
        if (!result && !failure)
            failure = SGPreviewError(3, @"Preview frame was unavailable before the decode deadline");
        if (failure) {
            if (error)
                *error = failure;
            return nil;
        }
        [self.cache setObject:result
                       forKey:key
                         cost:(NSUInteger)(result.extent.size.width * result.extent.size.height * 4)];
        return result;
    }
}
@end

@interface SGTimelineSpriteCue ()
@property(nonatomic, readwrite) CMTimeRange range;
@property(nonatomic, copy, readwrite) NSURL *URL;
@property(nonatomic, readwrite) CGRect pixelRect;
@end
@implementation SGTimelineSpriteCue
@end
@interface SGTimelineSpriteIndex ()
@property(nonatomic, copy, readwrite) NSArray<SGTimelineSpriteCue *> *cues;
@end
static double SGPreviewTimestamp(NSString *text) {
    NSArray *parts = [text componentsSeparatedByString:@":"];
    if (parts.count < 2 || parts.count > 3)
        return NAN;
    double total = 0;
    for (NSUInteger i = 0; i < parts.count; i++) {
        NSScanner *scanner = [NSScanner scannerWithString:parts[i]];
        double value = 0;
        if (![scanner scanDouble:&value] || !scanner.isAtEnd || !isfinite(value) || value < 0 || (i > 0 && value >= 60))
            return NAN;
        if (i + 1 < parts.count && floor(value) != value)
            return NAN;
        total = total * 60 + value;
    }
    return total;
}
@implementation SGTimelineSpriteIndex
+ (instancetype)indexWithWebVTT:(NSString *)text baseURL:(NSURL *)URL error:(NSError **)error {
    NSString *normalized = [[text stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"]
        stringByReplacingOccurrencesOfString:@"\r"
                                  withString:@"\n"];
    if ([normalized hasPrefix:@"\uFEFF"])
        normalized = [normalized substringFromIndex:1];
    if (text.length > 2 * 1024 * 1024 || ![normalized hasPrefix:@"WEBVTT"] || !URL) {
        if (error)
            *error = SGPreviewError(4, @"Invalid WebVTT sprite index");
        return nil;
    }
    NSMutableArray *cues = [NSMutableArray array];
    BOOL invalid = NO;
    for (NSString *block in [normalized componentsSeparatedByString:@"\n\n"]) {
        NSArray *lines = [block componentsSeparatedByString:@"\n"];
        if ([block hasPrefix:@"NOTE"] || [block hasPrefix:@"WEBVTT"])
            continue;
        for (NSUInteger i = 0; i + 1 < lines.count; i++) {
            if (![lines[i] containsString:@"-->"])
                continue;
            NSArray *times = [lines[i] componentsSeparatedByString:@"-->"];
            if (times.count != 2) {
                invalid = YES;
                break;
            }
            NSString *start = [times[0] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
            NSString *end = [[times[1] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet]
                                componentsSeparatedByString:@" "]
                                .firstObject;
            double a = SGPreviewTimestamp(start), b = SGPreviewTimestamp(end);
            NSString *reference = [lines[i + 1] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
            NSURL *resolved = [NSURL URLWithString:reference relativeToURL:URL].absoluteURL;
            CGRect rect = CGRectNull;
            if (resolved.fragment) {
                NSString *fragment = resolved.fragment;
                if (![fragment hasPrefix:@"xywh="]) {
                    invalid = YES;
                    break;
                }
                NSArray *numbers = [[fragment substringFromIndex:5] componentsSeparatedByString:@","];
                double values[4] = {0};
                if (numbers.count != 4) {
                    invalid = YES;
                    break;
                }
                for (int j = 0; j < 4; j++) {
                    NSScanner *scanner = [NSScanner scannerWithString:numbers[j]];
                    if (![scanner scanDouble:&values[j]] || !scanner.isAtEnd || !isfinite(values[j]) || values[j] < 0 ||
                        values[j] > 8192 || floor(values[j]) != values[j])
                        invalid = YES;
                }
                if (values[2] <= 0 || values[3] <= 0)
                    invalid = YES;
                rect = CGRectMake(values[0], values[1], values[2], values[3]);
                NSURLComponents *components = [NSURLComponents componentsWithURL:resolved resolvingAgainstBaseURL:YES];
                components.fragment = nil;
                resolved = components.URL;
            }
            if (!isfinite(a) || !isfinite(b) || b <= a || !reference.length ||
                ![@[ @"file", @"http", @"https" ] containsObject:resolved.scheme.lowercaseString] ||
                cues.count >= 10000)
                invalid = YES;
            if (invalid)
                break;
            SGTimelineSpriteCue *cue = [SGTimelineSpriteCue new];
            cue.range = CMTimeRangeMake(CMTimeMakeWithSeconds(a, 1000000), CMTimeMakeWithSeconds(b - a, 1000000));
            cue.URL = resolved;
            cue.pixelRect = rect;
            [cues addObject:cue];
            break;
        }
        if (invalid)
            break;
    }
    [cues sortUsingComparator:^NSComparisonResult(SGTimelineSpriteCue *a, SGTimelineSpriteCue *b) {
        int c = CMTimeCompare(a.range.start, b.range.start);
        return c < 0 ? NSOrderedAscending : c > 0 ? NSOrderedDescending : NSOrderedSame;
    }];
    for (NSUInteger i = 1; i < cues.count; i++)
        if (CMTimeCompare(((SGTimelineSpriteCue *)cues[i]).range.start,
                          CMTimeRangeGetEnd(((SGTimelineSpriteCue *)cues[i - 1]).range)) < 0)
            invalid = YES;
    if (invalid || !cues.count) {
        if (error)
            *error = SGPreviewError(4, @"Sprite index contains invalid or overlapping cues");
        return nil;
    }
    SGTimelineSpriteIndex *index = [self new];
    index.cues = cues;
    return index;
}
- (SGTimelineSpriteCue *)cueAtTime:(CMTime)time {
    if (!CMTIME_IS_NUMERIC(time))
        return nil;
    NSUInteger low = 0, high = self.cues.count;
    while (low < high) {
        NSUInteger middle = low + (high - low) / 2;
        if (CMTimeCompare(self.cues[middle].range.start, time) <= 0)
            low = middle + 1;
        else
            high = middle;
    }
    SGTimelineSpriteCue *cue = low ? self.cues[low - 1] : nil;
    return cue && CMTimeRangeContainsTime(cue.range, time) ? cue : nil;
}
+ (CIImage *)imageForCue:(SGTimelineSpriteCue *)cue
               imageData:(NSData *)data
        maximumDimension:(NSInteger)dimension
                   error:(NSError **)error {
    if (!data.length || data.length > 16 * 1024 * 1024 || dimension < 32 || dimension > 1920) {
        if (error)
            *error = SGPreviewError(5, @"Sprite data or preview dimensions exceed limits");
        return nil;
    }
    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
    CIImage *image = nil;
    if (source) {
        NSDictionary *properties = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source, 0, NULL));
        double w = [properties[(__bridge NSString *)kCGImagePropertyPixelWidth] doubleValue],
               h = [properties[(__bridge NSString *)kCGImagePropertyPixelHeight] doubleValue];
        if (w > 0 && h > 0 && w <= 8192 && h <= 8192 && w * h <= 16 * 1024 * 1024) {
            CGImageRef cg = CGImageSourceCreateImageAtIndex(source, 0, NULL);
            if (cg) {
                image = [CIImage imageWithCGImage:cg];
                CGImageRelease(cg);
            }
        }
        CFRelease(source);
    }
    if (image && !CGRectIsNull(cue.pixelRect)) {
        CGRect top = cue.pixelRect;
        if (!CGRectContainsRect(image.extent, top))
            image = nil;
        else {
            CGRect rect = CGRectMake(top.origin.x, image.extent.size.height - CGRectGetMaxY(top), top.size.width,
                                     top.size.height);
            image = [[image imageByCroppingToRect:rect]
                imageByApplyingTransform:CGAffineTransformMakeTranslation(-rect.origin.x, -rect.origin.y)];
        }
    }
    if (!image) {
        if (error)
            *error = SGPreviewError(6, @"Invalid sprite bitmap or crop rectangle");
        return nil;
    }
    return SGPreviewScale(image, dimension);
}
@end
