#import <AppKit/AppKit.h>
#import <SGPlayer/SGPlaybackControls.h>
static NSView *find(NSView *v, NSString *identifier) {
    if ([v.accessibilityIdentifier isEqual:identifier]) return v;
    for (NSView *child in v.subviews) { NSView *match=find(child,identifier); if(match)return match; }
    return nil;
}
@interface SGPlaybackControls (Validation)
- (NSArray<NSNumber *> *)settingsActions;
- (NSArray<NSNumber *> *)moreSettingsActions;
- (NSMenu *)settingsMenuForActions:(NSArray<NSNumber *> *)actions;
@end
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
        NSCAssert(fabs(NSMidY(find(controls,@"session.status").frame)-NSMidY(find(controls,@"session.progress").frame))<.5,@"Time label is not centered on seek track");
        NSCAssert(fabs(NSMidY([[controls valueForKey:@"durationLabel"] frame])-NSMidY(find(controls,@"session.progress").frame))<.5,@"Duration is not centered on seek track");
        controls.controlsLocked=YES;
        NSCAssert(find(controls,@"session.play").hidden && !find(controls,@"session.lock").hidden,@"Lock must hide toolbar and preserve unlock");
        controls.controlsLocked=NO;
    }
    controls.progressColorARGB=0xff00ff00;controls.volumeColorARGB=0xff0000ff;[controls refresh];
    NSColor *seekColor=[[(NSSlider *)find(controls,@"session.progress") cell]valueForKey:@"fillColor"];
    NSCAssert(seekColor.greenComponent>.99&&seekColor.redComponent<.01,@"Progress color was not applied");
    [(NSButton *)find(controls,@"session.volume") performClick:nil];
    NSSlider *volume=(NSSlider *)find(controls,@"session.volume.slider");
    NSCAssert(!volume.isHiddenOrHasHiddenAncestor,@"Volume panel did not open");
    NSCAssert(volume.isVertical && volume.frame.size.height>volume.frame.size.width,@"Volume must be vertical");
    NSCAssert(![[controls settingsActions]containsObject:@15] && [[controls moreSettingsActions]containsObject:@15],@"Advanced source loading must be in More Settings");
    NSMenu *more=[controls settingsMenuForActions:[controls moreSettingsActions]];
    NSCAssert(more.numberOfItems>0 && [more itemWithTag:15],@"Advanced settings missing native action");
    controls.controlsEnabled=NO;[controls refresh];
    NSCAssert(!controls.hidden&&!find(controls,@"session.play").hidden&&find(controls,@"session.settings").hidden,@"Pure mode lost play/pause");
    controls.controlsEnabled=YES;
    NSColor *volumeColor=[volume.cell valueForKey:@"fillColor"];
    NSCAssert(volumeColor.blueComponent>.99&&volumeColor.redComponent<.01,@"Volume color was not applied");
    volume.doubleValue=.25; [NSApp sendAction:volume.action to:volume.target from:volume];
    NSCAssert(fabs(player.volume-.25)<.01,@"Volume slider did not update native player");
    puts("PASS native toolbar widths 240/280/360/720/1280, lock/unlock, volume slider");
    [session close];
} return 0; }
