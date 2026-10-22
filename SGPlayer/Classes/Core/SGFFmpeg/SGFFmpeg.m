//
//  SGFFmpeg.m
//  SGPlayer
//
//  Created by Single on 2018/8/2.
//  Copyright © 2018 single. All rights reserved.
//

#import "SGFFmpeg.h"

static void SGFFmpegLogCallback(void * context, int level, const char * format, va_list args)
{
//    NSString * message = [[NSString alloc] initWithFormat:[NSString stringWithUTF8String:format] arguments:args];
//    NSLog(@"SGFFLog : %@", message);
}

void SGFFmpegSetupIfNeeded(void)
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        av_log_set_callback(SGFFmpegLogCallback);
        avformat_network_init();
    });
}

CMTime SGFFmpegTime(int64_t value, AVRational timebase)
{
    if (value == AV_NOPTS_VALUE || timebase.num <= 0 || timebase.den <= 0) {
        return kCMTimeInvalid;
    }
    return CMTimeMultiplyByRatio(CMTimeMake(value, timebase.den), timebase.num, 1);
}
