#import "AppDelegate.h"
#import "SGVideoItem.h"
#import "SGFeatureDemo.h"
#import <AVFoundation/AVFoundation.h>

@interface AppDelegate ()
@property (nonatomic,strong) SGFeatureDemo *features;
#if DEBUG
@property (nonatomic, strong) SGDemoPlaybackTest *demoTests;
#endif
@end

@implementation AppDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions
{
    [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback error:nil];
    return YES;
}
@end

@interface SGSceneDelegate : UIResponder <UIWindowSceneDelegate>
@property (nonatomic, strong) UIWindow *window;
@end

@implementation SGSceneDelegate
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)connectionOptions
{
    self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    BOOL featureMode=[NSProcessInfo.processInfo.arguments containsObject:@"--sgplayer-features"];
    BOOL smokeMode=[NSProcessInfo.processInfo.arguments containsObject:@"--sgplayer-smoke-test"];
    if (!featureMode && !smokeMode) self.window.rootViewController = [[UIStoryboard storyboardWithName:@"Main" bundle:nil] instantiateInitialViewController];
#if DEBUG
    BOOL testing = [NSProcessInfo.processInfo.arguments containsObject:@"--sgplayer-smoke-test"];
    if (testing) {
        self.window.rootViewController = [[UIViewController alloc] init];
        self.window.rootViewController.view.backgroundColor = UIColor.blackColor;
    }
#endif
    if (featureMode) { self.window.rootViewController=[[UIViewController alloc]init];self.window.rootViewController.view.backgroundColor=UIColor.blackColor; }
    [self.window makeKeyAndVisible];
    if (featureMode) { AppDelegate *delegate=(AppDelegate *)UIApplication.sharedApplication.delegate;delegate.features=[[SGFeatureDemo alloc]initWithView:self.window.rootViewController.view]; }
#if DEBUG
    if (testing) {
        AppDelegate *delegate = (AppDelegate *)UIApplication.sharedApplication.delegate;
        delegate.demoTests = [SGDemoPlaybackTest startInView:self.window.rootViewController.view completion:nil];
    }
#endif
}
@end
