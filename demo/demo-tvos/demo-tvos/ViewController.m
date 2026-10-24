//
//  ViewController.m
//  demo-tvos
//
//  Created by Single on 2018/11/5.
//  Copyright © 2018 Single. All rights reserved.
//

#import "ViewController.h"
#import <SGPlayer/SGPlayer.h>
#import "SGFeatureDemo.h"

@interface ViewController ()

@property (nonatomic, strong) SGFeatureDemo *features;
@property (nonatomic) NSUInteger demoMode;
@property (nonatomic, assign) BOOL seeking;
@property (nonatomic, strong) SGPlayer *player;

@end

@implementation ViewController

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.demoMode=[NSProcessInfo.processInfo.arguments containsObject:@"--sgplayer-audio-export"]?3:[NSProcessInfo.processInfo.arguments containsObject:@"--sgplayer-transcode-demo"]?2:[NSProcessInfo.processInfo.arguments containsObject:@"--sgplayer-session-controls"]?1:0;
    self.features=[[SGFeatureDemo alloc]initWithView:self.view sessionControls:self.demoMode==1 exportMode:self.demoMode==3?SGFeatureExportAudio:self.demoMode==2?SGFeatureExportVideo:SGFeatureExportNone];
}
- (void)pressesEnded:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    for(UIPress *press in presses)if(press.type==UIPressTypeMenu){
        [self.features close];for(UIView *view in [self.view.subviews copy])[view removeFromSuperview];
        self.demoMode=(self.demoMode+1)%4;self.features=[[SGFeatureDemo alloc]initWithView:self.view sessionControls:self.demoMode==1 exportMode:self.demoMode==3?SGFeatureExportAudio:self.demoMode==2?SGFeatureExportVideo:SGFeatureExportNone];return;
    }
    [super pressesEnded:presses withEvent:event];
}

#pragma mark - SGPlayer Notifications

- (void)infoChanged:(NSNotification *)notification
{
    SGTimeInfo time = [SGPlayer timeInfoFromUserInfo:notification.userInfo];
    SGStateInfo state = [SGPlayer stateInfoFromUserInfo:notification.userInfo];
    SGInfoAction action = [SGPlayer infoActionFromUserInfo:notification.userInfo];
    if (action & SGInfoActionTime) {
        NSLog(@"playback: %f, duration: %f, cached: %f",
              CMTimeGetSeconds(time.playback),
              CMTimeGetSeconds(time.duration),
              CMTimeGetSeconds(time.cached));
    }
    if (action & SGInfoActionState) {
        NSLog(@"player: %d, loading: %d, playback: %d, playing: %d, seeking: %d, finished: %d",
              (int)state.player, (int)state.loading, (int)state.playback,
              (int)(state.playback & SGPlaybackStatePlaying),
              (int)(state.playback & SGPlaybackStateSeeking),
              (int)(state.playback & SGPlaybackStateFinished));
    }
}

@end
