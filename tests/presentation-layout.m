#import <AppKit/AppKit.h>
#import <SGPlayer/SGPlaybackPresentation.h>
int main(void){@autoreleasepool{
[NSApplication sharedApplication];
NSView *root=[[NSView alloc]initWithFrame:NSMakeRect(0,0,400,300)];
NSView *surface=[NSView new];surface.translatesAutoresizingMaskIntoConstraints=NO;[root addSubview:surface];
NSArray *sizes=@[[surface.widthAnchor constraintEqualToConstant:400],[surface.heightAnchor constraintEqualToConstant:300]];[NSLayoutConstraint activateConstraints:sizes];
NSArray *constraints=@[[surface.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],[surface.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],[surface.topAnchor constraintEqualToAnchor:root.topAnchor],[surface.bottomAnchor constraintEqualToAnchor:root.bottomAnchor]];
[NSLayoutConstraint activateConstraints:constraints];[root layoutSubtreeIfNeeded];
NSView *video=[NSView new];video.translatesAutoresizingMaskIntoConstraints=NO;[surface addSubview:video];
[NSLayoutConstraint activateConstraints:@[[video.leadingAnchor constraintEqualToAnchor:surface.leadingAnchor],[video.trailingAnchor constraintEqualToAnchor:surface.trailingAnchor],[video.topAnchor constraintEqualToAnchor:surface.topAnchor],[video.bottomAnchor constraintEqualToAnchor:surface.bottomAnchor]]];
[root layoutSubtreeIfNeeded];
SGPlaybackPresentation *p=[[SGPlaybackPresentation alloc]initWithSurface:surface];
NSCAssert([p showFloatingInView:root frame:NSMakeRect(16,16,400,225)],@"Floating request must be clamped to host bounds");
for(NSLayoutConstraint *size in sizes)NSCAssert(!size.active,@"Own size constraint still active while floating");
NSCAssert(surface.translatesAutoresizingMaskIntoConstraints,@"Floating surface must use its new host sizing policy");
NSCAssert(surface.frame.size.width>0&&surface.frame.size.height>0,@"Floating surface empty");
[surface layoutSubtreeIfNeeded];
NSCAssert(video.bounds.size.height<300,@"Child must take floating dimensions before restore");
[p restore];
NSCAssert(NSEqualSizes(video.bounds.size,surface.bounds.size),@"Nested video layout must restore synchronously");
NSCAssert(surface.superview==root&&!surface.translatesAutoresizingMaskIntoConstraints,@"Original layout policy not restored");
for(NSLayoutConstraint *size in sizes)NSCAssert(size.active,@"Original own size constraint not restored");
for(NSLayoutConstraint *c in constraints)NSCAssert(c.active,@"Original constraints not restored");
puts("PASS floating layout with constraints, bounded frame and restoration");
}return 0;}
