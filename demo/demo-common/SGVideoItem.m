//
//  SGVideoItem.m
//  demo-common
//
//  Created by Single on 2017/3/15.
//  Copyright © 2017年 single. All rights reserved.
//

#import "SGVideoItem.h"

@implementation SGVideoItem

+ (NSArray<SGVideoItem *> *)videoItems
{
    NSURL *i_see_fire = [[NSBundle mainBundle] URLForResource:@"i-see-fire" withExtension:@"mp4"];
    NSURL *google_help_vr = [[NSBundle mainBundle] URLForResource:@"google-help-vr" withExtension:@"mp4"];
    
    NSMutableArray *items = [NSMutableArray array];
    {
        SGVideoItem *item = [[SGVideoItem alloc] init];
        item.name = @"I See Fire";
        item.asset = [SGAsset assetWithURL:i_see_fire];
        item.displayMode = SGDisplayModePlane;
        [items addObject:item];
    }
    {
        SGMutableAsset *asset = [[SGMutableAsset alloc] init];
        SGMutableTrack *track = [asset addTrack:SGMediaTypeVideo];
        SGSegment *segment = [SGSegment segmentWithURL:i_see_fire index:0];
        [track appendSegment:segment];
        
        SGVideoItem *item = [[SGVideoItem alloc] init];
        item.name = @"I See Fire, Video Track";
        item.asset = asset;
        item.displayMode = SGDisplayModePlane;
        [items addObject:item];
    }
    {
        SGMutableAsset *asset = [[SGMutableAsset alloc] init];
        SGMutableTrack *track = [asset addTrack:SGMediaTypeAudio];
        SGSegment *segment = [SGSegment segmentWithURL:i_see_fire index:1];
        [track appendSegment:segment];
        
        SGVideoItem *item = [[SGVideoItem alloc] init];
        item.name = @"I See Fire, Audio Track";
        item.asset = asset;
        item.displayMode = SGDisplayModePlane;
        [items addObject:item];
    }
    {
        CMTime scale = kCMTimeInvalid;
        CMTimeRange timeRange = CMTimeRangeMake(CMTimeMake(30, 1), CMTimeMake(10, 1));
        
        SGMutableAsset *asset = [[SGMutableAsset alloc] init];
        {
            SGMutableTrack *track = [asset addTrack:SGMediaTypeAudio];
            SGSegment *segment = [SGSegment segmentWithURL:i_see_fire index:1 timeRange:timeRange scale:scale];
            [track appendSegment:segment];
        }
        {
            SGMutableTrack *track = [asset addTrack:SGMediaTypeVideo];
            SGSegment *segment = [SGSegment segmentWithURL:i_see_fire index:0 timeRange:timeRange scale:scale];
            [track appendSegment:segment];
        }
        
        SGVideoItem *item = [[SGVideoItem alloc] init];
        item.name = @"I See Fire, Range: 30s-40s";
        item.asset = asset;
        item.displayMode = SGDisplayModePlane;
        [items addObject:item];
    }
    {
        CMTime scale = CMTimeMake(1, 2);
        CMTimeRange timeRange = CMTimeRangeMake(CMTimeMake(30, 1), CMTimeMake(20, 1));
        
        SGMutableAsset *asset = [[SGMutableAsset alloc] init];
        {
            SGMutableTrack *track = [asset addTrack:SGMediaTypeAudio];
            SGSegment *segment = [SGSegment segmentWithURL:i_see_fire index:1 timeRange:timeRange scale:scale];
            [track appendSegment:segment];
        }
        {
            SGMutableTrack *track = [asset addTrack:SGMediaTypeVideo];
            SGSegment *segment = [SGSegment segmentWithURL:i_see_fire index:0 timeRange:timeRange scale:scale];
            [track appendSegment:segment];
        }
        
        SGVideoItem *item = [[SGVideoItem alloc] init];
        item.name = @"I See Fire, Range: 30s-50s, Scale: 0.5";
        item.asset = asset;
        item.displayMode = SGDisplayModePlane;
        [items addObject:item];
    }
    {
        SGMutableAsset *asset = [[SGMutableAsset alloc] init];
        {
            SGMutableTrack *track = [asset addTrack:SGMediaTypeAudio];
            SGSegment *segment1 = [SGURLSegment segmentWithURL:i_see_fire index:1];
            SGSegment *segment2 = [SGURLSegment segmentWithURL:google_help_vr index:1];
            [track appendSegment:segment1];
            [track appendSegment:segment2];
        }
        {
            SGMutableTrack *track = [asset addTrack:SGMediaTypeVideo];
            SGSegment *segment1 = [SGURLSegment segmentWithURL:i_see_fire index:0];
            SGSegment *segment2 = [SGURLSegment segmentWithURL:google_help_vr index:0];
            [track appendSegment:segment1];
            [track appendSegment:segment2];
        }
        
        SGVideoItem *item = [[SGVideoItem alloc] init];
        item.name = @"I See Fire + Google Help";
        item.asset = asset;
        item.displayMode = SGDisplayModePlane;
        [items addObject:item];
    }
    {
        SGVideoItem *item = [[SGVideoItem alloc] init];
        item.name = @"Google Help VR";
        item.asset = [SGAsset assetWithURL:google_help_vr];
        item.displayMode = SGDisplayModeVR;
        [items addObject:item];
    }
    return items;
}

@end

#if DEBUG
#import <AVFoundation/AVFoundation.h>
extern const char *av_version_info(void);

@interface SGDemoPlaybackTest ()
@property (nonatomic, strong) SGPlayer *player;
@property (nonatomic, strong) NSArray<SGVideoItem *> *items;
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic, strong) NSMutableArray *results;
@property (nonatomic, strong) NSMutableDictionary *checks;
@property (nonatomic, strong) NSURL *directory;
@property (nonatomic, copy) void (^completion)(NSDictionary *);
@property (nonatomic) NSUInteger index;
@property (nonatomic) NSUInteger phase;
@property (nonatomic) NSUInteger frames;
@property (nonatomic) NSUInteger hardwareFrames;
@property (nonatomic) NSUInteger framesBeforeSeek;
@property (nonatomic) NSTimeInterval caseStart;
@property (nonatomic) NSTimeInterval phaseStart;
@property (nonatomic) Float64 referenceTime;
@property (nonatomic) Float64 seekTarget;
@property (nonatomic) BOOL seekDone;
@property (nonatomic) BOOL seekFailed;
@property (nonatomic) BOOL screenshot;
@end

@implementation SGDemoPlaybackTest

+ (instancetype)startInView:(SGPLFView *)view completion:(void (^)(NSDictionary *))completion
{
    SGDemoPlaybackTest *test = [[self alloc] init];
    test.completion = completion;
    test.items = SGVideoItem.videoItems;
    test.results = [NSMutableArray array];
    test.directory = [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
    for (NSString *argument in NSProcessInfo.processInfo.arguments) {
        if ([argument hasPrefix:@"--sgplayer-test-output="]) test.directory = [NSURL fileURLWithPath:[argument substringFromIndex:[@"--sgplayer-test-output=" length]] isDirectory:YES];
    }
    [NSFileManager.defaultManager createDirectoryAtURL:test.directory withIntermediateDirectories:YES attributes:nil error:nil];
    test.player = [[SGPlayer alloc] init];
    test.player.videoRenderer.view = view;
    __weak SGDemoPlaybackTest *weakTest = test;
    test.player.videoRenderer.frameOutput = ^(SGVideoFrame *frame) {
        SGDemoPlaybackTest *test = weakTest;
        test.frames++;
        if (frame.pixelBuffer) test.hardwareFrames++;
    };
    [test beginCase];
    test.timer = [NSTimer scheduledTimerWithTimeInterval:0.2 repeats:YES block:^(NSTimer *timer) { [weakTest tick]; }];
    return test;
}

- (void)beginCase
{
    self.phase = 0;
    self.frames = 0;
    self.hardwareFrames = 0;
    self.seekDone = NO;
    self.seekFailed = NO;
    self.screenshot = NO;
    self.checks = [NSMutableDictionary dictionary];
    self.caseStart = NSDate.timeIntervalSinceReferenceDate;
    self.phaseStart = self.caseStart;
    self.player.rate = 1.0;
    SGVideoItem *item = self.items[self.index];
    self.player.videoRenderer.displayMode = item.displayMode;
    [self.player replaceWithAsset:item.asset];
    [self.player play];
    NSLog(@"SGPLAYER_DEMO_CASE_START %lu %@", (unsigned long)self.index, item.name);
}

- (void)seek:(Float64)target
{
    self.seekTarget = target;
    self.seekDone = NO;
    self.seekFailed = NO;
    self.framesBeforeSeek = self.frames;
    [self.player seekToTime:CMTimeMakeWithSeconds(target, 1000) result:^(CMTime time, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self.seekFailed = error != nil;
            self.seekDone = YES;
        });
    }];
}

- (void)tick
{
    SGTimeInfo time = self.player.timeInfo;
    Float64 position = CMTimeGetSeconds(time.playback);
    Float64 duration = CMTimeGetSeconds(time.duration);
    NSTimeInterval now = NSDate.timeIntervalSinceReferenceDate;
    NSError *error = self.player.error;
    BOOL video = self.index != 2;
    if (error || self.seekFailed || now - self.caseStart > 45) {
        [self finishCase:NO error:error.localizedDescription ?: (self.seekFailed ? @"seek failed" : [NSString stringWithFormat:@"stalled in phase %lu at %.3f", (unsigned long)self.phase, position])];
        return;
    }
    switch (self.phase) {
        case 0:
            if (isfinite(position) && position >= 0.8 && (!video || self.frames >= 8)) {
                self.checks[@"play"] = @YES;
                [self.player pause];
                self.referenceTime = position;
                self.phaseStart = now;
                self.phase = 1;
            }
            break;
        case 1:
            if (now - self.phaseStart >= 0.7) {
                if (fabs(position - self.referenceTime) > 0.25) { [self finishCase:NO error:@"playback continued while paused"]; return; }
                self.checks[@"pause"] = @YES;
                [self.player play];
                self.phase = 2;
            }
            break;
        case 2:
            if (position >= self.referenceTime + 0.5) {
                self.checks[@"resume"] = @YES;
                self.player.rate = 0.5;
                self.phaseStart = now;
                self.referenceTime = position;
                self.phase = 3;
            }
            break;
        case 3:
            if (now - self.phaseStart >= 1.2) {
                Float64 delta = position - self.referenceTime;
                if (delta < 0.15 || delta > 1.4) { [self finishCase:NO error:[NSString stringWithFormat:@"0.5x playback delta %.3f over %.3fs", delta, now - self.phaseStart]]; return; }
                self.checks[@"rate0.5"] = @(delta / (now - self.phaseStart));
                self.player.rate = 2.0;
                self.phaseStart = now;
                self.referenceTime = position;
                self.phase = 4;
            }
            break;
        case 4:
            if (now - self.phaseStart >= 1.2) {
                Float64 delta = position - self.referenceTime;
                if (delta < 0.8 || delta > 4.2) { [self finishCase:NO error:[NSString stringWithFormat:@"2x playback delta %.3f over %.3fs", delta, now - self.phaseStart]]; return; }
                self.checks[@"rate2"] = @(delta / (now - self.phaseStart));
                self.player.rate = 1.0;
                Float64 target = MIN(3.0, duration * 0.4);
                if (self.index == 5) {
                    NSURL *URL = [NSBundle.mainBundle URLForResource:@"i-see-fire" withExtension:@"mp4"];
                    target = CMTimeGetSeconds([AVURLAsset URLAssetWithURL:URL options:nil].duration) - 0.4;
                }
                [self seek:target];
                self.phase = 5;
            }
            break;
        case 5:
            if (self.seekDone && position >= self.seekTarget + 0.65 && (!video || self.frames >= self.framesBeforeSeek + 5)) {
                self.checks[@"seek"] = @YES;
                if (self.index == 5) self.checks[@"segmentBoundary"] = @YES;
                SGPLFImage *image = video ? self.player.videoRenderer.currentImage : nil;
                self.screenshot = image != nil;
                if (video && !image) { [self finishCase:NO error:@"no video image after seek"]; return; }
                if (image) {
#if SGPLATFORM_TARGET_OS_MAC
                    NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc] initWithData:image.TIFFRepresentation];
                    NSData *data = [bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
#else
                    NSData *data = UIImagePNGRepresentation(image);
#endif
                    [data writeToURL:[self.directory URLByAppendingPathComponent:[NSString stringWithFormat:@"demo-case-%lu.png", (unsigned long)self.index]] atomically:YES];
                    [data writeToURL:[self.directory URLByAppendingPathComponent:@"sgplayer-device-smoke.png"] atomically:YES];
                }
                [self seek:MAX(0.0, duration - 0.7)];
                self.phase = 6;
            }
            break;
        case 6:
            if (self.seekDone && (self.player.sstateInfo.playback & SGPlaybackStateFinished)) {
                self.checks[@"endOfFile"] = @YES;
                [self finishCase:YES error:@""];
            }
            break;
    }
}

- (void)finishCase:(BOOL)passed error:(NSString *)error
{
    NSDictionary *entry = @{@"name": self.items[self.index].name, @"passed": @(passed), @"checks": self.checks.copy,
                            @"renderedFrames": @(self.frames), @"hardwareFrames": @(self.hardwareFrames),
                            @"screenshot": @(self.screenshot), @"error": error, @"phase": @(self.phase)};
    [self.results addObject:entry];
    NSLog(@"SGPLAYER_DEMO_CASE_%@: %@", passed ? @"PASS" : @"FAIL", entry);
    [self.player replaceWithPlayerItem:nil];
    self.index++;
    if (self.index < self.items.count) { [self beginCase]; return; }
    [self.timer invalidate];
    self.timer = nil;
    BOOL allPassed = YES;
    NSUInteger frames = 0, hardware = 0;
    for (NSDictionary *entry in self.results) { allPassed &= [entry[@"passed"] boolValue]; frames += [entry[@"renderedFrames"] unsignedIntegerValue]; hardware += [entry[@"hardwareFrames"] unsignedIntegerValue]; }
    NSString *runID = @"";
    for (NSString *argument in NSProcessInfo.processInfo.arguments) if ([argument hasPrefix:@"--sgplayer-smoke-run="]) runID = [argument substringFromIndex:[@"--sgplayer-smoke-run=" length]];
    NSDictionary *report = @{@"passed": @(allPassed), @"runID": runID, @"ffmpegVersion": [NSString stringWithUTF8String:av_version_info()],
                             @"bundleIdentifier": NSBundle.mainBundle.bundleIdentifier, @"osVersion": NSProcessInfo.processInfo.operatingSystemVersionString,
                             @"renderedFrames": @(frames), @"hardwareFrames": @(hardware), @"cases": self.results.copy};
    NSData *data = [NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil];
    [data writeToURL:[self.directory URLByAppendingPathComponent:@"sgplayer-device-smoke.json"] atomically:YES];
    NSLog(@"SGPLAYER_ALL_DEMOS_%@", allPassed ? @"PASS" : @"FAIL");
    self.player.videoRenderer.frameOutput = nil;
    if (self.completion) self.completion(report);
    // Keep a moving picture after automation completes, rather than leaving a paused test frame.
    self.player.rate = 1.0;
    self.player.videoRenderer.displayMode = SGDisplayModePlane;
    [self.player replaceWithAsset:self.items.firstObject.asset];
    [self.player play];
}

@end
#endif
