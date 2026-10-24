#import "SGDemuxerOptions.h"
#import <CoreMedia/CoreMedia.h>
#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
typedef NS_ENUM(NSInteger, SGMediaContainer) { SGMediaContainerMatroska, SGMediaContainerMP4, SGMediaContainerMPEGTS };
/// Packet recording/container conversion using an independent SGURLDemuxer. No re-encoding or burned effects.
/// Run on a worker queue. Clips begin at the first primary-video keyframe returned by the backward seek.
/// actualRange reports that boundary. Only the primary video and audio/subtitle/attachment tracks are copied.
@interface SGMediaRemuxer : NSObject
@property(atomic, readonly) BOOL cancelled;
@property(nonatomic, copy) SGDemuxerOptions *demuxerOptions;
@property(nonatomic) NSTimeInterval maximumWallTime; // default 3600; bounded 1...86400
@property(nonatomic, readonly) CMTimeRange actualRange;
@property(nonatomic, copy, nullable) void (^progress)(double fraction); // calling worker queue
- (void)cancel;
- (BOOL)remuxURL:(NSURL *)source
           toURL:(NSURL *)destination
       container:(SGMediaContainer)container
           range:(CMTimeRange)range
           error:(NSError **)error;
@end
NS_ASSUME_NONNULL_END
