#import <XCTest/XCTest.h>
#import <TargetConditionals.h>
#if TARGET_OS_OSX
#import <AppKit/AppKit.h>
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
    NSString *root=[[@(__FILE__) stringByDeletingLastPathComponent] stringByDeletingLastPathComponent];
    self.app.launchArguments=[self.app.launchArguments arrayByAddingObject:[@"--sgplayer-test-output=" stringByAppendingString:[root stringByAppendingPathComponent:@"build/feature-ui-artifacts/macos"]]];
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
#if TARGET_OS_TV
        if([self.status containsString:@"unsupported"]) {
            XCTAssertTrue([self.status containsString:@"Error:"],@"Unavailable PiP must report a real capability error");
            XCTSkip(@"This tvOS simulator reports system PiP unsupported; capability rejection verified, active PiP requires supported hardware/runtime.");
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
