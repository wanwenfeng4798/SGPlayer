#import "SGMediaEffects.h"
#import "SGMediaRemuxer.h"
NS_ASSUME_NONNULL_BEGIN
typedef NS_ENUM(NSInteger, SGTranscodeVideoCodec) {
    SGTranscodeVideoCodecMPEG4,
    SGTranscodeVideoCodecH264VideoToolbox,
    SGTranscodeVideoCodecHEVCVideoToolbox
};
@interface SGTranscodeConfiguration : NSObject <NSCopying>
@property(nonatomic) SGMediaContainer container;       // MP4 by default
@property(nonatomic) SGTranscodeVideoCodec videoCodec; // portable software MPEG-4 by default
@property(nonatomic) NSInteger maximumDimension;       // 1280; 32...3840, even output dimensions
@property(nonatomic) NSInteger maximumFramesPerSecond; // 30; 1...60, preserve timestamps, drop excess frames
@property(nonatomic) NSInteger videoBitRate;           // 2,000,000 bits/second
@property(nonatomic) BOOL includeVideo;                // YES; NO exports only audio, without a video encoder
@property(nonatomic) BOOL includeAudio;                // YES; first audio track -> stereo 48 kHz AAC
@property(nonatomic) NSInteger audioBitRate;           // 128,000 bits/second
@property(nonatomic) float audioGain;                  // 1; 0...4, clamp amplified PCM to [-1,1]
- (BOOL)validate:(NSError *_Nullable *_Nullable)error;
@end
/// Independent finite-range SDR/8-bit transcode and effect burning through SGAsset/SGFrameReader.
/// At least one output must be enabled. Audio-only exports require an audio track and nil effects.
/// The first video/audio tracks are selected; supplied subtitles/overlays burn through effects.kernel.
/// Run synchronously on a worker queue. Supply an export-specific effects instance, not a live player's.
/// One operation per instance; cancellation/deadline/failure preserve an existing destination.
/// VideoToolbox choices fail explicitly when unavailable; no automatic encoder substitution.
@interface SGMediaTranscoder : NSObject
@property(atomic, readonly) BOOL cancelled;
@property(nonatomic, copy) SGDemuxerOptions *demuxerOptions;
@property(nonatomic) NSTimeInterval maximumWallTime; // 3600, bounded 1...86400
@property(nonatomic, readonly) NSUInteger videoFrameCount;
@property(nonatomic, readonly) int64_t audioSampleCount; // per channel, excludes encoder tail padding
@property(nonatomic, readonly) CMTimeRange actualRange;
@property(nonatomic, copy, nullable) void (^progress)(double fraction); // calling worker queue
- (void)cancel;
- (BOOL)transcodeURL:(NSURL *)source
               toURL:(NSURL *)destination
       configuration:(SGTranscodeConfiguration *)configuration
               range:(CMTimeRange)range
             effects:(nullable SGMediaEffects *)effects
               error:(NSError *_Nullable *_Nullable)error;
@end
NS_ASSUME_NONNULL_END
