#import "AppDelegate.h"
#import "SGVideoItem.h"

@interface AppDelegate ()
#if DEBUG
@property (nonatomic, strong) NSWindow *testWindow;
@property (nonatomic, strong) SGDemoPlaybackTest *demoTests;
#endif
@end

@implementation AppDelegate
- (void)applicationDidFinishLaunching:(NSNotification *)notification
{
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
@end
