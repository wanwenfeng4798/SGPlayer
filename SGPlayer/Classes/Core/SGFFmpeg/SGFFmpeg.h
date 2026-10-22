//
//  SGFFmpeg.h
//  SGPlayer
//
//  Created by Single on 2018/8/2.
//  Copyright © 2018 single. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdocumentation"
#import <libavformat/avformat.h>
#import <libavutil/imgutils.h>
#import <libavutil/common.h>
#import <libavutil/pixdesc.h>
#import <libavutil/hwcontext.h>
#import <libswresample/swresample.h>
#import <libswscale/swscale.h>
#import <libavcodec/avcodec.h>
#pragma clang diagnostic pop

void SGFFmpegSetupIfNeeded(void);

CMTime SGFFmpegTime(int64_t value, AVRational timebase);
