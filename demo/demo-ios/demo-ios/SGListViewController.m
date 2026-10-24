//
//  SGListViewController.m
//  demo-ios
//
//  Created by Single on 2017/3/15.
//  Copyright © 2017年 single. All rights reserved.
//

#import "SGListViewController.h"
#import "SGPlayViewController.h"
#import "SGVideoItem.h"
#import "SGFeatureDemo.h"

@interface SGFeatureViewController : UIViewController
@property (nonatomic, strong) SGFeatureDemo *features;
@property (nonatomic) BOOL sessionControls;
@property (nonatomic) SGFeatureExportMode exportMode;
@end
@implementation SGFeatureViewController
- (void)viewDidLoad { [super viewDidLoad]; self.view.backgroundColor=UIColor.blackColor; self.features=[[SGFeatureDemo alloc]initWithView:self.view sessionControls:self.sessionControls exportMode:[NSProcessInfo.processInfo.arguments containsObject:@"--sgplayer-audio-export"]?SGFeatureExportAudio:[NSProcessInfo.processInfo.arguments containsObject:@"--sgplayer-transcode-demo"]?SGFeatureExportVideo:self.exportMode]; }
- (void)viewDidDisappear:(BOOL)animated { [super viewDidDisappear:animated]; [self.features close]; }
@end

@interface SGListViewController ()

@property (nonatomic, strong) NSArray<SGVideoItem *> *videoItems;

@end

@implementation SGListViewController

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.videoItems = [SGVideoItem videoItems];
}

- (void)viewWillDisappear:(BOOL)animated
{
    [super viewWillDisappear:animated];
    [self.navigationController setNavigationBarHidden:YES animated:YES];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    [self.navigationController setNavigationBarHidden:NO animated:YES];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
    return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    return self.videoItems.count+4;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell * cell = [tableView dequeueReusableCellWithIdentifier:@"cell"];
    cell.textLabel.text = indexPath.row == self.videoItems.count+3 ? @"音频导出 / Export audio" : indexPath.row == self.videoItems.count+2 ? @"视频导出 / Export video" : indexPath.row == self.videoItems.count+1 ? @"播放会话 / Playback session" : indexPath.row == self.videoItems.count ? @"全部功能 / All features" : self.videoItems[indexPath.row].name;
    cell.accessibilityIdentifier = indexPath.row == self.videoItems.count+3 ? @"audio-export.open" : indexPath.row == self.videoItems.count+2 ? @"transcode.open" : indexPath.row == self.videoItems.count+1 ? @"session.open" : indexPath.row == self.videoItems.count ? @"feature.open" : [NSString stringWithFormat:@"demo.%ld",(long)indexPath.row];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (indexPath.row >= self.videoItems.count) { SGFeatureViewController *controller=[SGFeatureViewController new];controller.sessionControls=indexPath.row==self.videoItems.count+1;controller.exportMode=indexPath.row==self.videoItems.count+3?SGFeatureExportAudio:indexPath.row==self.videoItems.count+2?SGFeatureExportVideo:SGFeatureExportNone;[self.navigationController pushViewController:controller animated:YES]; return; }
    SGPlayViewController *vc = [[SGPlayViewController alloc] init];
    vc.videoItem = self.videoItems[indexPath.row];
    [self.navigationController pushViewController:vc animated:YES];
}

@end
