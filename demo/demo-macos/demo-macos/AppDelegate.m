#import "AppDelegate.h"
#import "SGVideoItem.h"
#import "SGFeatureDemo.h"

@interface AppDelegate ()
@property (nonatomic, strong) SGFeatureDemo *features;
@property (nonatomic, strong) NSWindow *featureWindow;
#if DEBUG
@property (nonatomic, strong) NSWindow *testWindow;
@property (nonatomic, strong) SGDemoPlaybackTest *demoTests;
#endif
@end

@implementation AppDelegate
- (void)applicationDidFinishLaunching:(NSNotification *)notification
{
    NSMenuItem *menuItem=[[NSMenuItem alloc]initWithTitle:@"全部功能 / All features" action:@selector(openFeatures:) keyEquivalent:@"f"];
    menuItem.target=self;
    [NSApp.mainMenu.itemArray.firstObject.submenu addItem:menuItem];
    NSMenuItem *sessionItem=[[NSMenuItem alloc]initWithTitle:@"播放会话 / Playback session" action:@selector(openFeatures:) keyEquivalent:@"s"];sessionItem.target=self;sessionItem.tag=1;[NSApp.mainMenu.itemArray.firstObject.submenu addItem:sessionItem];
    NSMenuItem *exportItem=[[NSMenuItem alloc]initWithTitle:@"视频导出 / Export video" action:@selector(openFeatures:) keyEquivalent:@"e"];exportItem.target=self;exportItem.tag=2;[NSApp.mainMenu.itemArray.firstObject.submenu addItem:exportItem];
    NSMenuItem *audioItem=[[NSMenuItem alloc]initWithTitle:@"音频导出 / Export audio" action:@selector(openFeatures:) keyEquivalent:@"a"];audioItem.target=self;audioItem.tag=3;[NSApp.mainMenu.itemArray.firstObject.submenu addItem:audioItem];
    if ([NSProcessInfo.processInfo.arguments containsObject:@"--sgplayer-features"]) [self openFeatures:nil];
#if DEBUG
    if ([NSProcessInfo.processInfo.arguments containsObject:@"--sgplayer-smoke-test"]) {
        self.testWindow = [[NSWindow alloc] initWithContentRect:NSMakeRect(100, 100, 960, 540)
            styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable
            backing:NSBackingStoreBuffered defer:NO];
        self.testWindow.title = @"SGPlayer Demo Verification";
        [self.testWindow makeKeyAndOrderFront:nil];
        [NSApp activateIgnoringOtherApps:YES];
        self.demoTests = [SGDemoPlaybackTest startInView:self.testWindow.contentView completion:nil];
    }
#endif
}
- (void)openFeatures:(id)sender {
    [self.features close];
    [self.featureWindow close];
    self.featureWindow=[[NSWindow alloc]initWithContentRect:NSMakeRect(100,100,960,720) styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskResizable backing:NSBackingStoreBuffered defer:NO];
    self.featureWindow.title=@"SGPlayer All Features";
    [self.featureWindow makeKeyAndOrderFront:nil];
    BOOL advanced=[sender tag]==1||[NSProcessInfo.processInfo.arguments containsObject:@"--sgplayer-session-controls"];
    BOOL videoExport=[sender tag]==2||[NSProcessInfo.processInfo.arguments containsObject:@"--sgplayer-transcode-demo"];
    BOOL audioExport=[sender tag]==3||[NSProcessInfo.processInfo.arguments containsObject:@"--sgplayer-audio-export"];
    self.featureWindow.title=audioExport?@"SGPlayer Audio Export":videoExport?@"SGPlayer Video Export":advanced?@"SGPlayer Playback Session":@"SGPlayer All Features";
    self.features=[[SGFeatureDemo alloc]initWithView:self.featureWindow.contentView sessionControls:advanced exportMode:audioExport?SGFeatureExportAudio:videoExport?SGFeatureExportVideo:SGFeatureExportNone];
}
@end
