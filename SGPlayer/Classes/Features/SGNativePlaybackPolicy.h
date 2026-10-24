#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
/// Native AVPlayer resource/ABR policy. Zero values leave selection to the system.
/// These preferences are hints to AVPlayer; they cannot guarantee a selected variant.
@interface SGNativePlaybackPolicy : NSObject <NSCopying>
@property(nonatomic) double preferredPeakBitRate;                   // bits/second, zero = no cap
@property(nonatomic) CGSize preferredMaximumResolution;             // CGSizeZero = unspecified
@property(nonatomic) NSTimeInterval preferredForwardBufferDuration; // zero = automatic
@property(nonatomic) BOOL automaticallyWaitsToMinimizeStalling;     // YES
@property(nonatomic) BOOL allowsNetworkWhilePaused;                 // NO; relevant to live streams
- (BOOL)validate:(NSError *_Nullable *_Nullable)error;
@end
NS_ASSUME_NONNULL_END
