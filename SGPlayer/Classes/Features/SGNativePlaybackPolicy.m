#import "SGNativePlaybackPolicy.h"
@implementation SGNativePlaybackPolicy
- (instancetype)init {
    if ((self = [super init]))
        _automaticallyWaitsToMinimizeStalling = YES;
    return self;
}
- (id)copyWithZone:(NSZone *)zone {
    SGNativePlaybackPolicy *copy = [[[self class] allocWithZone:zone] init];
    copy.preferredPeakBitRate = self.preferredPeakBitRate;
    copy.preferredMaximumResolution = self.preferredMaximumResolution;
    copy.preferredForwardBufferDuration = self.preferredForwardBufferDuration;
    copy.automaticallyWaitsToMinimizeStalling = self.automaticallyWaitsToMinimizeStalling;
    copy.allowsNetworkWhilePaused = self.allowsNetworkWhilePaused;
    return copy;
}
- (BOOL)validate:(NSError **)error {
    CGSize size = self.preferredMaximumResolution;
    BOOL valid = isfinite(self.preferredPeakBitRate) && self.preferredPeakBitRate >= 0 &&
                 isfinite(self.preferredForwardBufferDuration) && self.preferredForwardBufferDuration >= 0 &&
                 isfinite(size.width) && isfinite(size.height) &&
                 ((size.width == 0 && size.height == 0) || (size.width > 0 && size.height > 0));
    if (!valid && error)
        *error =
            [NSError errorWithDomain:@"SGNativePlaybackPolicy"
                                code:1
                            userInfo:@{
                                NSLocalizedDescriptionKey : @"Bitrate/buffer duration must be finite and nonnegative; "
                                                            @"resolution must have two positive dimensions or be zero"
                            }];
    return valid;
}
@end
