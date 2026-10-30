#import <AppKit/AppKit.h>
#import <SGPlayer/SGMediaEffects.h>
@interface SGMediaEffects (Validation)
- (CIImage *)textImage:(NSString *)text size:(CGFloat)size width:(CGFloat)width;
@end
static NSBitmapImageRep *pixels(CIImage *image) {
 CIContext *context=[CIContext contextWithOptions:@{kCIContextUseSoftwareRenderer:@YES}];
 CGImageRef cg=[context createCGImage:image fromRect:image.extent];NSBitmapImageRep *rep=[[NSBitmapImageRep alloc]initWithCGImage:cg];CGImageRelease(cg);return rep;
}
static NSRect ink(NSBitmapImageRep *rep) {
 NSInteger minX=rep.pixelsWide,minY=rep.pixelsHigh,maxX=-1,maxY=-1;
 for(NSInteger y=0;y<rep.pixelsHigh;y++)for(NSInteger x=0;x<rep.pixelsWide;x++){NSColor *p=[[rep colorAtX:x y:y] colorUsingColorSpace:NSColorSpace.deviceRGBColorSpace];if(p.alphaComponent>.1){minX=MIN(minX,x);minY=MIN(minY,y);maxX=MAX(maxX,x);maxY=MAX(maxY,y);}}
 return maxX<0?NSZeroRect:NSMakeRect(minX,minY,maxX-minX+1,maxY-minY+1);
}
int main(){@autoreleasepool{
 SGMediaEffects *effects=[SGMediaEffects new];NSCAssert(!effects.textBackgroundEnabled,@"Text background must default off");effects.textColorRGB=0xff0000;
 NSBitmapImageRep *plain=pixels([effects textImage:@"Test" size:28 width:500]);
 NSCAssert(plain.pixelsWide<150,@"Text bitmap must tightly fit glyphs, not stretch to maximum width");
 NSColor *corner=[[plain colorAtX:0 y:0]colorUsingColorSpace:NSColorSpace.deviceRGBColorSpace];NSCAssert(corner.alphaComponent==0,@"Plain text acquired a background");
 BOOL red=NO;for(NSInteger y=0;y<plain.pixelsHigh;y++)for(NSInteger x=0;x<plain.pixelsWide;x++){NSColor *p=[[plain colorAtX:x y:y]colorUsingColorSpace:NSColorSpace.deviceRGBColorSpace];if(p.alphaComponent>.9){NSCAssert(p.redComponent>.95&&p.greenComponent<.05&&p.blueComponent<.05,@"Text RGB color lost");red=YES;}}
 NSCAssert(red,@"No opaque glyph pixels");effects.textBackgroundEnabled=YES;
 NSBitmapImageRep *capsule=pixels([effects textImage:@"Test" size:28 width:500]);
 NSCAssert([[capsule colorAtX:0 y:0]alphaComponent]<.01,@"Capsule corner must be rounded/transparent");
 NSCAssert([[capsule colorAtX:1 y:capsule.pixelsHigh/2]alphaComponent]>.5,@"Optional capsule background missing");
 effects.textBackgroundEnabled=NO;
 SGSubtitleCue *cue=[SGSubtitleCue new];cue.text=@"Readable subtitle";cue.duration=CMTimeMake(10,1);effects.subtitles=@[cue];
 CIImage *transparent=[CIImage imageWithColor:[CIColor colorWithRed:0 green:0 blue:0 alpha:0]];
 NSRect small=ink(pixels([effects composeImage:[transparent imageByCroppingToRect:CGRectMake(0,0,720,360)] atTime:kCMTimeZero]));
 NSRect large=ink(pixels([effects composeImage:[transparent imageByCroppingToRect:CGRectMake(0,0,1440,720)] atTime:kCMTimeZero]));
 NSCAssert(small.size.width>20&&fabs(large.size.width/small.size.width-2)<.12&&fabs(large.size.height/small.size.height-2)<.15,@"Subtitle geometry must scale with video pixels");
 effects.subtitles=@[];SGWatermark *mark=[SGWatermark new];mark.text=@"H";mark.rect=CGRectMake(.1,.1,.5,.4);effects.watermarks=@[mark];
 NSRect textMark=ink(pixels([effects composeImage:[transparent imageByCroppingToRect:CGRectMake(0,0,720,360)] atTime:kCMTimeZero]));
 NSCAssert(textMark.size.width<50&&textMark.size.height<50,@"Text watermark was stretched to the requested rectangle");
 mark.image=[[CIImage imageWithColor:[CIColor colorWithRed:1 green:1 blue:1 alpha:1]]imageByCroppingToRect:CGRectMake(0,0,20,10)];mark.rect=CGRectMake(.1,.1,.25,.4);
 NSRect imageMark=ink(pixels([effects composeImage:[transparent imageByCroppingToRect:CGRectMake(0,0,720,360)]atTime:kCMTimeZero]));
 fprintf(stderr,"IMAGE_MARK %s\n",NSStringFromRect(imageMark).UTF8String);NSCAssert(fabs(imageMark.size.width/imageMark.size.height-2)<.05,@"Image watermark aspect ratio changed");
 SGMediaEffects *snapshot=[effects snapshot];NSCAssert(snapshot.textColorRGB==0xff0000&&!snapshot.textBackgroundEnabled,@"Text style snapshot lost");
 puts("PASS transparent colored glyphs, optional capsule, proportional subtitles and undistorted text/image watermarks");
}return 0;}
