#import <CoreImage/CoreImage.h>
#import <CoreMedia/CoreMedia.h>
#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
/// Independent FFmpeg frame reader: never seeks the active playback session.
/// Call imageAtTime on a worker queue. A provider serializes its requests; cancel is permanent.
@interface SGTimelinePreview : NSObject
- (instancetype)initWithURL:(NSURL *)URL;
@property(atomic, readonly) BOOL cancelled;
- (nullable CIImage *)imageAtTime:(CMTime)time maximumDimension:(NSInteger)dimension error:(NSError **)error;
- (void)cancel;
@end

@interface SGTimelineSpriteCue : NSObject
@property(nonatomic, readonly) CMTimeRange range;
@property(nonatomic, copy, readonly) NSURL *URL;
@property(nonatomic, readonly) CGRect pixelRect; // CGRectNull means the whole image
@end
/// WebVTT sprite metadata. Image fetching stays with the application's authenticated source/cache layer.
@interface SGTimelineSpriteIndex : NSObject
+ (nullable instancetype)indexWithWebVTT:(NSString *)text baseURL:(NSURL *)URL error:(NSError **)error;
@property(nonatomic, copy, readonly) NSArray<SGTimelineSpriteCue *> *cues;
- (nullable SGTimelineSpriteCue *)cueAtTime:(CMTime)time;
+ (nullable CIImage *)imageForCue:(SGTimelineSpriteCue *)cue
                        imageData:(NSData *)data
                 maximumDimension:(NSInteger)dimension
                            error:(NSError **)error;
@end
NS_ASSUME_NONNULL_END
