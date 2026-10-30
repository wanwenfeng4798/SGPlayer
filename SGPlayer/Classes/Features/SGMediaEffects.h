#import <Foundation/Foundation.h>
#import <CoreImage/CoreImage.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, SGPlaybackKernel) {
    SGPlaybackKernelFFmpeg,
    SGPlaybackKernelNative,
};
typedef NS_ENUM(NSInteger, SGDanmakuMode) {
    SGDanmakuModeScrolling,
    SGDanmakuModeTop,
    SGDanmakuModeBottom,
    SGDanmakuModeReverse,
};

@interface SGSubtitleCue : NSObject
@property (nonatomic) CMTime start;
@property (nonatomic) CMTime duration;
@property (nonatomic, copy) NSString *text;
@property (nonatomic, copy, nullable) NSString *ASS;
@property (nonatomic, strong, nullable) CIImage *bitmap;
@property (nonatomic) CGRect region;
@end

@interface SGSubtitleTrack : NSObject
@property (nonatomic) NSInteger index;
@property (nonatomic, copy) NSString *language;
@property (nonatomic, copy) NSString *title;
@property (nonatomic) BOOL defaultTrack;
@property (nonatomic) BOOL forced;
@property (nonatomic, copy) NSArray<SGSubtitleCue *> *cues;
@property (nonatomic, copy, nullable) NSData *ASSHeader;
@property (nonatomic, copy) NSDictionary<NSString *,NSData *> *fonts;
@end

@interface SGSubtitleReader : NSObject
// Runs on the calling thread; use a worker queue for remote/large sources.
// Returns owned cues and metadata, independent of the source AVFormatContext.
+ (nullable NSArray<SGSubtitleTrack *> *)readURL:(NSURL *)URL error:(NSError **)error;
@end

@interface SGDanmakuItem : NSObject
@property (nonatomic) NSUInteger rgbColor;
@property (nonatomic) CGFloat fontSize;
@property (nonatomic) CMTime start;
@property (nonatomic) NSTimeInterval duration;
@property (nonatomic) SGDanmakuMode mode;
@property (nonatomic, copy) NSString *text;
@end

/// Reads standard Bilibili XML on the calling thread; run remote reads on a worker.
@interface SGDanmakuReader : NSObject
+ (nullable NSArray<SGDanmakuItem *> *)readURL:(NSURL *)URL error:(NSError **)error;
@end

@interface SGWatermark : NSObject
@property (nonatomic, copy) NSString *text;
@property (nonatomic, strong, nullable) CIImage *image;
// Normalized top-left bounding box in the composed video canvas.
// Preserves aspect ratio and does not upscale beyond the original image pixels.
@property (nonatomic) CGRect rect;
@property (nonatomic) CGFloat opacity;
@end

@interface SGFilterConfiguration : NSObject <NSCopying>
@property (nonatomic) double brightness; // -1 ... 1
@property (nonatomic) double contrast;   // 0 ... 4; default 1
@property (nonatomic) double saturation; // 0 ... 2; default 1
@property (nonatomic) BOOL grayscale;
@property (nonatomic) BOOL horizontalFlip;
@property (nonatomic) BOOL verticalFlip;
// Interleaved float RGB samples (2...64 entries), each component in [0,1].
@property (nonatomic, copy, nullable) NSData *colorCurves;
@property (nonatomic) double blurRadius; // 0 ... 20 pixels
// A true 3D LUT: red changes fastest, RGBA floats, alpha must be 1, dimension 2...64.
@property (nonatomic, copy, nullable) NSData *colorCube;
@property (nonatomic) NSUInteger colorCubeDimension;
@property (nonatomic) double bloomRadius; // 0...20 pixels
@property (nonatomic) double bloomIntensity; // 0...1, default 0
+ (nullable instancetype)configurationWithCubeText:(NSString *)text error:(NSError **)error;
@property (nonatomic, readonly) BOOL active;
- (nullable NSError *)validationError;
@end

@interface SGAnimatedImage : NSObject
@property (nonatomic, readonly) NSTimeInterval duration;
@property (nonatomic, readonly) NSUInteger frameCount;
@property (nonatomic, readonly) NSUInteger loopCount;
+ (nullable instancetype)imageWithURL:(NSURL *)URL maxDecodedBytes:(NSUInteger)limit error:(NSError **)error;
- (nullable CIImage *)imageAtTime:(NSTimeInterval)time;
@end

@interface SGMediaEffects : NSObject
// Configuration and composition are synchronized. Arrays are copied on assignment.
@property (atomic) SGPlaybackKernel kernel;
@property (atomic) BOOL softwareRendering; // CPU composition for background PiP.
@property (atomic, copy) SGFilterConfiguration *filter;
@property (atomic, copy) NSArray<SGSubtitleCue *> *subtitles;
@property (atomic, strong, nullable) SGSubtitleTrack *subtitleTrack;
// Independent ASS renderer for the second track; authored ASS positioning is preserved.
@property (atomic, strong, nullable) SGSubtitleTrack *secondarySubtitleTrack;
@property (atomic) BOOL subtitlesEnabled;
@property (atomic) NSTimeInterval subtitleOffset;
@property (atomic) NSTimeInterval secondarySubtitleOffset;
@property (atomic) CGFloat subtitleVerticalPosition; // plain text, fraction from bottom, default .06
@property (atomic) CGFloat secondarySubtitleVerticalPosition; // plain text, default .80
// Defaults to the bundled Noto CJK font; set a readable font URL to override.
@property (atomic, copy, nullable) NSURL *subtitleFallbackFontURL;
@property (atomic, copy) NSArray<SGDanmakuItem *> *danmaku;
@property (atomic) BOOL danmakuEnabled;
@property (atomic) NSUInteger maximumDanmakuCount;
// Font size on a 720-pixel-wide reference canvas; scales with the video.
@property (atomic) CGFloat textSize;
@property (atomic) NSUInteger textColorRGB; // 0xRRGGBB, default white
@property (atomic) BOOL textBackgroundEnabled; // NO; optional rounded capsule
@property (atomic) NSUInteger textBackgroundColorRGB; // default black
@property (atomic) CGFloat textBackgroundOpacity; // default .65
@property (atomic) CGFloat overlayOpacity;
@property (atomic, copy) NSArray<SGWatermark *> *watermarks;
@property (atomic) BOOL watermarksEnabled; // YES; hiding preserves loaded watermark content.
@property (atomic, strong, nullable) SGAnimatedImage *sticker;
@property (atomic) CGRect stickerRect;
@property (atomic) NSTimeInterval stickerStart;
@property (atomic, readonly) BOOL active;
@property (atomic, strong, readonly, nullable) NSError *lastError;
// Input/output coordinates are pixel based with origin at bottom-left (Core Image).
- (nullable CIImage *)composeImage:(CIImage *)image atTime:(CMTime)time;
- (nullable CVPixelBufferRef)copyPixelBufferForImage:(CIImage *)image atTime:(CMTime)time CF_RETURNS_RETAINED;
- (nullable CGImageRef)copyImageAtTime:(CMTime)time source:(CIImage *)image CF_RETURNS_RETAINED;
/// Copy configuration and mutable cue/event/mark values into independent render state.
/// Take the snapshot on the queue that owns configuration changes.
- (SGMediaEffects *)snapshot;
- (void)flush;
@end

@interface SGGIFExporter : NSObject
@property (atomic, readonly) BOOL cancelled;
@property (nonatomic, copy, nullable) void (^progress)(double value);
- (void)cancel;
// Independent decode session; does not seek or pause the active player.
- (BOOL)exportURL:(NSURL *)source toURL:(NSURL *)destination range:(CMTimeRange)range
 framesPerSecond:(NSInteger)fps maximumDimension:(NSInteger)dimension
         effects:(nullable SGMediaEffects *)effects error:(NSError **)error;
@end
NS_ASSUME_NONNULL_END
