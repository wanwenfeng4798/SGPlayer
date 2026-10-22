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
    self.featureWindow=[[NSWindow alloc]initWithContentRect:NSMakeRect(100,100,960,720) styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskResizable backing:NSBackingStoreBuffered defer:NO];
    self.featureWindow.title=@"SGPlayer All Features";
    [self.featureWindow makeKeyAndOrderFront:nil];
    self.features=[[SGFeatureDemo alloc]initWithView:self.featureWindow.contentView];
}
@end
