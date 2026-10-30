#import <XCTest/XCTest.h>
#import <TargetConditionals.h>
#if TARGET_OS_OSX
#import <AppKit/AppKit.h>
@import Carbon;
#else
#import <UIKit/UIKit.h>
#endif

@interface SGFeatureUITests : XCTestCase
@property (nonatomic,strong) XCUIApplication *app;
@end
@implementation SGFeatureUITests
- (void)setUp {
    [super setUp];self.continueAfterFailure=NO;
    self.app=[[XCUIApplication alloc]init];self.app.launchArguments=@[@"--sgplayer-features"];
#if TARGET_OS_OSX
    NSString *output=[NSTemporaryDirectory() stringByAppendingPathComponent:[@"SGPlayerUI-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    [XCTContext runActivityNamed:[@"SGPLAYER_UI_OUTPUT=" stringByAppendingString:output] block:^(id<XCTActivity> activity) {}];
    self.app.launchArguments=[self.app.launchArguments arrayByAddingObject:[@"--sgplayer-test-output=" stringByAppendingString:output]];
#endif
    [self.app launch];
    XCTAssertTrue([self.app.buttons[@"feature.play"] waitForExistenceWithTimeout:30]);
    [self waitForFrames:5];
}
- (void)tearDown {[self.app terminate];[super tearDown];}
- (NSString *)status {
    XCUIElement *label=self.app.staticTexts[@"feature.status"];
    NSString *value=label.label;
    if (!value.length && [label.value isKindOfClass:NSString.class])value=label.value;
    return value?:@"";
}
- (void)waitForStatusContaining:(NSString *)text timeout:(NSTimeInterval)timeout {
    NSPredicate *predicate=[NSPredicate predicateWithBlock:^BOOL(id object,NSDictionary *bindings){return [[self status] containsString:text];}];
    XCTNSPredicateExpectation *expectation=[[XCTNSPredicateExpectation alloc]initWithPredicate:predicate object:self.app];
    XCTAssertEqual([XCTWaiter waitForExpectations:@[expectation] timeout:timeout],XCTWaiterResultCompleted,@"Status: %@",self.status);
}
- (void)waitForFrames:(NSUInteger)minimum {
    NSPredicate *predicate=[NSPredicate predicateWithBlock:^BOOL(id object,NSDictionary *bindings){
        NSRegularExpression *regex=[NSRegularExpression regularExpressionWithPattern:@"([0-9]+) frames" options:0 error:nil];
        NSString *status=self.status;NSTextCheckingResult *match=[regex firstMatchInString:status options:0 range:NSMakeRange(0,status.length)];
        return match && [[status substringWithRange:[match rangeAtIndex:1]] integerValue]>=(NSInteger)minimum;
    }];
    XCTNSPredicateExpectation *expectation=[[XCTNSPredicateExpectation alloc]initWithPredicate:predicate object:self.app];
    XCTAssertEqual([XCTWaiter waitForExpectations:@[expectation] timeout:30],XCTWaiterResultCompleted,@"No rendered frames: %@",self.status);
}
- (void)waitForIdle {
    NSPredicate *predicate=[NSPredicate predicateWithBlock:^BOOL(id object,NSDictionary *bindings){return ![[self status] containsString:@"Working"];}];
    XCTNSPredicateExpectation *expectation=[[XCTNSPredicateExpectation alloc]initWithPredicate:predicate object:self.app];
    XCTAssertEqual([XCTWaiter waitForExpectations:@[expectation] timeout:60],XCTWaiterResultCompleted,@"Status: %@",self.status);
}
- (void)press:(NSString *)name {
    XCUIElement *button=self.app.buttons[[@"feature." stringByAppendingString:name]];
    XCTAssertTrue([button waitForExistenceWithTimeout:5]);
#if TARGET_OS_OSX
    [button click];
#elif TARGET_OS_TV
    NSArray *actions=@[@"play",@"pause",@"seek",@"kernel",@"subtitles",@"danmaku",@"watermark",@"filter",@"sticker",@"pip",@"export",@"stop",@"source",@"vr",@"rate",@"screenshot"];
    NSInteger target=[actions indexOfObject:name];
    for (NSUInteger attempt=0;attempt<20 && !button.hasFocus;attempt++) {
        NSInteger current=-1;
        for (NSUInteger i=0;i<actions.count;i++) if (self.app.buttons[[@"feature." stringByAppendingString:actions[i]]].hasFocus) {current=i;break;}
        XCUIRemoteButton direction=XCUIRemoteButtonUp;
        if(current>=0) {
            if(current/4<target/4)direction=XCUIRemoteButtonDown;
            else if(current/4>target/4)direction=XCUIRemoteButtonUp;
            else if(current%4<target%4)direction=XCUIRemoteButtonRight;
            else direction=XCUIRemoteButtonLeft;
        }
        [[XCUIRemote sharedRemote]pressButton:direction];
    }
    XCTAssertTrue(button.hasFocus,@"Cannot focus %@",name);
    [[XCUIRemote sharedRemote]pressButton:XCUIRemoteButtonSelect];
#else
    XCTAssertTrue(button.isHittable,@"%@ must be reachable",name);[button tap];
#endif
    [self waitForIdle];
}
- (void)attach:(NSString *)name {
    XCTAttachment *attachment=[XCTAttachment attachmentWithScreenshot:self.app.screenshot];attachment.name=name;attachment.lifetime=XCTAttachmentLifetimeKeepAlways;[self addAttachment:attachment];
}
- (double)seconds {
    NSArray *parts=[self.status componentsSeparatedByString:@"|"];
    return parts.count>1?[parts[1] doubleValue]:-1;
}
- (void)pressSession:(NSString *)name {
#if !TARGET_OS_TV
    NSDictionary *menuTitles=@{@"back":@"后退 10 秒",@"forward":@"前进 10 秒",@"previous":@"上一集",@"next":@"下一集",@"kernel":@"播放内核",@"audio":@"切换音轨",@"subtitles":@"切换字幕",@"quality":@"切换清晰度",@"retry":@"重新加载",@"pip":@"画中画",@"floating":@"悬浮播放"};
    if(menuTitles[name]) {
        XCUIElement *settings=self.app.buttons[@"session.settings"];
        XCTAssertTrue([settings waitForExistenceWithTimeout:10]);
#if TARGET_OS_OSX
        [settings click];XCUIElement *item=self.app.menuItems[menuTitles[name]];
        XCTAssertTrue([item waitForExistenceWithTimeout:5]);[item click];
#else
        [settings tap];XCUIElement *item=self.app.buttons[menuTitles[name]];
        XCTAssertTrue([item waitForExistenceWithTimeout:5]);[item tap];
#endif
        return;
    }
#endif
    XCUIElement *button=self.app.buttons[[@"session." stringByAppendingString:name]];XCTAssertTrue([button waitForExistenceWithTimeout:10]);
#if TARGET_OS_OSX
    [button click];
#elif TARGET_OS_TV
    NSArray *actions=@[@"play",@"back",@"forward",@"previous",@"next",@"kernel",@"audio",@"subtitles",@"quality",@"speed",@"retry",@"lock",@"pip",@"fullscreen",@"floating"];
    NSInteger target=[actions indexOfObject:name];
    for(NSUInteger attempt=0;attempt<24&&!button.hasFocus;attempt++){
        NSInteger current=-1;for(NSUInteger i=0;i<actions.count;i++)if(self.app.buttons[[@"session." stringByAppendingString:actions[i]]].hasFocus){current=i;break;}
        XCUIRemoteButton direction=XCUIRemoteButtonUp;
        if(target!=NSNotFound&&current>=0){
            NSInteger waypoint=(current/4)*4+target%4;
            BOOL canAlign=waypoint<(NSInteger)actions.count&&self.app.buttons[[@"session." stringByAppendingString:actions[waypoint]]].enabled;
            if(current%4!=target%4&&canAlign)direction=current%4<target%4?XCUIRemoteButtonRight:XCUIRemoteButtonLeft;
            else if(current/4<target/4)direction=XCUIRemoteButtonDown;
            else if(current/4>target/4)direction=XCUIRemoteButtonUp;
            else direction=current%4<target%4?XCUIRemoteButtonRight:XCUIRemoteButtonLeft;
        }
        [[XCUIRemote sharedRemote]pressButton:direction];
    }
    XCTAssertTrue(button.hasFocus,@"Cannot focus session %@",name);[[XCUIRemote sharedRemote]pressButton:XCUIRemoteButtonSelect];
#else
    XCTAssertTrue(button.isHittable);[button tap];
#endif
}
- (void)waitForSession:(NSString *)text {
    #if TARGET_OS_TV
    XCUIElement *label=self.app.staticTexts[@"session.status"];
#else
    XCUIElement *label=self.app.staticTexts[@"session.diagnostics"];
#endif
    NSPredicate *predicate=[NSPredicate predicateWithBlock:^BOOL(id object,NSDictionary *bindings){NSString *value=label.label.length?label.label:label.value;return [value containsString:text];}];
    XCTNSPredicateExpectation *expectation=[[XCTNSPredicateExpectation alloc]initWithPredicate:predicate object:label];
    XCTAssertEqual([XCTWaiter waitForExpectations:@[expectation] timeout:35],XCTWaiterResultCompleted,@"Session: %@",label.label);
}
#if !TARGET_OS_TV
- (void)waitForSessionTime:(double)target tolerance:(double)tolerance {
    __block NSString *lastStatus=@"unavailable";
    NSPredicate *predicate=[NSPredicate predicateWithBlock:^BOOL(id object,NSDictionary *bindings){
        #if TARGET_OS_TV
    XCUIElement *label=self.app.staticTexts[@"session.status"];
#else
    XCUIElement *label=self.app.staticTexts[@"session.diagnostics"];
#endif
        if (!label.exists)return NO;
        NSString *value=label.label.length?label.label:label.value;
        lastStatus=value?:@"";
        NSRegularExpression *regex=[NSRegularExpression regularExpressionWithPattern:@"([0-9.]+) /" options:0 error:nil];
        NSTextCheckingResult *match=[regex firstMatchInString:value options:0 range:NSMakeRange(0,value.length)];
        return match && fabs([[value substringWithRange:[match rangeAtIndex:1]]doubleValue]-target)<tolerance;
    }];
    XCTNSPredicateExpectation *expectation=[[XCTNSPredicateExpectation alloc]initWithPredicate:predicate object:self.app];
    XCTAssertEqual([XCTWaiter waitForExpectations:@[expectation]timeout:15],XCTWaiterResultCompleted,@"Session time: %@",lastStatus);
}
- (void)testAccessibleProgressAdjustment {
    [self.app terminate];self.app.launchArguments=[self.app.launchArguments arrayByAddingObjectsFromArray:@[@"--sgplayer-session-controls",@"--sgplayer-no-resume"]];[self.app launch];
    [self waitForSession:@"Playing"];[self pressSession:@"play"];[self waitForSession:@"Paused"];
    [self.app.sliders[@"session.progress"]adjustToNormalizedSliderPosition:.5];[self attach:@"adjusted-progress-half"];
    // XCTest promises a best-effort drag, so verify movement and the actual media position.
    CGFloat firstPosition=self.app.sliders[@"session.progress"].normalizedSliderPosition;
    XCTAssertGreaterThan(firstPosition,.25);XCTAssertLessThan(firstPosition,.75);
    [self waitForSessionTime:59.9*self.app.sliders[@"session.progress"].normalizedSliderPosition tolerance:1];[self waitForSession:@"Paused"];
    [self pressSession:@"kernel"];[self waitForSession:@"Native"];[self waitForSession:@"Paused"];[self waitForSessionTime:59.9*firstPosition tolerance:1];
    [self.app.sliders[@"session.progress"]adjustToNormalizedSliderPosition:.75];
    XCTAssertGreaterThan(self.app.sliders[@"session.progress"].normalizedSliderPosition,firstPosition+.1);
    [self waitForSessionTime:59.9*self.app.sliders[@"session.progress"].normalizedSliderPosition tolerance:1];[self waitForSession:@"Paused"];[self attach:@"accessible-progress-both-kernels"];
}
- (void)testLongSliderTracking {
    [self.app terminate];self.app.launchArguments=[self.app.launchArguments arrayByAddingObjectsFromArray:@[@"--sgplayer-session-controls",@"--sgplayer-no-resume",@"--sgplayer-auto-hide-controls"]];[self.app launch];
    [self waitForSession:@"Playing"];
    XCUIElement *slider=self.app.sliders[@"session.progress"];
    XCUICoordinate *start=[slider coordinateWithNormalizedOffset:CGVectorMake(slider.normalizedSliderPosition,.5)];
    XCUICoordinate *end=[slider coordinateWithNormalizedOffset:CGVectorMake(.7,.5)];
#if TARGET_OS_OSX
    [start clickForDuration:.2 thenDragToCoordinate:end withVelocity:XCUIGestureVelocitySlow thenHoldForDuration:6];
#else
    [start pressForDuration:.2 thenDragToCoordinate:end withVelocity:XCUIGestureVelocitySlow thenHoldForDuration:6];
#endif
    [self waitForSessionTime:42 tolerance:5];[self waitForSession:@"Playing"];[self attach:@"long-progress-drag-committed"];
}
#endif
- (void)testAudioOnlyTranscoding {
    [self.app terminate];self.app.launchArguments=[self.app.launchArguments arrayByAddingObject:@"--sgplayer-audio-export"];[self.app launch];
    [self waitForStatusContaining:@"transcode-av.mp4" timeout:30];
    for (NSString *kernel in @[@"FFmpeg",@"Native"]) {
        [self waitForStatusContaining:kernel timeout:30];[self press:@"export"];[self waitForStatusContaining:@"Audio:ready" timeout:60];
        XCTAssertFalse([self.status containsString:@"Error:"],@"%@",self.status);[self press:@"export"];
        [self waitForStatusContaining:@"feature-audio.m4a" timeout:30];[self waitForStatusContaining:@"Audio:playing" timeout:30];
        NSPredicate *advanced=[NSPredicate predicateWithBlock:^BOOL(id object,NSDictionary *bindings){NSArray *parts=[self.status componentsSeparatedByString:@" | "];return parts.count>1&&[parts[1]doubleValue]>.1;}];
        XCTNSPredicateExpectation *clock=[[XCTNSPredicateExpectation alloc]initWithPredicate:advanced object:self.app];
        XCTAssertEqual([XCTWaiter waitForExpectations:@[clock]timeout:15],XCTWaiterResultCompleted,@"Audio clock: %@",self.status);
        XCTAssertFalse([self.status containsString:@"Error:"],@"%@",self.status);[self attach:[kernel stringByAppendingString:@"-audio-only-playback"]];
        if ([kernel isEqual:@"FFmpeg"]) {[self press:@"source"];[self waitForStatusContaining:@"transcode-av.mp4" timeout:30];[self press:@"kernel"];}
    }
}
- (void)testVideoTranscoding {
    [self.app terminate];
    self.app.launchArguments=[self.app.launchArguments arrayByAddingObject:@"--sgplayer-transcode-demo"];
    [self.app launch];
    [self waitForStatusContaining:@"transcode-av.mp4" timeout:30];
    [self waitForFrames:5];
    for (NSString *kernel in @[@"FFmpeg",@"Native"]) {
        [self waitForStatusContaining:kernel timeout:30];
        [self press:@"filter"];
        [self press:@"watermark"];
        [self press:@"export"];
        [self waitForStatusContaining:@"Video:ready" timeout:90];
        XCTAssertFalse([self.status containsString:@"Error:"],@"%@",self.status);
        [self attach:[kernel stringByAppendingString:@"-export-ready"]];
        [self press:@"export"];
        [self waitForStatusContaining:@"feature-export.mp4" timeout:30];
        [self waitForStatusContaining:@"Video:playing" timeout:30];
        [self waitForFrames:5];
        XCTAssertFalse([self.status containsString:@"Error:"],@"%@",self.status);
        [self attach:[kernel stringByAppendingString:@"-export-playback"]];
        if ([kernel isEqual:@"FFmpeg"]) {
            [self press:@"source"];
            [self waitForStatusContaining:@"transcode-av.mp4" timeout:30];
            [self press:@"kernel"];
        }
    }
}
#if TARGET_OS_OSX
- (void)testKeyboardSessionControls {
    TISInputSourceRef original=TISCopyCurrentKeyboardInputSource();
    NSDictionary *filter=@{(__bridge NSString *)kTISPropertyInputSourceID:@"com.apple.keylayout.ABC"};
    NSArray *sources=CFBridgingRelease(TISCreateInputSourceList((__bridge CFDictionaryRef)filter,false));
    @try {
    XCTAssertTrue(sources.count>0);if(!sources.count)return;XCTAssertEqual(TISSelectInputSource((__bridge TISInputSourceRef)sources.firstObject),noErr);
    [self.app terminate];self.app.launchArguments=[self.app.launchArguments arrayByAddingObjectsFromArray:@[@"--sgplayer-session-controls",@"--sgplayer-no-resume",@"--sgplayer-keyboard-test-input"]];[self.app launch];
    [self waitForSession:@"Playing"];
    [[self.app.windows.firstMatch coordinateWithNormalizedOffset:CGVectorMake(.5,.2)]click];
    [self.app typeKey:@" " modifierFlags:0];[self waitForSession:@"Paused"];
    [self.app typeKey:XCUIKeyboardKeyLeftArrow modifierFlags:XCUIKeyModifierShift];[self waitForSession:@"Paused  0.0 /"];
    [self.app typeKey:XCUIKeyboardKeyRightArrow modifierFlags:0];[self waitForSession:@"Paused  10.0 /"];
    [self.app typeKey:@"]" modifierFlags:0];[self.app typeKey:@"]" modifierFlags:0];[self attach:@"keyboard-after-rate"];[self waitForSession:@"1.5×"];
    [self.app typeKey:@"l" modifierFlags:0];XCTAssertFalse(self.app.buttons[@"session.play"].isHittable);
    [self.app typeKey:@" " modifierFlags:0];[self.app typeKey:@"l" modifierFlags:0];[self waitForSession:@"Paused"];
    [self.app typeKey:@"f" modifierFlags:0];XCTAssertTrue([self.app.buttons[@"session.restore"]waitForExistenceWithTimeout:10]);
    [self.app typeKey:XCUIKeyboardKeyEscape modifierFlags:0];XCTAssertTrue(self.app.buttons[@"session.play"].isHittable);
    [self.app typeKey:@" " modifierFlags:0];[self waitForSession:@"Playing"];
    XCUIElement *input=self.app.textFields[@"session.keyboard-input"];[input click];[input typeText:@"fml[]"];XCTAssertEqualObjects(input.value,@"fml[]");
    [self waitForSession:@"Playing"];XCTAssertFalse(self.app.buttons[@"session.restore"].exists);
    [[self.app.windows.firstMatch coordinateWithNormalizedOffset:CGVectorMake(.5,.2)]click];[self.app typeKey:@" " modifierFlags:0];[self waitForSession:@"Paused"];
    [self attach:@"keyboard-play-seek-lock-rate-fullscreen-restore-and-text-focus"];
    } @finally {if(original){OSStatus restored=TISSelectInputSource(original);CFRelease(original);XCTAssertEqual(restored,noErr);}}
}
#endif
#if TARGET_OS_OSX || TARGET_OS_TV
- (void)waitForControlVisibility:(BOOL)visible {
    NSPredicate *predicate=[NSPredicate predicateWithBlock:^BOOL(id object,NSDictionary *bindings){return self.app.buttons[@"session.play"].isHittable==visible;}];
    XCTNSPredicateExpectation *expectation=[[XCTNSPredicateExpectation alloc]initWithPredicate:predicate object:self.app];
    XCTAssertEqual([XCTWaiter waitForExpectations:@[expectation]timeout:12],XCTWaiterResultCompleted);
}
- (void)testAutomaticSessionControls {
    [self.app terminate];self.app.launchArguments=[self.app.launchArguments arrayByAddingObjectsFromArray:@[@"--sgplayer-session-controls",@"--sgplayer-no-resume",@"--sgplayer-auto-hide-controls"]];[self.app launch];
    [self waitForSession:@"Playing"];
#if TARGET_OS_OSX
    [[self.app.windows.firstMatch coordinateWithNormalizedOffset:CGVectorMake(.5,.2)]click];
#endif
    [self waitForControlVisibility:NO];
#if TARGET_OS_TV
    XCUIElement *receiver=[[self.app descendantsMatchingType:XCUIElementTypeAny]matchingIdentifier:@"session.remote-surface"].firstMatch;
    XCTAssertTrue(receiver.hasFocus);[[XCUIRemote sharedRemote]pressButton:XCUIRemoteButtonSelect];
#else
    [self.app.windows.firstMatch hover];
#endif
    [self waitForControlVisibility:YES];[self waitForSession:@"Playing"];
#if TARGET_OS_TV
    XCTAssertTrue(self.app.buttons[@"session.play"].hasFocus);[[XCUIRemote sharedRemote]pressButton:XCUIRemoteButtonPlayPause];
#else
    [self.app typeKey:@" " modifierFlags:0];
#endif
    [self waitForSession:@"Paused"];
    NSPredicate *hidden=[NSPredicate predicateWithBlock:^BOOL(id object,NSDictionary *bindings){return !self.app.buttons[@"session.play"].isHittable;}];
    XCTNSPredicateExpectation *staysVisible=[[XCTNSPredicateExpectation alloc]initWithPredicate:hidden object:self.app];staysVisible.inverted=YES;
    XCTAssertEqual([XCTWaiter waitForExpectations:@[staysVisible]timeout:5],XCTWaiterResultCompleted);
#if TARGET_OS_TV
    [[XCUIRemote sharedRemote]pressButton:XCUIRemoteButtonPlayPause];
#else
    [self.app typeKey:@" " modifierFlags:0];
#endif
    [self waitForSession:@"Playing"];[self waitForControlVisibility:NO];
#if TARGET_OS_TV
    [[XCUIRemote sharedRemote]pressButton:XCUIRemoteButtonPlayPause];
#else
    [self.app typeKey:@" " modifierFlags:0];
#endif
    [self waitForSession:@"Paused"];[self waitForControlVisibility:YES];
    [self pressSession:@"play"];[self waitForSession:@"Playing"];[self pressSession:@"lock"];
    NSPredicate *lockHidden=[NSPredicate predicateWithBlock:^BOOL(id object,NSDictionary *bindings){return !self.app.buttons[@"session.lock"].isHittable;}];
    XCTNSPredicateExpectation *lockVisible=[[XCTNSPredicateExpectation alloc]initWithPredicate:lockHidden object:self.app];lockVisible.inverted=YES;
    XCTAssertEqual([XCTWaiter waitForExpectations:@[lockVisible]timeout:5],XCTWaiterResultCompleted);
    [self pressSession:@"lock"];[self waitForSession:@"Playing"];[self attach:@"automatic-hide-reveal-focus-paused-and-locked-preservation"];
}
#endif
- (void)testSessionControlsAndPresentation {
    [self.app terminate];self.app.launchArguments=[self.app.launchArguments arrayByAddingObjectsFromArray:@[@"--sgplayer-session-controls",@"--sgplayer-no-resume"]];[self.app launch];
    XCTAssertTrue([self.app.buttons[@"session.play"] waitForExistenceWithTimeout:30]);[self waitForSession:@"Playing"];
    [self pressSession:@"play"];[self waitForSession:@"Paused"];
    [self pressSession:@"speed"];[self waitForSession:@"1.5×"];
    [self pressSession:@"lock"];XCTAssertFalse(self.app.buttons[@"session.forward"].isHittable);[self pressSession:@"lock"];
    [self pressSession:@"kernel"];[self waitForSession:@"Native"];
    [self pressSession:@"play"];[self waitForSession:@"Playing"];[self pressSession:@"forward"];
    [self pressSession:@"next"];[self waitForSession:@"Playing"];[self pressSession:@"previous"];[self waitForSession:@"Playing"];
    [self pressSession:@"floating"];XCTAssertTrue([self.app.buttons[@"session.restore"] waitForExistenceWithTimeout:10]);[self pressSession:@"restore"];
    XCTAssertTrue(self.app.buttons[@"session.play"].isHittable);
    [self pressSession:@"fullscreen"];XCTAssertTrue([self.app.buttons[@"session.restore"] waitForExistenceWithTimeout:10]);[self pressSession:@"restore"];
    [self attach:@"session-controls-and-restored-surface"];
}
#if TARGET_OS_IOS && !TARGET_OS_TV
- (void)testCoverAndAutomaticControls {
    [self.app terminate];self.app.launchArguments=[self.app.launchArguments arrayByAddingObjectsFromArray:@[@"--sgplayer-session-controls",@"--sgplayer-no-resume",@"--sgplayer-feature-orientation-test",@"--sgplayer-cover-test",@"--sgplayer-auto-hide-controls"]];[self.app launch];
    [self waitForSession:@"Failed"];
    XCUIElement *video=[[self.app descendantsMatchingType:XCUIElementTypeAny] matchingIdentifier:@"feature.video"].firstMatch;
    XCTAssertEqualObjects(video.label,@"Video cover");[self attach:@"cover-on-source-failure"];
    [self pressSession:@"next"];[self waitForSession:@"Paused"];[self pressSession:@"play"];[self waitForSession:@"Playing"];
    NSPredicate *coverGone=[NSPredicate predicateWithBlock:^BOOL(id object,NSDictionary *bindings){return ![video.label isEqual:@"Video cover"];}];
    XCTAssertEqual([XCTWaiter waitForExpectations:@[[[XCTNSPredicateExpectation alloc]initWithPredicate:coverGone object:video]] timeout:10],XCTWaiterResultCompleted);
    NSPredicate *hidden=[NSPredicate predicateWithBlock:^BOOL(id object,NSDictionary *bindings){return !self.app.buttons[@"session.play"].isHittable;}];
    XCTAssertEqual([XCTWaiter waitForExpectations:@[[[XCTNSPredicateExpectation alloc]initWithPredicate:hidden object:self.app]] timeout:10],XCTWaiterResultCompleted);
    [video tap];XCTAssertTrue([self.app.buttons[@"session.play"]waitForExistenceWithTimeout:5]);[self pressSession:@"play"];[self waitForSession:@"Paused"];
    [NSThread sleepForTimeInterval:4.5];XCTAssertTrue(self.app.buttons[@"session.play"].isHittable);
    [[video coordinateWithNormalizedOffset:CGVectorMake(.8,.3)]pressForDuration:.1 thenDragToCoordinate:[video coordinateWithNormalizedOffset:CGVectorMake(.8,.7)]];
    [NSThread sleepForTimeInterval:3.2];XCTAssertFalse([video.label isEqual:@"Video cover"]);
    [video doubleTap];[self waitForSession:@"Playing"];[self pressSession:@"lock"];[NSThread sleepForTimeInterval:3];XCTAssertTrue(self.app.buttons[@"session.lock"].isHittable);[self pressSession:@"lock"];
    [self attach:@"cover-hidden-controls-restored-and-lock-preserved"];
}
- (void)testTouchSessionGestures {
    [self.app terminate];self.app.launchArguments=[self.app.launchArguments arrayByAddingObjectsFromArray:@[@"--sgplayer-session-controls",@"--sgplayer-no-resume",@"--sgplayer-feature-orientation-test"]];[self.app launch];
    [self waitForSession:@"Playing"];
    XCUIElement *video=[[self.app descendantsMatchingType:XCUIElementTypeAny] matchingIdentifier:@"feature.video"].firstMatch;
    XCTAssertTrue([video waitForExistenceWithTimeout:10]);[video doubleTap];[self waitForSession:@"Paused"];
    XCUICoordinate *start=[video coordinateWithNormalizedOffset:CGVectorMake(.2,.5)],*end=[video coordinateWithNormalizedOffset:CGVectorMake(.65,.5)];
    [start pressForDuration:.1 thenDragToCoordinate:end];
    NSPredicate *seeked=[NSPredicate predicateWithBlock:^BOOL(id object,NSDictionary *bindings){NSString *text=self.app.staticTexts[@"session.status"].label;NSRegularExpression *regex=[NSRegularExpression regularExpressionWithPattern:@"Paused[[:space:]]+([0-9.]+) /" options:0 error:nil];NSTextCheckingResult *match=[regex firstMatchInString:text options:0 range:NSMakeRange(0,text.length)];return match&&[[text substringWithRange:[match rangeAtIndex:1]]doubleValue]>10;}];
    XCTAssertEqual([XCTWaiter waitForExpectations:@[[[XCTNSPredicateExpectation alloc]initWithPredicate:seeked object:self.app]] timeout:20],XCTWaiterResultCompleted);
    [[video coordinateWithNormalizedOffset:CGVectorMake(.8,.3)]pressForDuration:.1 thenDragToCoordinate:[video coordinateWithNormalizedOffset:CGVectorMake(.8,.7)]];
    XCTAssertTrue([[video.value description] containsString:@"Volume"]);
    [[video coordinateWithNormalizedOffset:CGVectorMake(.2,.3)]pressForDuration:.1 thenDragToCoordinate:[video coordinateWithNormalizedOffset:CGVectorMake(.2,.6)]];
    XCTAssertTrue([[video.value description] containsString:@"Brightness"]);
    [self pressSession:@"lock"];[video doubleTap];[self pressSession:@"lock"];[self waitForSession:@"Paused"];
    [video doubleTap];[self waitForSession:@"Playing"];[self attach:@"touch-seek-levels-and-lock"];
}
- (void)testSessionBackgroundLifecycle {
    [self.app terminate];self.app.launchArguments=[self.app.launchArguments arrayByAddingObjectsFromArray:@[@"--sgplayer-session-controls",@"--sgplayer-no-resume",@"--sgplayer-feature-orientation-test"]];[self.app launch];
    [self waitForSession:@"Playing"];
    double (^seconds)(void)=^double{
        NSString *text=self.app.staticTexts[@"session.status"].label;NSRegularExpression *regex=[NSRegularExpression regularExpressionWithPattern:@"Playing[[:space:]]+([0-9.]+) /" options:0 error:nil];
        NSTextCheckingResult *match=[regex firstMatchInString:text options:0 range:NSMakeRange(0,text.length)];return match?[[text substringWithRange:[match rangeAtIndex:1]]doubleValue]:-1;
    };
    double before=seconds();XCTAssertGreaterThanOrEqual(before,0);
    [[XCUIDevice sharedDevice]pressButton:XCUIDeviceButtonHome];[NSThread sleepForTimeInterval:25];[self.app activate];
    NSPredicate *advances=[NSPredicate predicateWithBlock:^BOOL(id object,NSDictionary *bindings){return seconds()>before+.3;}];
    XCTNSPredicateExpectation *expectation=[[XCTNSPredicateExpectation alloc]initWithPredicate:advances object:self.app];
    XCTAssertEqual([XCTWaiter waitForExpectations:@[expectation] timeout:20],XCTWaiterResultCompleted);
    XCTAssertTrue([self.app.staticTexts[@"session.status"].label containsString:@"FFmpeg"]);
    [self attach:@"session-video-only-foreground-resume"];
}
#endif
#if TARGET_OS_OSX || TARGET_OS_TV
- (void)testCoverLifecycle {
    [self.app terminate];self.app.launchArguments=[self.app.launchArguments arrayByAddingObjectsFromArray:@[@"--sgplayer-session-controls",@"--sgplayer-no-resume",@"--sgplayer-feature-orientation-test",@"--sgplayer-cover-test"]];[self.app launch];
    [self waitForSession:@"Failed"];
    XCUIElement *video=[[self.app descendantsMatchingType:XCUIElementTypeAny] matchingIdentifier:@"feature.video"].firstMatch;
    XCTAssertEqualObjects(video.label,@"Video cover");[self attach:@"cover-before-valid-source"];
    [self pressSession:@"next"];[self waitForSession:@"Paused"];[self pressSession:@"play"];[self waitForSession:@"Playing"];
    NSPredicate *gone=[NSPredicate predicateWithBlock:^BOOL(id object,NSDictionary *bindings){return ![video.label isEqual:@"Video cover"];}];
    XCTAssertEqual([XCTWaiter waitForExpectations:@[[[XCTNSPredicateExpectation alloc]initWithPredicate:gone object:video]] timeout:10],XCTWaiterResultCompleted);
    [self attach:@"cover-hidden-after-first-frame"];
}
#endif
- (void)testProjectionOrientation {
    [self.app terminate];self.app.launchArguments=[self.app.launchArguments arrayByAddingObject:@"--sgplayer-feature-orientation-test"];[self.app launch];
    for(int backend=0;backend<2;backend++) {
        [self press:@"play"];[self waitForFrames:5];[self press:@"pause"];
        XCUIElement *video=[[self.app descendantsMatchingType:XCUIElementTypeAny] matchingIdentifier:@"feature.video"].firstMatch;
        XCTAssertTrue([video waitForExistenceWithTimeout:10]);
#if TARGET_OS_OSX
        NSImage *screenshot=video.screenshot.image;CGImageRef cg=[screenshot CGImageForProposedRect:NULL context:nil hints:nil];
#else
        CGImageRef cg=video.screenshot.image.CGImage;
#endif
        XCTAssertTrue(cg!=NULL);
        CGFloat width=CGImageGetWidth(cg),height=CGImageGetHeight(cg);
        CGFloat contentHeight=MIN(height,width*0.75);
        for(int sample=0;sample<2;sample++) {
            CGFloat y=height/2+(sample==0?-1:1)*contentHeight/4;
            CGImageRef pixel=CGImageCreateWithImageInRect(cg,CGRectMake(width/2,y,1,1));
            uint8_t rgba[4]={0};CGColorSpaceRef space=CGColorSpaceCreateDeviceRGB();
            CGContextRef context=CGBitmapContextCreate(rgba,1,1,8,4,space,kCGImageAlphaPremultipliedLast|kCGBitmapByteOrder32Big);
            CGContextDrawImage(context,CGRectMake(0,0,1,1),pixel);
            CGContextRelease(context);CGColorSpaceRelease(space);CGImageRelease(pixel);
            if(sample==0)XCTAssertGreaterThan((int)rgba[0]-(int)rgba[2],80,@"Top must be red, backend %d",backend);
            else XCTAssertGreaterThan((int)rgba[2]-(int)rgba[0],80,@"Bottom must be blue, backend %d",backend);
        }
        [self attach:[NSString stringWithFormat:@"projection-orientation-%d",backend]];
        if(backend==0){[self press:@"kernel"];[self waitForStatusContaining:@"Native" timeout:30];}
    }
}
- (void)testControlsAndKernelSwitch {
    [self press:@"play"];
    NSPredicate *progress=[NSPredicate predicateWithBlock:^BOOL(id object,NSDictionary *bindings){return [self seconds]>1;}];
    XCTNSPredicateExpectation *ready=[[XCTNSPredicateExpectation alloc]initWithPredicate:progress object:self.app];
    XCTAssertEqual([XCTWaiter waitForExpectations:@[ready] timeout:30],XCTWaiterResultCompleted);
    [self press:@"pause"];double paused=self.seconds;
    XCTNSPredicateExpectation *stable=[[XCTNSPredicateExpectation alloc]initWithPredicate:[NSPredicate predicateWithBlock:^BOOL(id object,NSDictionary *bindings){return fabs(self.seconds-paused)>0.4;}] object:self.app];
    XCTAssertEqual([XCTWaiter waitForExpectations:@[stable] timeout:1],XCTWaiterResultTimedOut);
    [self press:@"seek"];XCTAssertGreaterThan(self.seconds,paused+1);
    [self press:@"play"];
    for (int i=0;i<3;i++)[self press:@"rate"];
    [self press:@"kernel"];[self waitForStatusContaining:@"Native" timeout:30];
    [self press:@"pause"];[self press:@"seek"];[self press:@"play"];
    [self press:@"kernel"];[self waitForStatusContaining:@"FFmpeg" timeout:30];
    [self attach:@"kernel-switch-controls"];
}
- (void)testEffectsAndGIF {
    for(int backend=0;backend<2;backend++) {
        [self press:@"subtitles"];[self press:@"danmaku"];[self press:@"watermark"];
        for(int i=0;i<5;i++) {[self press:@"filter"];[self attach:[NSString stringWithFormat:@"backend-%d-filter-%d",backend,i]];}
        [self press:@"sticker"];[self press:@"screenshot"];[self press:@"export"];
        XCTAssertFalse([self.status containsString:@"| Error:"],@"%@",self.status);
        [self attach:[NSString stringWithFormat:@"backend-%d-all-overlays",backend]];
        [self press:@"sticker"];[self press:@"subtitles"];[self press:@"danmaku"];[self press:@"watermark"];
        if(backend==0){[self press:@"kernel"];[self waitForStatusContaining:@"Native" timeout:30];}
    }
}
- (void)testAllBundledFormats {
    // Two original MP4 sources followed by eight generated formats.
    for(int i=0;i<10;i++) {
        [self press:@"play"];
        [self waitForFrames:5];
        [self attach:[NSString stringWithFormat:@"source-%d",i]];
        XCTAssertFalse([self.status containsString:@"| Error:"],@"%@",self.status);
        [self press:@"source"];
    }
}
- (void)testVRAndStop {
    [self press:@"subtitles"];[self press:@"watermark"];[self press:@"vr"];[self waitForFrames:10];
    [self press:@"screenshot"];XCTAssertFalse([self.status containsString:@"| Error:"],@"%@",self.status);[self attach:@"VR-with-subtitle-watermark"];
    [self press:@"vr"];[self press:@"stop"];double stopped=self.seconds;
    [NSThread sleepForTimeInterval:1];XCTAssertLessThan(fabs(self.seconds-stopped),0.4);
    [self press:@"play"];
}
- (void)testEffectsWhilePaused {
    for(int backend=0;backend<2;backend++) {
        [self press:@"pause"];double paused=self.seconds;
        [self press:@"watermark"];[self press:@"subtitles"];[self press:@"filter"];[self press:@"screenshot"];
        XCTAssertFalse([self.status containsString:@"| Error:"],@"%@",self.status);
        XCTAssertLessThan(fabs(self.seconds-paused),0.4);[self attach:[NSString stringWithFormat:@"paused-effects-%d",backend]];
        [self press:@"play"];if(backend==0){[self press:@"kernel"];[self waitForStatusContaining:@"Native" timeout:30];}
    }
}
- (void)testInvalidSourceRecovery {
    [self.app terminate];self.app.launchArguments=[self.app.launchArguments arrayByAddingObject:@"--sgplayer-feature-invalid-source"];[self.app launch];
    [self waitForStatusContaining:@"| Error:" timeout:30];[self press:@"source"];[self waitForFrames:5];
    XCTAssertFalse([self.status containsString:@"| Error:"],@"Source replacement must recover: %@",self.status);
}
- (void)testPictureInPicture {
    for(int backend=0;backend<2;backend++) {
        [self press:@"play"];[self waitForFrames:5];
        [self press:@"pip"];
#if TARGET_OS_TV || TARGET_OS_SIMULATOR
        if([self.status containsString:@"unsupported"]) {
            XCTAssertTrue([self.status containsString:@"Error:"],@"Unavailable PiP must report a real capability error");
            XCTSkip(@"This simulator reports system PiP unsupported; capability rejection verified. Active/background PiP requires a supported device and remains in physical iPhone acceptance.");
        }
#endif
        XCTAssertFalse([self.status containsString:@"unsupported"],@"PiP did not start: %@",self.status);
        XCTAssertFalse([self.status containsString:@"not ready"],@"PiP did not start: %@",self.status);
        [self waitForStatusContaining:@"PiP:on" timeout:20];
        double before=self.seconds;
#if TARGET_OS_IOS && !TARGET_OS_TV
        [[XCUIDevice sharedDevice]pressButton:XCUIDeviceButtonHome];
        [NSThread sleepForTimeInterval:4];
        [self.app activate];
        NSPredicate *backgroundFrames=[NSPredicate predicateWithBlock:^BOOL(id object,NSDictionary *bindings){
            NSRegularExpression *regex=[NSRegularExpression regularExpressionWithPattern:@"BgFrames:([0-9]+)" options:0 error:nil];
            NSString *value=self.status;NSTextCheckingResult *match=[regex firstMatchInString:value options:0 range:NSMakeRange(0,value.length)];
            return match && [[value substringWithRange:[match rangeAtIndex:1]] integerValue]>0;
        }];
        XCTNSPredicateExpectation *frames=[[XCTNSPredicateExpectation alloc]initWithPredicate:backgroundFrames object:self.app];
        XCTAssertEqual([XCTWaiter waitForExpectations:@[frames] timeout:10],XCTWaiterResultCompleted,@"No background PiP frames: %@",self.status);
#elif TARGET_OS_OSX
        [[[XCUIApplication alloc]initWithBundleIdentifier:@"com.apple.finder"] activate];
        [NSThread sleepForTimeInterval:3];[self.app activate];
#else
        [NSThread sleepForTimeInterval:3];
#endif
        XCTAssertGreaterThan(self.seconds,before+1,@"Playback stopped during PiP background transition");
        [self attach:[NSString stringWithFormat:@"picture-in-picture-backend-%d",backend]];
        if([self.status containsString:@"PiP:on"])[self press:@"pip"];
        [self waitForStatusContaining:@"PiP:off" timeout:20];
        if(backend==0){[self press:@"kernel"];[self waitForStatusContaining:@"Native" timeout:30];}
    }
}

@end
