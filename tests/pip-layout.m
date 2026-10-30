#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <SGPlayer/SGPlaybackSession.h>
static BOOL spin(BOOL(^done)(void),double seconds) {
    NSDate *end=[NSDate dateWithTimeIntervalSinceNow:seconds];
    while(!done() && end.timeIntervalSinceNow>0) { @autoreleasepool {
        NSEvent *event=nil;
        while((event=[NSApp nextEventMatchingMask:NSEventMaskAny untilDate:NSDate.date inMode:NSDefaultRunLoopMode dequeue:YES])) [NSApp sendEvent:event];
        [NSApp updateWindows];
        [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.02]];
    }}
    return done();
}
static BOOL logicOnly;
static NSSet *existingWindows;
static void RememberWindows(void) {
    NSArray *list=CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly,kCGNullWindowID));
    NSMutableSet *ids=[NSMutableSet set];for(NSDictionary *item in list)[ids addObject:item[(__bridge id)kCGWindowNumber]];existingWindows=ids;
}
static void CheckPiPWindow(NSView *media) {
if(logicOnly) { NSCAssert(media.window && [media.window.identifier isEqual:@"sgplayer.pictureInPicture"],@"Playback did not move to PiP panel"); return; }
NSArray *list=CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly,kCGNullWindowID));
BOOL captured=NO;
for(NSDictionary *d in list) {
NSString *name=[d[(__bridge id)kCGWindowOwnerName] lowercaseString];
if(![name containsString:@"画中画"]&&![name containsString:@"picture in picture"] && !([d[(__bridge id)kCGWindowOwnerPID] intValue]==NSProcessInfo.processInfo.processIdentifier && [d[(__bridge id)kCGWindowName] isEqual:@"画中画"]))continue;
if([existingWindows containsObject:d[(__bridge id)kCGWindowNumber]])continue;
NSString *window=[@"-l" stringByAppendingString:[d[(__bridge id)kCGWindowNumber] description]];
NSString *path=[NSTemporaryDirectory() stringByAppendingPathComponent:[NSUUID.UUID.UUIDString stringByAppendingPathExtension:@"png"]];
NSTask *task=[NSTask launchedTaskWithLaunchPath:@"/usr/sbin/screencapture" arguments:@[@"-x",@"-o",window,path]];NSCAssert(spin(^BOOL{return !task.running;},10),@"PiP capture timed out");
NSBitmapImageRep *rep=[NSBitmapImageRep imageRepWithData:[NSData dataWithContentsOfFile:path]];NSCAssert(rep,@"PiP capture failed");
fprintf(stderr,"CAPTURE own PiP window %s => %s\n",[d[(__bridge id)kCGWindowNumber] description].UTF8String,path.UTF8String);
NSRect videoRect=[media convertRect:media.bounds toView:nil];
CGFloat windowHeight=media.window.frame.size.height;
NSInteger y=(windowHeight-NSMinY(videoRect)-videoRect.size.height*.25)*rep.pixelsHigh/windowHeight;
y=MIN(rep.pixelsHigh-1,MAX(0,y));NSInteger left=-1,right=-1;
for(NSInteger x=0;x<rep.pixelsWide;x++){NSColor *p=[[rep colorAtX:x y:y]colorUsingColorSpace:NSColorSpace.deviceRGBColorSpace];if(p.alphaComponent>.99){if(left<0)left=x;right=x;}}
NSCAssert(left>=0&&right-left>100,@"Empty PiP window");
NSDictionary *bounds=d[(__bridge id)kCGWindowBounds];
NSString *region=[NSString stringWithFormat:@"-R%.0f,%.0f,%.0f,%.0f",[bounds[@"X"] doubleValue],[bounds[@"Y"] doubleValue],[bounds[@"Width"] doubleValue],[bounds[@"Height"] doubleValue]];
NSString *screenPath=[path stringByAppendingString:@".screen.png"];
NSTask *screen=[NSTask launchedTaskWithLaunchPath:@"/usr/sbin/screencapture" arguments:@[@"-x",region,screenPath]];NSCAssert(spin(^BOOL{return !screen.running;},10),@"Region capture timed out");
NSBitmapImageRep *composite=[NSBitmapImageRep imageRepWithData:[NSData dataWithContentsOfFile:screenPath]];
fprintf(stderr,"SCOPED_SCREEN %s dimensions=%ldx%ld window=%ldx%ld\n",screenPath.UTF8String,(long)composite.pixelsWide,(long)composite.pixelsHigh,(long)rep.pixelsWide,(long)rep.pixelsHigh);
if(composite && composite.pixelsWide==rep.pixelsWide && composite.pixelsHigh==rep.pixelsHigh)rep=composite;

for(NSNumber *x in @[@(left+6),@(right-6)]){NSColor *pixel=[[rep colorAtX:x.integerValue y:y]colorUsingColorSpace:NSColorSpace.deviceRGBColorSpace];printf("EDGE %ld R%.2f G%.2f B%.2f A%.2f\n",(long)x.integerValue,pixel.redComponent,pixel.greenComponent,pixel.blueComponent,pixel.alphaComponent);NSCAssert(pixel.blueComponent>.7&&pixel.redComponent<.3,@"PiP has a left/right gap or crop");}
NSInteger topY=(windowHeight-NSMinY(videoRect)-videoRect.size.height*.75)*rep.pixelsHigh/windowHeight;
topY=MIN(rep.pixelsHigh-1,MAX(0,topY));
for(NSNumber *x in @[@(left+6),@(right-6)]){NSColor *pixel=[[rep colorAtX:x.integerValue y:topY]colorUsingColorSpace:NSColorSpace.deviceRGBColorSpace];NSCAssert(pixel.redComponent>.7&&pixel.blueComponent<.3,@"PiP cropped the top of the video");}
[[NSFileManager defaultManager]removeItemAtPath:path error:nil];captured=YES;break;
}
NSCAssert(captured,@"No PiP window found");
}
int main(){@autoreleasepool{
NSDictionary *console=CFBridgingRelease(CGSessionCopyCurrentDictionary());
logicOnly=[NSProcessInfo.processInfo.environment[@"SG_PIP_LOGIC_ONLY"] boolValue];
if(!logicOnly && [console[@"CGSSessionScreenIsLocked"] boolValue]){fputs("BLOCKED: macOS is locked; unlock before visual PiP acceptance.\n",stderr);return 77;}
[NSApplication sharedApplication];[NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];[NSApp finishLaunching];
NSWindow *w=[[NSWindow alloc]initWithContentRect:NSMakeRect(80,80,500,360) styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskResizable|NSWindowStyleMaskMiniaturizable backing:NSBackingStoreBuffered defer:NO];w.title=@"SGPlayer PiP validation";
NSView *surface=[[NSView alloc]initWithFrame:w.contentView.bounds];surface.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable;[w.contentView addSubview:surface];[w makeKeyAndOrderFront:nil];[NSApp activateIgnoringOtherApps:YES];
BOOL ffmpeg=[NSProcessInfo.processInfo.environment[@"SG_PIP_KERNEL"] isEqual:@"ffmpeg"];
printf("BACKEND %s MODE %s\n",ffmpeg?"ffmpeg":"native",logicOnly?"lifecycle (no visual acceptance)":"visual");
SGPlaybackController *c=[[SGPlaybackController alloc]initWithKernel:ffmpeg?SGPlaybackKernelFFmpeg:SGPlaybackKernelNative view:surface];
SGPlaybackSession *s=[[SGPlaybackSession alloc]initWithController:c resumeStore:nil];s.kernelPolicy=ffmpeg?SGKernelSelectionPolicyPreferFFmpeg:SGKernelSelectionPolicyPreferNative;
NSURL *url=[NSURL fileURLWithPath:[[[NSString stringWithUTF8String:__FILE__] stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"fixtures/orientation.mp4"]];
SGPlaybackRendition *r=[[SGPlaybackRendition alloc]initWithIdentifier:@"main" title:@"Main" URL:url];SGPlaybackItem *i=[[SGPlaybackItem alloc]initWithIdentifier:@"test" title:@"Test" renditions:@[r]];
__block BOOL pipStopped=YES;CFAbsoluteTime startedAt=CFAbsoluteTimeGetCurrent();
c.pictureInPictureChanged=^(BOOL active,NSError *failure){if(!active)pipStopped=YES;fprintf(stderr,"PIP_EVENT active=%d elapsed=%.3f error=%s\n",active,CFAbsoluteTimeGetCurrent()-startedAt,failure.description.UTF8String);};
NSError *error=nil;NSCAssert([s loadItems:@[i] startIndex:0 autoPlay:YES error:&error],@"Load failed %@",error);
BOOL frames=spin(^BOOL{return c.presentedFrameCount>=5;},20);printf("FRAMES %d %lu POSSIBLE %d\n",frames,(unsigned long)c.presentedFrameCount,c.pictureInPictureController.pictureInPicturePossible);fflush(stdout);
RememberWindows();pipStopped=NO;BOOL requested=[c startPictureInPicture:&error];BOOL active=spin(^BOOL{return c.pictureInPictureActive;},8);printf("PIP_REQUEST %d ACTIVE %d ERROR %s\n",requested,active,error.description.UTF8String);fflush(stdout);
[[NSString stringWithFormat:@"%d",active]writeToFile:@"/tmp/sg-pip-repro-ready" atomically:YES encoding:NSUTF8StringEncoding error:nil];
spin(^BOOL{return NO;},3);
NSCAssert(frames && active && requested,@"PiP failed to start");
CMTime before=c.currentTime;NSCAssert(spin(^BOOL{return CMTimeGetSeconds(CMTimeSubtract(c.currentTime,before))>.3;},5),@"Playback stalled in PiP");
CheckPiPWindow(surface);puts(logicOnly?"PASS PiP source and playback lifecycle":"PASS PiP video fills both edges despite source view aspect mismatch");[c stopPictureInPicture];NSCAssert(spin(^BOOL{return pipStopped&&!c.pictureInPictureActive;},10),@"PiP stop timed out");spin(^BOOL{return NO;},.5);
for(AVLayerVideoGravity gravity in @[AVLayerVideoGravityResizeAspect,AVLayerVideoGravityResizeAspectFill,AVLayerVideoGravityResize]) {
[w makeKeyAndOrderFront:nil];[NSApp activateIgnoringOtherApps:YES];c.videoGravity=gravity;spin(^BOOL{return NO;},.5);RememberWindows();pipStopped=NO;NSCAssert([c startPictureInPicture:&error],@"PiP mode failed %@",error);NSCAssert(spin(^BOOL{return c.pictureInPictureActive;},5),@"PiP did not activate");spin(^BOOL{return NO;},2);
AVSampleBufferDisplayLayer *display=[c valueForKey:@"displayLayer"];
fprintf(stderr,"DISPLAY ready=%d hidden=%d opacity=%.2f parent=%d frame=%s prevent=%d\n",display.readyForDisplay,display.hidden,display.opacity,display.superlayer==surface.layer,NSStringFromRect(display.frame).UTF8String,display.preventsCapture);
if(!logicOnly) { NSTask *inlineShot=[NSTask launchedTaskWithLaunchPath:@"/usr/sbin/screencapture" arguments:@[@"-x",@"-o",[NSString stringWithFormat:@"-l%ld",(long)w.windowNumber],@"/tmp/sg-pip-inline-repeat.png"]];spin(^BOOL{return !inlineShot.running;},10); }
NSImage *frame=c.currentImage;NSBitmapImageRep *sourceRep=[NSBitmapImageRep imageRepWithData:frame.TIFFRepresentation];
NSString *sourcePath=[NSString stringWithFormat:@"/tmp/sg-pip-native-frame-%.0f.png",CMTimeGetSeconds(c.currentTime)];[[sourceRep representationUsingType:NSBitmapImageFileTypePNG properties:@{}]writeToFile:sourcePath atomically:YES];fprintf(stderr,"NATIVE_FRAME %s time %.3f\n",sourcePath.UTF8String,CMTimeGetSeconds(c.currentTime));
NSWindow *panel=surface.window;NSSize resized=[(id<NSWindowDelegate>)c windowWillResize:panel toSize:NSMakeSize(350,300)];[panel setFrame:NSMakeRect(panel.frame.origin.x,panel.frame.origin.y,resized.width,resized.height) display:YES];
spin(^BOOL{return NO;},.2);NSCAssert(fabs(surface.bounds.size.width/surface.bounds.size.height-4.0/3)<.03,@"PiP resize lost the video aspect ratio");
CheckPiPWindow(surface);[c stopPictureInPicture];NSCAssert(spin(^BOOL{return pipStopped&&!c.pictureInPictureActive;},10),@"PiP stop timed out");spin(^BOOL{return NO;},.5);NSCAssert(surface.superview==w.contentView && NSEqualRects(surface.frame,w.contentView.bounds),@"PiP failed to restore inline layout");}
c.videoGravity=AVLayerVideoGravityResizeAspect;
c.automaticPictureInPictureEnabled=YES;[w miniaturize:nil];NSCAssert(spin(^BOOL{return c.pictureInPictureActive;},10),@"Automatic PiP did not start on minimize");
puts("PASS automatic macOS PiP on window minimization");[c stopPictureInPicture];[w deminiaturize:nil];[s close];[w orderOut:nil];
}return 0;}
