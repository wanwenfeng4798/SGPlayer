#import <AppKit/AppKit.h>
#import <SGPlayer/SGPlaybackControls.h>
#import <SGPlayer/SGPlaybackPresentation.h>
static BOOL spin(BOOL(^done)(void),double seconds){NSDate *end=[NSDate dateWithTimeIntervalSinceNow:seconds];while(!done()&&end.timeIntervalSinceNow>0)[NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.03]];return done();}
static NSView *find(NSView *v, NSString *identifier) { if ([v.accessibilityIdentifier isEqual:identifier]) return v;for(NSView *child in v.subviews){NSView *r=find(child,identifier);if(r)return r;}return nil;}
@interface SGPlaybackProbeController : SGPlaybackController
@property(nonatomic) NSUInteger seekCount;
@end
@implementation SGPlaybackProbeController
- (void)seekToTime:(CMTime)time completion:(void (^)(BOOL))completion { self.seekCount++; [super seekToTime:time completion:completion]; }
@end
@interface SGPlaybackControls (PreviewTest)
- (void)showTimelineFraction:(double)fraction;
@end
int main(){@autoreleasepool{
[NSApplication sharedApplication];[NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
NSWindow *w=[[NSWindow alloc]initWithContentRect:NSMakeRect(40,40,640,400) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
NSView *surface=[[NSView alloc]initWithFrame:w.contentView.bounds];surface.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable;[w.contentView addSubview:surface];[w makeKeyAndOrderFront:nil];
SGPlaybackProbeController *c=[[SGPlaybackProbeController alloc]initWithKernel:SGPlaybackKernelNative view:surface];SGPlaybackSession *s=[[SGPlaybackSession alloc]initWithController:c resumeStore:nil];s.kernelPolicy=SGKernelSelectionPolicyPreferNative;s.automaticAdvance=NO;
SGPlaybackControls *controls=[[SGPlaybackControls alloc]initWithSession:s];controls.frame=surface.bounds;[surface addSubview:controls];
NSURL *url=[NSURL fileURLWithPath:[[[NSString stringWithUTF8String:__FILE__] stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"fixtures/orientation.mp4"]];
SGPlaybackRendition *r=[[SGPlaybackRendition alloc]initWithIdentifier:@"main" title:@"Main" URL:url];SGPlaybackItem *item=[[SGPlaybackItem alloc]initWithIdentifier:@"content" title:@"Content" renditions:@[r]];
NSError *error=nil;NSCAssert([s loadItems:@[item] startIndex:0 autoPlay:YES error:&error],@"load failed %@",error);NSCAssert(spin(^BOOL{return s.state==SGPlaybackSessionStatePlaying&&CMTimeGetSeconds(c.currentTime)>.3;},20),@"no frames");
controls.controlsEnabled=NO;spin(^BOOL{return NO;},.5);NSCAssert(!controls.hidden&&!find(controls,@"session.play").hidden&&find(controls,@"session.progress").hidden,@"pure mode must preserve only play/pause");controls.controlsEnabled=YES;[controls revealControls];NSCAssert(!controls.hidden,@"pure mode cannot exit");
NSString *base=[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];[[NSFileManager defaultManager]createDirectoryAtPath:base withIntermediateDirectories:YES attributes:nil error:nil];
NSURL *xml=[NSURL fileURLWithPath:[base stringByAppendingPathComponent:@"test.xml"]];
[@"<i><d p=\"0,1,25,16711680\">A &amp; B</d><d p=\"1,5,30,255\"><![CDATA[顶部]]></d><d p=\"2,4,25,65280\">Bottom</d><d p=\"3,6,25,16777215\">Reverse</d><d p=\"4,7,25,0\">Advanced unsupported</d></i>" writeToURL:xml atomically:YES encoding:NSUTF8StringEncoding error:nil];
NSArray *danmaku=[SGDanmakuReader readURL:xml error:&error];NSCAssert(danmaku.count==4,@"XML parser %@",error);NSCAssert([((SGDanmakuItem *)danmaku[0]).text isEqual:@"A & B"]&&((SGDanmakuItem *)danmaku[0]).rgbColor==0xff0000,@"XML color/entity lost");NSCAssert(((SGDanmakuItem *)danmaku[3]).mode==SGDanmakuModeReverse,@"reverse mode lost");
__block BOOL ready=NO;[c loadDanmakuFromURL:xml completion:^(NSError *failure){NSCAssert(!failure,@"XML load %@",failure);ready=YES;}];NSCAssert(spin(^BOOL{return ready;},10)&&c.effects.danmaku.count==4,@"native XML load incomplete");
NSBitmapImageRep *sprite=[[NSBitmapImageRep alloc]initWithBitmapDataPlanes:NULL pixelsWide:64 pixelsHigh:32 bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:256 bitsPerPixel:32];
for(int y=0;y<32;y++)for(int x=0;x<64;x++)[sprite setColor:[NSColor colorWithDeviceRed:x<32?1:0 green:0 blue:x<32?0:1 alpha:1] atX:x y:y];
[[sprite representationUsingType:NSBitmapImageFileTypePNG properties:@{}]writeToFile:[base stringByAppendingPathComponent:@"sprite.png"] atomically:YES];
NSURL *vtt=[NSURL fileURLWithPath:[base stringByAppendingPathComponent:@"preview.vtt"]];[@"WEBVTT\n\n00:00:00.000 --> 00:00:01.000\nsprite.png#xywh=0,0,32,32\n\n00:00:01.000 --> 00:00:10.000\nsprite.png#xywh=32,0,32,32\n" writeToURL:vtt atomically:YES encoding:NSUTF8StringEncoding error:nil];
ready=NO;[controls loadTimelineSpritesFromURL:vtt completion:^(NSError *failure){NSCAssert(!failure,@"VTT source %@",failure);ready=YES;}];NSCAssert(spin(^BOOL{return ready;},10),@"preview source timeout");
for(int region=0;region<2;region++){ready=NO;[controls timelineImageAtTime:CMTimeMake(region?15:5,10) completion:^(NSImage *image,NSError *failure){NSCAssert(image&&!failure,@"preview image %@",failure);NSBitmapImageRep *rep=[NSBitmapImageRep imageRepWithData:image.TIFFRepresentation];NSColor *color=[[rep colorAtX:16 y:16]colorUsingColorSpace:NSColorSpace.deviceRGBColorSpace];NSCAssert(region?color.blueComponent>.9&&color.redComponent<.1:color.redComponent>.9&&color.blueComponent<.1,@"wrong VTT crop");ready=YES;}];NSCAssert(spin(^BOOL{return ready;},10),@"preview request timeout");}
[controls showTimelineFraction:.02];NSCAssert(spin(^BOOL{return find(controls,@"session.timelinePreview")&&!find(controls,@"session.timelinePreview").hidden;},10),@"scrub preview not visible");NSCAssert(NSContainsRect(controls.bounds,find(controls,@"session.timelinePreview").frame),@"preview clipped");
[[NSFileManager defaultManager]removeItemAtPath:base error:nil];
puts("PASS XML modes/color/entities, native async XML loading, WebVTT relative sprite crops and visible scrub preview");
NSCAssert([c.videoGravity isEqual:AVLayerVideoGravityResizeAspect],@"initial scaling");
[(NSButton *)find(controls,@"session.scale") performClick:nil];NSCAssert([c.videoGravity isEqual:AVLayerVideoGravityResizeAspectFill],@"scale menu did not apply fill");
[(NSButton *)find(controls,@"session.scale") performClick:nil];NSCAssert([c.videoGravity isEqual:AVLayerVideoGravityResize],@"scale menu did not apply stretch");
[(NSButton *)find(controls,@"session.scale") performClick:nil];
[(NSButton *)find(controls,@"session.mirror") performClick:nil];NSCAssert(c.effects.filter.horizontalFlip,@"mirror menu did not apply effect");[(NSButton *)find(controls,@"session.mirror") performClick:nil];
[(NSButton *)find(controls,@"session.loop") performClick:nil];NSCAssert(s.loopMode==SGPlaybackLoopModeOne,@"loop menu did not apply policy");s.loopMode=SGPlaybackLoopModeNone;
__block BOOL screenshot=NO;controls.screenshotCaptured=^(NSImage *image){screenshot=image!=nil;};[controls refresh];[(NSButton *)find(controls,@"session.screenshot") performClick:nil];NSCAssert(screenshot,@"screenshot menu callback missing");
[(NSButton *)find(controls,@"session.purePlay") performClick:nil];NSCAssert(!controls.controlsEnabled&&!controls.hidden&&find(controls,@"session.settings").hidden,@"pure menu must preserve play/pause");controls.controlsEnabled=YES;[controls revealControls];
[(NSButton *)find(controls,@"session.keepLastFrame") performClick:nil];NSCAssert(controls.keepLastFrameWhenComplete,@"last-frame menu ignored");controls.keepLastFrameWhenComplete=NO;
[controls setCoverImage:c.currentImage forView:surface];[(NSButton *)find(controls,@"session.cover") performClick:nil];NSCAssert(!controls.coverEnabled,@"cover menu ignored");[(NSButton *)find(controls,@"session.cover") performClick:nil];NSCAssert(controls.coverEnabled,@"cover menu cannot restore");
puts("PASS native settings scale/mirror/loop/screenshot/pure/cover/last-frame actions");
NSSlider *seek=(NSSlider *)find(controls,@"session.progress");
NSPoint click=[seek convertPoint:NSMakePoint(seek.bounds.size.width*.25,seek.bounds.size.height/2) toView:nil];
NSTimeInterval stamp=NSProcessInfo.processInfo.systemUptime;
NSEvent *down=[NSEvent mouseEventWithType:NSEventTypeLeftMouseDown location:click modifierFlags:0 timestamp:stamp windowNumber:w.windowNumber context:nil eventNumber:1 clickCount:1 pressure:1];
NSEvent *up=[NSEvent mouseEventWithType:NSEventTypeLeftMouseUp location:click modifierFlags:0 timestamp:stamp+.1 windowNumber:w.windowNumber context:nil eventNumber:2 clickCount:1 pressure:0];
NSUInteger beforeSeeks=c.seekCount;[NSApp postEvent:up atStart:YES];[seek mouseDown:down];
NSCAssert(c.seekCount==beforeSeeks+1,@"Seek gesture did not commit exactly once");
NSCAssert(spin(^BOOL{return CMTimeGetSeconds(c.currentTime)>10;},10),@"Seek gesture did not reach native playback");
puts("PASS native seek mouse gesture commits once after tracking");
__block BOOL dismissed=NO;controls.dismissPresentation=^{dismissed=YES;};controls.controlsEnabled=NO;
NSEvent *escape=[NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:0 timestamp:stamp windowNumber:w.windowNumber context:nil characters:@"\x1b" charactersIgnoringModifiers:@"\x1b" isARepeat:NO keyCode:53];
NSCAssert([controls handleKeyEvent:escape]&&dismissed&&!controls.hidden,@"Pure playback traps fullscreen Escape");controls.controlsEnabled=YES;[controls revealControls];


BOOL originalSubtitles=c.effects.subtitlesEnabled;c.effects.danmakuEnabled=YES;
double contentTime=CMTimeGetSeconds(c.currentTime);NSCAssert([s playAdvertisementWithURL:url skipAfter:.4],@"ad rejected");NSCAssert(s.advertisementActive&&!s.canSkipAdvertisement&&![s skipAdvertisement],@"skip bypassed delay");
NSCAssert(spin(^BOOL{return s.canSkipAdvertisement;},20),@"ad never skippable %@",s.error);[controls refresh];NSCAssert(!find(controls,@"session.skipAd").hidden,@"missing skip button");NSCAssert([s skipAdvertisement],@"skip failed");NSCAssert(spin(^BOOL{return !s.advertisementActive&&s.state==SGPlaybackSessionStatePlaying;},20),@"content not resumed");NSCAssert(s.selectedIndex==0&&s.selectedRendition==0,@"playlist corrupted");NSCAssert(fabs(CMTimeGetSeconds(c.currentTime)-contentTime)<.5,@"content position lost");NSCAssert(c.effects.subtitlesEnabled==originalSubtitles&&c.effects.danmakuEnabled,@"effects not restored");
s.advertisements=@[[[SGPlaybackAdvertisement alloc]initWithURL:url atTime:CMTimeAdd(c.currentTime,CMTimeMake(3,10)) skipAfter:0]];NSCAssert(spin(^BOOL{return s.advertisementActive;},5),@"midroll not fired");NSCAssert(spin(^BOOL{return s.canSkipAdvertisement;},20)&&[s skipAdvertisement],@"midroll not skippable");NSCAssert(spin(^BOOL{return s.state==SGPlaybackSessionStatePlaying;},20),@"midroll restore failed");spin(^BOOL{return NO;},.5);NSCAssert(!s.advertisementActive,@"midroll fired twice");
[s pause];NSCAssert([s playAdvertisementWithURL:url skipAfter:0],@"paused ad rejected");NSCAssert(spin(^BOOL{return s.canSkipAdvertisement;},20)&&[s skipAdvertisement],@"paused ad skip failed");NSCAssert(spin(^BOOL{return s.state==SGPlaybackSessionStatePaused;},20)&&!c.playing,@"paused content resumed unexpectedly");
NSCAssert([s playPreRollAdvertisementWithURL:url skipAfter:0],@"preroll rejected");NSCAssert(spin(^BOOL{return s.canSkipAdvertisement;},20)&&[s skipAdvertisement],@"preroll skip failed");NSCAssert(spin(^BOOL{return s.state==SGPlaybackSessionStatePlaying;},20)&&CMTimeGetSeconds(c.currentTime)<.2,@"preroll did not start content from zero");[s pause];
// Malformed ads restore content instead of leaving an endless spinner.
NSCAssert([s playAdvertisementWithURL:[NSURL fileURLWithPath:@"/tmp/nonexistent-sg-ad.mp4"] skipAfter:0],@"failed ad not attempted");NSCAssert(spin(^BOOL{return !s.advertisementActive&&s.state==SGPlaybackSessionStatePaused;},20),@"failed ad did not restore content %@",s.error);
SGPlaybackCover *cover=[[SGPlaybackCover alloc]initWithSession:s view:surface image:nil];[s setValue:@(SGPlaybackSessionStateEnded) forKey:@"state"];[cover refresh];NSCAssert(cover.visible,@"ended black cover missing");cover.keepLastFrameWhenComplete=YES;[cover refresh];NSCAssert(!cover.visible,@"last frame obscured");[cover close];
puts("PASS native pure mode, preroll gating/skip, midroll once, return position/paused intent, ad failure, cover/last frame");[s close];[w orderOut:nil];
}return 0;}
