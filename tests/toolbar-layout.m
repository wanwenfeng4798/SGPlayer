#import <AppKit/AppKit.h>
#import <SGPlayer/SGPlaybackControls.h>
static NSView *find(NSView *v, NSString *identifier) {
    if ([v.accessibilityIdentifier isEqual:identifier]) return v;
    for (NSView *child in v.subviews) { NSView *match=find(child,identifier); if(match)return match; }
    return nil;
}
int main(void) { @autoreleasepool {
    [NSApplication sharedApplication];
    SGPlaybackController *player=[[SGPlaybackController alloc] initWithKernel:SGPlaybackKernelNative view:[NSView new]];
    SGPlaybackSession *session=[[SGPlaybackSession alloc] initWithController:player resumeStore:nil];
    SGPlaybackControls *controls=[[SGPlaybackControls alloc] initWithSession:session];
    for (NSNumber *width in @[@240,@280,@360,@720,@1280]) {
        controls.frame=NSMakeRect(0,0,width.doubleValue,240); [controls refresh];
        for (NSString *identifier in @[@"session.play",@"session.progress",@"session.status",@"session.speed",@"session.settings",@"session.volume",@"session.lock",@"session.fullscreen"]) {
            NSView *view=find(controls,identifier);
            NSCAssert(view && !view.hidden,@"Missing %@ at width %@",identifier,width);
            NSCAssert(NSContainsRect(controls.bounds,view.frame),@"Clipped %@ %@ at width %@",identifier,NSStringFromRect(view.frame),width);
        }
        controls.controlsLocked=YES;
        NSCAssert(find(controls,@"session.play").hidden && !find(controls,@"session.lock").hidden,@"Lock must hide toolbar and preserve unlock");
        controls.controlsLocked=NO;
    }
    [(NSButton *)find(controls,@"session.volume") performClick:nil];
    NSSlider *volume=(NSSlider *)find(controls,@"session.volume.slider");
    NSCAssert(!volume.isHiddenOrHasHiddenAncestor,@"Volume panel did not open");
    volume.doubleValue=.25; [NSApp sendAction:volume.action to:volume.target from:volume];
    NSCAssert(fabs(player.volume-.25)<.01,@"Volume slider did not update native player");
    puts("PASS native toolbar widths 240/280/360/720/1280, lock/unlock, volume slider");
    [session close];
} return 0; }
