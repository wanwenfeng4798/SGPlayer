#import "SGPlaybackCapabilities.h"
#import "SGFFmpeg.h"
#import <AVKit/AVKit.h>
#import <VideoToolbox/VideoToolbox.h>
#import <libavfilter/avfilter.h>
@implementation SGPlaybackCapabilities
+ (NSDictionary<NSString *, id> *)snapshot {
    NSMutableDictionary *filters = [NSMutableDictionary dictionary];
    for (NSString *name in @[ @"lut3d", @"blend", @"gblur", @"scale", @"bwdif", @"yadif_videotoolbox" ])
        filters[name] = @(avfilter_get_by_name(name.UTF8String) != NULL);
    return @{
        @"schema" : @1,
        @"ffmpegVersion" : @(av_version_info()),
        @"ffmpegLicense" : @(avcodec_license()),
        @"hardwareH264" : @(VTIsHardwareDecodeSupported(kCMVideoCodecType_H264)),
        @"hardwareHEVC" : @(VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC)),
        @"hardwareAV1" : @(VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1)),
        @"pictureInPicture" : @([AVPictureInPictureController isPictureInPictureSupported]),
        @"filters" : filters
    };
}
@end
