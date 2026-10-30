#import <AppKit/AppKit.h>
#import <SGPlayer/SGPlayer.h>
#import <SGPlayer/SGPlaybackControls.h>
@interface SGPlaybackControls (VRValidation)
- (void)panVR:(NSPanGestureRecognizer *)gesture;
@end
@interface ValidationPan:NSPanGestureRecognizer
@property NSGestureRecognizerState simulatedState;
@property NSPoint delta;
@end
@implementation ValidationPan
- (NSGestureRecognizerState)state{return self.simulatedState;}
- (NSPoint)translationInView:(NSView *)view{return self.delta;}
@end
static BOOL spin(BOOL(^done)(void),double seconds){NSDate *end=[NSDate dateWithTimeIntervalSinceNow:seconds];while(!done()&&end.timeIntervalSinceNow>0){@autoreleasepool{[NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.02]];}}return done();}
static NSBitmapImageRep *frame(SGPlaybackController *c,NSString *name){NSBitmapImageRep *rep=[NSBitmapImageRep imageRepWithData:c.currentImage.TIFFRepresentation];NSCAssert(rep,@"Missing rendered VR image");[[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}]writeToFile:[@"/tmp/sg-vr-" stringByAppendingFormat:@"%@.png",name] atomically:YES];return rep;}
static double difference(NSBitmapImageRep *a,NSBitmapImageRep *b){double sum=0;for(int y=1;y<32;y++)for(int x=1;x<64;x++){NSColor *p=[[a colorAtX:x*a.pixelsWide/64 y:y*a.pixelsHigh/32]colorUsingColorSpace:NSColorSpace.deviceRGBColorSpace];NSColor *q=[[b colorAtX:x*b.pixelsWide/64 y:y*b.pixelsHigh/32]colorUsingColorSpace:NSColorSpace.deviceRGBColorSpace];sum+=fabs(p.redComponent-q.redComponent)+fabs(p.greenComponent-q.greenComponent)+fabs(p.blueComponent-q.blueComponent);}return sum/(31*63*3);}
int main(){@autoreleasepool{
[NSApplication sharedApplication];NSWindow *w=[[NSWindow alloc]initWithContentRect:NSMakeRect(100,100,720,360) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];[w makeKeyAndOrderFront:nil];
NSView *surface=[[NSView alloc]initWithFrame:w.contentView.bounds];[w.contentView addSubview:surface];
SGPlaybackController *c=[[SGPlaybackController alloc]initWithKernel:SGPlaybackKernelFFmpeg view:surface];SGPlaybackSession *session=[[SGPlaybackSession alloc]initWithController:c resumeStore:nil];session.kernelPolicy=SGKernelSelectionPolicyPreferFFmpeg;
SGPlaybackControls *controls=[[SGPlaybackControls alloc]initWithSession:session];controls.frame=surface.bounds;[surface addSubview:controls];[controls attachKeyboardToView:surface];
NSURL *url=[NSURL fileURLWithPath:[[[NSString stringWithUTF8String:__FILE__]stringByDeletingLastPathComponent]stringByAppendingPathComponent:@"../demo/demo-assset/google-help-vr.mp4"]];SGPlaybackRendition *r=[[SGPlaybackRendition alloc]initWithIdentifier:@"vr" title:@"360" URL:url];SGPlaybackItem *item=[[SGPlaybackItem alloc]initWithIdentifier:@"vr" title:@"360" renditions:@[r]];NSError *error=nil;
NSCAssert([session loadItems:@[item] startIndex:0 autoPlay:YES error:&error],@"VR source load failed %@",error);NSCAssert(spin(^BOOL{return c.presentedFrameCount>5;},20),@"No VR frames %@",c.error);[session pause];
__block BOOL sought=NO;[c seekToTime:CMTimeMake(10,1) completion:^(BOOL success){sought=success;}];NSCAssert(spin(^BOOL{return sought;},15),@"VR seek failed");spin(^BOOL{return NO;},.5);
NSBitmapImageRep *plane=frame(c,@"plane");SGVideoRenderer *renderer=c.ffmpegPlayer.videoRenderer;renderer.viewport.sensorEnable=NO;NSCAssert(renderer.viewport.degress==90,@"Default FOV should be 90 degrees");renderer.displayMode=SGDisplayModeVR;
NSUInteger count=c.presentedFrameCount;NSCAssert(spin(^BOOL{return c.presentedFrameCount>count+2;},5),@"VR projection did not redraw while paused");NSBitmapImageRep *vr=frame(c,@"sphere");
NSCAssert(difference(plane,vr)>.025,@"VR still matches a flat frame");CMTime time=c.currentTime;float volume=c.volume;
ValidationPan *pan=[ValidationPan new];pan.simulatedState=NSGestureRecognizerStateBegan;[controls panVR:pan];pan.delta=NSMakePoint(-360,0);pan.simulatedState=NSGestureRecognizerStateChanged;[controls panVR:pan];
NSCAssert(fabs(renderer.viewport.x-90)<.1,@"VR drag did not change yaw");count=c.presentedFrameCount;NSCAssert(spin(^BOOL{return c.presentedFrameCount>count+2;},5),@"VR yaw did not redraw");NSBitmapImageRep *yaw=frame(c,@"yaw90");
NSCAssert(difference(vr,yaw)>.025,@"Looking around did not change the 360 scene");NSCAssert(fabs(CMTimeGetSeconds(CMTimeSubtract(c.currentTime,time)))<.1&&c.volume==volume,@"VR drag changed transport or volume");
renderer.displayMode=SGDisplayModeVRBox;count=c.presentedFrameCount;NSCAssert(spin(^BOOL{return c.presentedFrameCount>count+2;},5),@"VRBox did not redraw");NSBitmapImageRep *box=frame(c,@"box");NSCAssert(difference(yaw,box)>.02,@"VRBox did not create two eye viewports");
printf("PASS actual 360 scene: plane/sphere difference %.3f, yaw difference %.3f, VRBox difference %.3f; drag preserves time/volume\n",difference(plane,vr),difference(vr,yaw),difference(yaw,box));[controls attachKeyboardToView:nil];[session close];[w orderOut:nil];
}return 0;}
