#import "SGMediaEffects.h"
#import "SGURLDemuxer.h"
#import "SGVideoDecoder.h"
#import "SGOptions.h"
#import "SGError.h"
#import "SGVideoFrame.h"
#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import "SGPLFTargets.h"

@interface SGGIFExporter ()
@property (atomic, readwrite) BOOL cancelled;
@end
@implementation SGGIFExporter
- (void)cancel { self.cancelled = YES; }
- (BOOL)exportURL:(NSURL *)source toURL:(NSURL *)destination range:(CMTimeRange)range framesPerSecond:(NSInteger)fps maximumDimension:(NSInteger)dimension effects:(SGMediaEffects *)effects error:(NSError **)error
{
    double start = CMTimeGetSeconds(range.start), duration = CMTimeGetSeconds(range.duration);
    if (!isfinite(start) || start < 0 || !isfinite(duration) || duration <= 0 || duration > 30 || fps < 1 || fps > 30 || dimension < 32 || dimension > 1920 || !destination.isFileURL || [source isEqual:destination]) {
        if (error) *error = [NSError errorWithDomain:@"SGGIFExporter" code:1 userInfo:@{NSLocalizedDescriptionKey:@"Invalid GIF range, frame rate, dimensions or output URL"}]; return NO;
    }
    SGURLDemuxer *demuxer = [[SGURLDemuxer alloc] initWithURL:source];
    NSError *failure = [demuxer open];
    SGVideoDecoder *decoder = [[SGVideoDecoder alloc] init]; decoder.options = [SGOptions sharedOptions].decoder.copy;
    decoder.options.hardwareDecodeH264 = NO; decoder.options.hardwareDecodeH265 = NO;
    if (!failure && [SGTrack tracksWithTracks:demuxer.tracks type:SGMediaTypeVideo].count == 0) failure = [NSError errorWithDomain:@"SGGIFExporter" code:2 userInfo:@{NSLocalizedDescriptionKey:@"No video stream"}];
    if (!failure) failure = [demuxer seekToTime:range.start toleranceBefor:kCMTimeZero toleranceAfter:kCMTimeZero];
    NSUInteger requested = (NSUInteger)ceil(duration * fps);
    NSURL *temporary = [[destination URLByDeletingLastPathComponent] URLByAppendingPathComponent:[NSString stringWithFormat:@".%@.gif", NSUUID.UUID.UUIDString]];
    CGImageDestinationRef output = failure ? NULL : CGImageDestinationCreateWithURL((__bridge CFURLRef)temporary, (__bridge CFStringRef)UTTypeGIF.identifier, requested, NULL);
    if (!failure && !output) failure = [NSError errorWithDomain:@"SGGIFExporter" code:3 userInfo:@{NSLocalizedDescriptionKey:@"Cannot create GIF output"}];
    if (output) CGImageDestinationSetProperties(output, (__bridge CFDictionaryRef)@{(__bridge NSString *)kCGImagePropertyGIFDictionary:@{(__bridge NSString *)kCGImagePropertyGIFLoopCount:@0}});
    __block NSUInteger written = 0;
    __block NSError *frameError = nil;
    CIContext *context = [CIContext contextWithOptions:@{kCIContextCacheIntermediates:@NO}];
    void (^consume)(NSArray *) = ^(NSArray *frames) {
        for (SGVideoFrame *frame in frames) {
            if (!self.cancelled && written < requested && !frameError) {
                double frameStart = CMTimeGetSeconds(frame.timeStamp), end = frameStart + CMTimeGetSeconds(frame.duration);
                while (written < requested && start + written / (double)fps < end && !self.cancelled && !frameError) {
                    @autoreleasepool {
                        double sample = start + written / (double)fps;
                        SGPLFImage *platformImage = [frame image];
                        CGImageRef cg = NULL;
#if SGPLATFORM_TARGET_OS_MAC
                        if (platformImage) cg = [platformImage CGImageForProposedRect:NULL context:nil hints:nil];
#else
                        cg = platformImage.CGImage;
#endif
                        if (!cg) { frameError = [NSError errorWithDomain:@"SGGIFExporter" code:4 userInfo:@{NSLocalizedDescriptionKey:@"Unable to convert video frame"}]; break; }
                        CIImage *image = [CIImage imageWithCGImage:cg];
                        double scale = MIN(1, dimension / MAX(image.extent.size.width,image.extent.size.height));
                        image = [image imageByApplyingTransform:CGAffineTransformMakeScale(scale, scale)];
                        if (effects) image = [effects composeImage:image atTime:CMTimeMakeWithSeconds(sample,1000000)];
                        CGImageRef composed = image ? [context createCGImage:image fromRect:image.extent] : NULL;
                        if (!composed) { frameError = effects.lastError ?: [NSError errorWithDomain:@"SGGIFExporter" code:5 userInfo:@{NSLocalizedDescriptionKey:@"Unable to compose GIF frame"}]; break; }
                        double delay = MIN(1.0/fps, start + duration - sample);
                        NSDictionary *properties = @{(__bridge NSString *)kCGImagePropertyGIFDictionary:@{(__bridge NSString *)kCGImagePropertyGIFDelayTime:@(delay),(__bridge NSString *)kCGImagePropertyGIFUnclampedDelayTime:@(delay)}};
                        CGImageDestinationAddImage(output,composed,(__bridge CFDictionaryRef)properties);
                        CGImageRelease(composed); written++;
                        if (self.progress) self.progress(written/(double)requested);
                    }
                }
            }
            [frame unlock];
        }
    };
    while (!failure && !frameError && !self.cancelled && written < requested) {
        @autoreleasepool {
            SGPacket *packet = nil;
            NSError *next = [demuxer nextPacket:&packet];
            if (next) {
                if (next.code == SGErrorCodeDemuxerEndOfFile) consume([decoder finish]); else failure = next;
                break;
            }
            if (packet.track.type == SGMediaTypeVideo) consume([decoder decode:packet]);
            [packet unlock];
        }
    }
    failure = failure ?: frameError;
    if (self.cancelled) failure = [NSError errorWithDomain:NSCocoaErrorDomain code:NSUserCancelledError userInfo:nil];
    if (!failure && written != requested) failure = [NSError errorWithDomain:@"SGGIFExporter" code:6 userInfo:@{NSLocalizedDescriptionKey:@"Requested GIF interval exceeds available video frames"}];
    BOOL finished = output && !failure ? CGImageDestinationFinalize(output) : NO;
    if (output) CFRelease(output);
    [decoder flush]; [demuxer close];
    if (finished) {
        NSFileManager *manager = NSFileManager.defaultManager;
        if ([manager fileExistsAtPath:destination.path]) finished = [manager replaceItemAtURL:destination withItemAtURL:temporary backupItemName:nil options:0 resultingItemURL:nil error:&failure];
        else finished = [manager moveItemAtURL:temporary toURL:destination error:&failure];
    }
    if (!finished) {
        [NSFileManager.defaultManager removeItemAtURL:temporary error:nil];
        if (error) *error = failure ?: [NSError errorWithDomain:@"SGGIFExporter" code:7 userInfo:@{NSLocalizedDescriptionKey:@"GIF finalization failed"}];
    }
    return finished;
}
@end
