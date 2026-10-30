#import "SGMediaEffects.h"
#import "SGFFmpeg.h"
#import <CoreText/CoreText.h>
#import <ImageIO/ImageIO.h>
#import <libavfilter/avfilter.h>
#import <libavfilter/buffersrc.h>
#import <libavfilter/buffersink.h>
#import <libavutil/opt.h>
#import <ass/ass.h>

static NSError *SGEffectError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:@"SGMediaEffects" code:code userInfo:@{NSLocalizedDescriptionKey: message}];
}
@implementation SGFilterConfiguration
- (instancetype)init { if ((self = [super init])) { _contrast = 1; _saturation = 1; } return self; }
- (id)copyWithZone:(NSZone *)zone {
    SGFilterConfiguration *c = [[SGFilterConfiguration alloc] init];
    c.brightness = self.brightness; c.contrast = self.contrast; c.saturation = self.saturation;
    c.grayscale = self.grayscale; c.horizontalFlip = self.horizontalFlip; c.verticalFlip = self.verticalFlip; c.blurRadius = self.blurRadius; c.colorCurves = self.colorCurves;
    c.colorCube=self.colorCube;c.colorCubeDimension=self.colorCubeDimension;c.bloomRadius=self.bloomRadius;c.bloomIntensity=self.bloomIntensity;return c;
}
- (BOOL)active { return self.brightness != 0 || self.contrast != 1 || self.saturation != 1 || self.grayscale || self.horizontalFlip || self.verticalFlip || self.blurRadius != 0 || self.colorCurves.length > 0 || self.colorCube.length || self.bloomIntensity>0; }
- (NSError *)validationError {
    if (!isfinite(self.brightness) || fabs(self.brightness) > 1 || !isfinite(self.contrast) || self.contrast < 0 || self.contrast > 4 || !isfinite(self.saturation) || self.saturation < 0 || self.saturation > 2 || !isfinite(self.blurRadius) || self.blurRadius < 0 || self.blurRadius > 20) return SGEffectError(1, @"Filter parameter out of range");
    if (self.colorCurves) {
        NSUInteger count=self.colorCurves.length/(3*sizeof(float));
        if (count<2 || count>64 || self.colorCurves.length!=count*3*sizeof(float)) return SGEffectError(6,@"LUT must contain 2...64 RGB float samples");
        const float *values=self.colorCurves.bytes;
        for(NSUInteger i=0;i<count*3;i++) if(!isfinite(values[i]) || values[i]<0 || values[i]>1) return SGEffectError(6,@"Invalid LUT sample");
    }
    if(!isfinite(self.bloomRadius)||self.bloomRadius<0||self.bloomRadius>20||!isfinite(self.bloomIntensity)||self.bloomIntensity<0||self.bloomIntensity>1)return SGEffectError(7,@"Invalid bloom radius or intensity");
    if(self.colorCube){
        NSUInteger n=self.colorCubeDimension;
        if(n<2||n>64||self.colorCube.length!=n*n*n*4*sizeof(float))return SGEffectError(8,@"3D LUT requires 2...64 cubed RGBA samples");
        const float *values=self.colorCube.bytes;
        for(NSUInteger i=0;i<n*n*n*4;i++)if(!isfinite(values[i])||values[i]<0||values[i]>1||(i%4==3&&values[i]!=1))return SGEffectError(8,@"Invalid 3D LUT sample or alpha");
    }
    return nil;
}
+ (instancetype)configurationWithCubeText:(NSString *)text error:(NSError **)error {
    if(text.length>16*1024*1024){if(error)*error=SGEffectError(8,@"Cube text exceeds the 16 MB limit");return nil;}
    SGFilterConfiguration *configuration=[self new];NSMutableData *data=[NSMutableData data];NSUInteger dimension=0,count=0;BOOL invalid=NO;
    NSScanner *lines=[NSScanner scannerWithString:text];lines.charactersToBeSkipped=nil;
    while(!lines.isAtEnd){
        NSString *line=nil;[lines scanUpToCharactersFromSet:NSCharacterSet.newlineCharacterSet intoString:&line];[lines scanCharactersFromSet:NSCharacterSet.newlineCharacterSet intoString:nil];line=line?:@"";
        NSString *body=[[line componentsSeparatedByString:@"#"].firstObject stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if(!body.length||[body hasPrefix:@"TITLE "])continue;
        NSScanner *scanner=[NSScanner scannerWithString:body];
        if([scanner scanString:@"LUT_3D_SIZE" intoString:nil]){NSInteger n=0;if(dimension||![scanner scanInteger:&n]||!scanner.isAtEnd||n<2||n>64){invalid=YES;break;}dimension=n;continue;}
        BOOL minimum=[scanner scanString:@"DOMAIN_MIN" intoString:nil];
        BOOL maximum=!minimum&&[scanner scanString:@"DOMAIN_MAX" intoString:nil];
        if(minimum||maximum){for(int i=0;i<3;i++){double value;if(![scanner scanDouble:&value]||value!=(minimum?0:1))invalid=YES;}if(!scanner.isAtEnd)invalid=YES;if(invalid)break;continue;}
        if(!dimension||count>=dimension*dimension*dimension){invalid=YES;break;}
        float values[4]={0,0,0,1};for(int i=0;i<3;i++)if(![scanner scanFloat:&values[i]]||!isfinite(values[i])||values[i]<0||values[i]>1)invalid=YES;
        if(!scanner.isAtEnd)invalid=YES;if(invalid)break;
        [data appendBytes:values length:sizeof(values)];count++;
    }
    if(invalid||!dimension||count!=dimension*dimension*dimension){if(error)*error=SGEffectError(8,@"Invalid .cube LUT: require a complete 3D cube with a unit input domain");return nil;}
    configuration.colorCube=data;configuration.colorCubeDimension=dimension;return configuration;
}
@end

@interface SGAnimatedImage ()
@property (nonatomic, copy) NSArray<CIImage *> *frames;
@property (nonatomic, copy) NSArray<NSNumber *> *ends;
@property (nonatomic, readwrite) NSTimeInterval duration;
@property (nonatomic, readwrite) NSUInteger loopCount;
@end
@implementation SGAnimatedImage
+ (instancetype)imageWithURL:(NSURL *)URL maxDecodedBytes:(NSUInteger)limit error:(NSError **)error {
    CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)URL, NULL);
    if (!source) { if (error) *error = SGEffectError(2, @"Cannot open animated image"); return nil; }
    size_t count = CGImageSourceGetCount(source);
    SGAnimatedImage *result = [[self alloc] init];
    NSDictionary *properties = CFBridgingRelease(CGImageSourceCopyProperties(source, NULL));
    result.loopCount = [properties[(__bridge NSString *)kCGImagePropertyGIFDictionary][(__bridge NSString *)kCGImagePropertyGIFLoopCount] unsignedIntegerValue];
    NSMutableArray *frames = [NSMutableArray array], *ends = [NSMutableArray array];
    NSUInteger bytes = 0;
    BOOL failed = count == 0 || count > 10000 || limit == 0;
    for (size_t i = 0; i < count && !failed; i++) {
        CGImageRef image = CGImageSourceCreateImageAtIndex(source, i, NULL);
        if (!image) { failed = YES; break; }
        size_t width = CGImageGetWidth(image), height = CGImageGetHeight(image);
        if (width > 8192 || height > 8192 || width * height > (limit - MIN(bytes, limit)) / 4) { CGImageRelease(image); failed = YES; break; }
        bytes += width * height * 4;
        [frames addObject:[CIImage imageWithCGImage:image]];
        CGImageRelease(image);
        NSDictionary *frameProperties = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source, i, NULL));
        NSDictionary *gif = frameProperties[(__bridge NSString *)kCGImagePropertyGIFDictionary];
        double delay = [gif[(__bridge NSString *)kCGImagePropertyGIFUnclampedDelayTime] doubleValue];
        if (delay <= 0) delay = [gif[(__bridge NSString *)kCGImagePropertyGIFDelayTime] doubleValue];
        result.duration += MAX(0.02, isfinite(delay) ? delay : 0.1);
        [ends addObject:@(result.duration)];
    }
    CFRelease(source);
    if (failed) { if (error) *error = SGEffectError(3, @"Invalid animation or decoded memory budget exceeded"); return nil; }
    result.frames = frames; result.ends = ends; return result;
}
- (NSUInteger)frameCount { return self.frames.count; }
- (CIImage *)imageAtTime:(NSTimeInterval)time {
    if (!isfinite(time) || time < 0 || self.duration <= 0 || !self.frames.count) return nil;
    if (self.loopCount > 0 && time >= self.duration * (self.loopCount + 1)) return self.frames.lastObject;
    time = fmod(time, self.duration);
    NSUInteger low = 0, high = self.ends.count;
    while (low < high) { NSUInteger mid = (low + high) / 2; if (time < self.ends[mid].doubleValue) high = mid; else low = mid + 1; }
    return self.frames[MIN(low, self.frames.count - 1)];
}
@end

@interface SGMediaEffects () {
    AVFilterGraph *_graph;
    AVFilterContext *_source, *_sink;
    CVPixelBufferPoolRef _pixelPool;
    CGSize _poolSize;
    ASS_Library *_assLibrary;
    ASS_Renderer *_assRenderer;
    ASS_Track *_assTrack;
    NSArray *_assCues;
    SGSubtitleTrack *_assSource;
    NSURL *_assFallbackFontURL;

}
@property (nonatomic, strong) CIContext *context;
@property (nonatomic) BOOL contextUsesSoftware;
@property (nonatomic, strong) NSCache *textCache;
@property (nonatomic, copy) NSString *graphKey;
@property (nonatomic, strong) NSArray *sortedDanmaku;
@property (nonatomic, strong) NSArray *sortedDanmakuSource;
@property (atomic, strong, readwrite) NSError *lastError;
@property (nonatomic, strong) SGMediaEffects *secondaryRenderer;
@property (nonatomic, copy) NSData *cubeFileData;
@property (nonatomic) NSUInteger cubeFileDimension;
@property (nonatomic, strong) NSURL *cubeFileURL;
@end
static NSArray<SGSubtitleCue *> *SGSnapshotCues(NSArray<SGSubtitleCue *> *source) {
    NSMutableArray *cues=[NSMutableArray arrayWithCapacity:source.count];
    for(SGSubtitleCue *cue in source){SGSubtitleCue *copy=[SGSubtitleCue new];copy.start=cue.start;copy.duration=cue.duration;copy.text=cue.text;copy.ASS=cue.ASS;copy.bitmap=cue.bitmap;copy.region=cue.region;[cues addObject:copy];}
    return cues;
}
static SGSubtitleTrack *SGSnapshotTrack(SGSubtitleTrack *source) {
    if(!source)return nil;SGSubtitleTrack *copy=[SGSubtitleTrack new];copy.index=source.index;copy.language=source.language;copy.title=source.title;copy.defaultTrack=source.defaultTrack;copy.forced=source.forced;copy.ASSHeader=source.ASSHeader;copy.cues=SGSnapshotCues(source.cues);
    NSMutableDictionary *fonts=[NSMutableDictionary dictionary];[source.fonts enumerateKeysAndObjectsUsingBlock:^(NSString *name,NSData *bytes,BOOL *stop){fonts[name]=[bytes copy];}];copy.fonts=fonts;return copy;
}
@implementation SGMediaEffects
- (instancetype)init {
    if ((self = [super init])) {
        _filter = [[SGFilterConfiguration alloc] init]; _subtitles = @[]; _danmaku = @[]; _watermarks = @[];
        _watermarksEnabled = YES; _subtitlesEnabled = YES; _danmakuEnabled = YES; _maximumDanmakuCount = 40; _textSize = 28; _textColorRGB=0xffffff; _textBackgroundColorRGB=0; _textBackgroundOpacity=.65; _overlayOpacity = 1;
        _subtitleVerticalPosition=.06;_secondarySubtitleVerticalPosition=.80;
        _subtitleFallbackFontURL = [[NSBundle bundleForClass:SGMediaEffects.class] URLForResource:@"NotoSansCJKsc-Regular" withExtension:@"otf"];
        _stickerRect = CGRectMake(0.05, 0.05, 0.2, 0.2);
        _context = [CIContext contextWithOptions:@{kCIContextCacheIntermediates: @NO}];
        _textCache = [[NSCache alloc] init]; _textCache.totalCostLimit = 16 * 1024 * 1024;
    } return self;
}
- (void)dealloc { if (_assTrack) ass_free_track(_assTrack); if (_assRenderer) ass_renderer_done(_assRenderer); if (_assLibrary) ass_library_done(_assLibrary); if (_graph) avfilter_graph_free(&_graph); if (_pixelPool) CVPixelBufferPoolRelease(_pixelPool); if(_cubeFileURL)[NSFileManager.defaultManager removeItemAtURL:_cubeFileURL error:nil]; }
- (SGMediaEffects *)snapshot {
    @synchronized(self){
        SGMediaEffects *copy=[SGMediaEffects new];copy.kernel=self.kernel;copy.softwareRendering=self.softwareRendering;copy.filter=self.filter;
        copy.subtitleTrack=SGSnapshotTrack(self.subtitleTrack);copy.secondarySubtitleTrack=SGSnapshotTrack(self.secondarySubtitleTrack);copy.subtitles=SGSnapshotCues(self.subtitles);copy.subtitlesEnabled=self.subtitlesEnabled;
        copy.subtitleOffset=self.subtitleOffset;copy.secondarySubtitleOffset=self.secondarySubtitleOffset;copy.subtitleVerticalPosition=self.subtitleVerticalPosition;copy.secondarySubtitleVerticalPosition=self.secondarySubtitleVerticalPosition;copy.subtitleFallbackFontURL=self.subtitleFallbackFontURL;
        NSMutableArray *events=[NSMutableArray array];for(SGDanmakuItem *item in self.danmaku){SGDanmakuItem *event=[SGDanmakuItem new];event.start=item.start;event.duration=item.duration;event.mode=item.mode;event.text=item.text;event.fontSize=item.fontSize;event.rgbColor=item.rgbColor;[events addObject:event];}
        copy.danmaku=events;copy.danmakuEnabled=self.danmakuEnabled;copy.maximumDanmakuCount=self.maximumDanmakuCount;copy.textSize=self.textSize;copy.textColorRGB=self.textColorRGB;copy.textBackgroundEnabled=self.textBackgroundEnabled;copy.textBackgroundColorRGB=self.textBackgroundColorRGB;copy.textBackgroundOpacity=self.textBackgroundOpacity;copy.overlayOpacity=self.overlayOpacity;
        NSMutableArray *marks=[NSMutableArray array];for(SGWatermark *mark in self.watermarks){SGWatermark *item=[SGWatermark new];item.text=mark.text;item.image=mark.image;item.rect=mark.rect;item.opacity=mark.opacity;[marks addObject:item];}
        copy.watermarks=marks;copy.watermarksEnabled=self.watermarksEnabled;copy.sticker=self.sticker;copy.stickerRect=self.stickerRect;copy.stickerStart=self.stickerStart;return copy;
    }
}
- (void)flush { @synchronized (self) { if (_graph) avfilter_graph_free(&_graph); _source = NULL; _sink = NULL; self.graphKey = nil; self.lastError = nil; } }
- (BOOL)active { return self.filter.active || (self.subtitlesEnabled && (self.subtitles.count||self.secondarySubtitleTrack.cues.count)) || (self.danmakuEnabled && self.danmaku.count) || (self.watermarksEnabled && self.watermarks.count) || self.sticker; }
- (CIImage *)textImage:(NSString *)text size:(CGFloat)size width:(CGFloat)width {
    return [self textImage:text size:size width:width color:self.textColorRGB];
}
- (CIImage *)textImage:(NSString *)text size:(CGFloat)size width:(CGFloat)width color:(NSUInteger)rgb {
    if (!text.length || text.length > 8192 || width <= 0) return nil;
    size=MIN(512,MAX(1,size));width=MIN(8192,ceil(width));
    NSString *key=[NSString stringWithFormat:@"%@|%.2f|%.1f|%lu|%d|%lu|%.3f",text,size,width,(unsigned long)rgb,self.textBackgroundEnabled,(unsigned long)self.textBackgroundColorRGB,self.textBackgroundOpacity];
    CIImage *cached=[self.textCache objectForKey:key];if(cached)return cached;
    CTFontRef font=CTFontCreateWithName(CFSTR("Helvetica"),size,NULL);
    CGColorSpaceRef space=CGColorSpaceCreateDeviceRGB();
    CGFloat components[4]={((rgb>>16)&255)/255.0,((rgb>>8)&255)/255.0,(rgb&255)/255.0,1};
    CGColorRef color=CGColorCreate(space,components);
    NSDictionary *attributes=@{(__bridge NSString *)kCTFontAttributeName:(__bridge id)font,(__bridge NSString *)kCTForegroundColorAttributeName:(__bridge id)color};
    NSAttributedString *string=[[NSAttributedString alloc]initWithString:text attributes:attributes];
    CTFramesetterRef setter=CTFramesetterCreateWithAttributedString((__bridge CFAttributedStringRef)string);
    CGFloat pad=MAX(1,ceil(size*.2));
    CGSize measured=CTFramesetterSuggestFrameSizeWithConstraints(setter,CFRangeMake(0,0),NULL,CGSizeMake(MAX(1,width-2*pad),4096),NULL);
    size_t bitmapWidth=MAX(1,MIN(width,ceil(measured.width+2*pad))),height=MIN(4096,MAX(1,ceil(measured.height+2*pad)));
    CGContextRef ctx=CGBitmapContextCreate(NULL,bitmapWidth,height,8,bitmapWidth*4,space,kCGImageAlphaPremultipliedLast);
    CIImage *image=nil;
    if(ctx){
        CGContextSetShouldAntialias(ctx,YES);
        if(self.textBackgroundEnabled){
            NSUInteger bg=self.textBackgroundColorRGB;
            CGContextSetRGBFillColor(ctx,((bg>>16)&255)/255.0,((bg>>8)&255)/255.0,(bg&255)/255.0,self.textBackgroundOpacity);
            CGFloat radius=MIN(bitmapWidth,height)/2.0;
            CGPathRef capsule=CGPathCreateWithRoundedRect(CGRectMake(0,0,bitmapWidth,height),radius,radius,NULL);
            CGContextAddPath(ctx,capsule);CGContextFillPath(ctx);CGPathRelease(capsule);
        }
        CGPathRef path=CGPathCreateWithRect(CGRectMake(pad,pad,MAX(1,bitmapWidth-2*pad),MAX(1,height-2*pad)),NULL);
        CTFrameRef frame=CTFramesetterCreateFrame(setter,CFRangeMake(0,0),path,NULL);CTFrameDraw(frame,ctx);
        CGImageRef cg=CGBitmapContextCreateImage(ctx);image=[CIImage imageWithCGImage:cg];
        CGImageRelease(cg);CFRelease(frame);CGPathRelease(path);CGContextRelease(ctx);
    }
    CFRelease(setter);CGColorRelease(color);CGColorSpaceRelease(space);CFRelease(font);
    if(image)[self.textCache setObject:image forKey:key cost:bitmapWidth*height*4];return image;
}
- (CIImage *)place:(CIImage *)overlay rect:(CGRect)rect opacity:(CGFloat)opacity on:(CIImage *)background {
    if (!overlay || CGRectIsEmpty(rect) || !isfinite(opacity)) return background;
    CGRect extent = overlay.extent;
    if (CGRectIsEmpty(extent)) return background;
    overlay = [overlay imageByApplyingTransform:CGAffineTransformMakeTranslation(-extent.origin.x, -extent.origin.y)];
    overlay = [overlay imageByApplyingTransform:CGAffineTransformMakeScale(rect.size.width / extent.size.width, rect.size.height / extent.size.height)];
    overlay = [[overlay imageByApplyingTransform:CGAffineTransformMakeTranslation(rect.origin.x, rect.origin.y)] imageByCroppingToRect:rect];
    overlay = [overlay imageByApplyingFilter:@"CIColorMatrix" withInputParameters:@{@"inputAVector": [CIVector vectorWithX:0 Y:0 Z:0 W:MIN(1, MAX(0, opacity))]}];
    return [overlay imageByCompositingOverImage:background];
}
- (CIImage *)FFmpegFilter:(CIImage *)image config:(SGFilterConfiguration *)config time:(CMTime)time {
    int width = CGRectGetWidth(image.extent), height = CGRectGetHeight(image.extent);
    NSMutableArray *filters = [NSMutableArray arrayWithObject:@"format=rgba"];
    double saturation = config.grayscale ? 0 : config.saturation;
    if (saturation != 1) {
        double r = (1 - saturation) * 0.2126, g = (1 - saturation) * 0.7152, b = (1 - saturation) * 0.0722;
        [filters addObject:[NSString stringWithFormat:@"colorchannelmixer=rr=%.8f:rg=%.8f:rb=%.8f:gr=%.8f:gg=%.8f:gb=%.8f:br=%.8f:bg=%.8f:bb=%.8f", r+saturation, g, b, r, g+saturation, b, r, g, b+saturation]];
    }
    if (config.brightness != 0 || config.contrast != 1) {
        NSString *expression = [NSString stringWithFormat:@"'clip((val-128)*%.8f+128+%.8f,0,255)'", config.contrast, config.brightness * 255];
        [filters addObject:[NSString stringWithFormat:@"lutrgb=r=%@:g=%@:b=%@", expression, expression, expression]];
    }
    if (config.colorCurves.length) {
        NSUInteger count=config.colorCurves.length/(3*sizeof(float)); const float *values=config.colorCurves.bytes;
        NSMutableArray *expressions=[NSMutableArray array];
        for(NSUInteger channel=0;channel<3;channel++) {
            NSString *expression=[NSString stringWithFormat:@"%.8f",255.0*values[(count-1)*3+channel]];
            for(NSInteger i=(NSInteger)count-2;i>=0;i--) {
                double start=i*255.0/(count-1),end=(i+1)*255.0/(count-1),value=values[i*3+channel]*255.0,slope=(values[(i+1)*3+channel]-values[i*3+channel])*(count-1);
                expression=[NSString stringWithFormat:@"if(lte(val,%.8f),%.8f+(val-%.8f)*%.8f,%@)",end,value,start,slope,expression];
            }
            [expressions addObject:expression];
        }
        [filters addObject:[NSString stringWithFormat:@"lutrgb=r='%@':g='%@':b='%@'",expressions[0],expressions[1],expressions[2]]];
    }
    if (config.horizontalFlip) [filters addObject:@"hflip"];
    if (config.verticalFlip) [filters addObject:@"vflip"];
    if (config.blurRadius > 0) [filters addObject:[NSString stringWithFormat:@"gblur=sigma=%.4f", config.blurRadius]];
    if(config.colorCube.length){
        if(![self.cubeFileData isEqual:config.colorCube]||self.cubeFileDimension!=config.colorCubeDimension){
            NSURL *URL=[[NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES] URLByAppendingPathComponent:[NSString stringWithFormat:@"sgplayer-%@.cube",NSUUID.UUID.UUIDString]];
            NSMutableString *text=[NSMutableString stringWithFormat:@"LUT_3D_SIZE %lu\n",(unsigned long)config.colorCubeDimension];const float *values=config.colorCube.bytes;
            for(NSUInteger i=0;i<config.colorCube.length/sizeof(float);i+=4)[text appendFormat:@"%.9g %.9g %.9g\n",values[i],values[i+1],values[i+2]];
            NSError *failure=nil;if(![text writeToURL:URL atomically:YES encoding:NSUTF8StringEncoding error:&failure]){self.lastError=failure;return nil;}
            if(self.cubeFileURL)[NSFileManager.defaultManager removeItemAtURL:self.cubeFileURL error:nil];
            self.cubeFileURL=URL;self.cubeFileData=config.colorCube;self.cubeFileDimension=config.colorCubeDimension;
        }
        NSString *path=[[self.cubeFileURL.path stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"] stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"];
        [filters addObject:[NSString stringWithFormat:@"lut3d=file='%@':interp=trilinear",path]];
    }
    if(config.bloomIntensity>0)[filters addObject:[NSString stringWithFormat:@"split=2[sgbase][sgglow];[sgglow]gblur=sigma=%.4f[sgblur];[sgbase][sgblur]blend=all_mode=screen:all_opacity=%.6f",MAX(.001,config.bloomRadius),config.bloomIntensity]];
    [filters addObject:@"format=bgra"];
    NSString *chain = [filters componentsJoinedByString:@","];
    NSString *key = [NSString stringWithFormat:@"%d:%d:%@", width, height, chain];
    int status = 0;
    if (![self.graphKey isEqual:key]) {
        if (_graph) avfilter_graph_free(&_graph);
        _graph = avfilter_graph_alloc(); _source = NULL; _sink = NULL;
        if (!_graph) return nil;
        _graph->nb_threads = 2;
        NSString *arguments = [NSString stringWithFormat:@"video_size=%dx%d:pix_fmt=%d:time_base=1/1000000:pixel_aspect=1/1", width, height, AV_PIX_FMT_BGRA];
        status = avfilter_graph_create_filter(&_source, avfilter_get_by_name("buffer"), "input", arguments.UTF8String, NULL, _graph);
        if (status >= 0) status = avfilter_graph_create_filter(&_sink, avfilter_get_by_name("buffersink"), "output", NULL, NULL, _graph);
        AVFilterInOut *inputs = avfilter_inout_alloc(), *outputs = avfilter_inout_alloc();
        if (!inputs || !outputs) status = AVERROR(ENOMEM);
        if (status >= 0) {
            outputs->name = av_strdup("in"); outputs->filter_ctx = _source; outputs->pad_idx = 0;
            inputs->name = av_strdup("out"); inputs->filter_ctx = _sink; inputs->pad_idx = 0;
            status = avfilter_graph_parse_ptr(_graph, chain.UTF8String, &inputs, &outputs, NULL);
            if (status >= 0) status = avfilter_graph_config(_graph, NULL);
        }
        avfilter_inout_free(&inputs); avfilter_inout_free(&outputs);
        if (status < 0) { avfilter_graph_free(&_graph); self.lastError = SGEffectError(status, @"Unable to configure FFmpeg filter graph"); return nil; }
        self.graphKey = key;
    }
    AVFrame *input = av_frame_alloc(), *output = av_frame_alloc();
    if (!input || !output) { av_frame_free(&input); av_frame_free(&output); return nil; }
    input->format = AV_PIX_FMT_BGRA; input->width = width; input->height = height;
    input->pts = CMTIME_IS_NUMERIC(time) ? CMTimeConvertScale(time, 1000000, kCMTimeRoundingMethod_Default).value : 0;
    status = av_frame_get_buffer(input, 32);
    CIImage *result = nil;
    if (status >= 0) {
        CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
        [self.context render:image toBitmap:input->data[0] rowBytes:input->linesize[0] bounds:CGRectMake(0, 0, width, height) format:kCIFormatBGRA8 colorSpace:space];
        CGColorSpaceRelease(space);
        status = av_buffersrc_add_frame_flags(_source, input, AV_BUFFERSRC_FLAG_KEEP_REF);
        if (status >= 0) status = av_buffersink_get_frame(_sink, output);
        if (status >= 0) {
            NSData *data = [NSData dataWithBytes:output->data[0] length:(NSUInteger)output->linesize[0] * height];
            CGColorSpaceRef rgb = CGColorSpaceCreateDeviceRGB();
            result = [CIImage imageWithBitmapData:data bytesPerRow:output->linesize[0] size:CGSizeMake(width, height) format:kCIFormatBGRA8 colorSpace:rgb];
            CGColorSpaceRelease(rgb);
        }
    }
    if (status < 0) self.lastError = SGEffectError(status, @"FFmpeg filter frame processing failed");
    av_frame_free(&input); av_frame_free(&output); return result;
}
- (CIImage *)renderASSOver:(CIImage *)image atTime:(double)seconds {
    SGSubtitleTrack *track=self.subtitleTrack;
    if(!track.ASSHeader.length) return image;
    if(!_assLibrary) {
        _assLibrary=ass_library_init();
        if(_assLibrary) _assRenderer=ass_renderer_init(_assLibrary);
        if(!_assLibrary || !_assRenderer){self.lastError=SGEffectError(7,@"Cannot initialize ASS renderer");return nil;}
        ass_set_cache_limits(_assRenderer,1000,16);
    }
    if (_assCues!=self.subtitles || _assSource!=track || (_assFallbackFontURL!=self.subtitleFallbackFontURL && ![_assFallbackFontURL isEqual:self.subtitleFallbackFontURL])) {
        if(_assTrack)ass_free_track(_assTrack);
        ass_clear_fonts(_assLibrary);
        // Register the fallback with libass itself. CoreText may advertise an
        // inaccessible system CJK font before the path fallback is considered.
        NSData *fallback=self.subtitleFallbackFontURL.isFileURL ? [NSData dataWithContentsOfURL:self.subtitleFallbackFontURL options:NSDataReadingMappedIfSafe error:nil] : nil;
        if (fallback.length && fallback.length<=32*1024*1024)
            ass_add_font(_assLibrary,"SGPlayerFallback.otf",fallback.bytes,(int)fallback.length);
        for(NSString *name in track.fonts) {
            NSData *font=track.fonts[name];
            if(font.length<=16*1024*1024)ass_add_font(_assLibrary,name.UTF8String,font.bytes,(int)font.length);
        }
        _assTrack=ass_new_track(_assLibrary);
        if(!_assTrack){self.lastError=SGEffectError(8,@"Cannot allocate ASS track");return nil;}
        ass_process_codec_private(_assTrack,track.ASSHeader.bytes,(int)track.ASSHeader.length);
        for(SGSubtitleCue *cue in self.subtitles) {
            if(!cue.ASS.length)continue;
            NSData *chunk=[cue.ASS dataUsingEncoding:NSUTF8StringEncoding];
            double start=CMTimeGetSeconds(cue.start),duration=CMTimeGetSeconds(cue.duration);
            if(!isfinite(start)||!isfinite(duration)||duration<=0)continue;
            ass_process_chunk(_assTrack,chunk.bytes,(int)chunk.length,llround(start*1000),llround(duration*1000));
        }
        ass_set_fonts(_assRenderer,self.subtitleFallbackFontURL.fileSystemRepresentation,"Noto Sans CJK SC",ASS_FONTPROVIDER_CORETEXT,NULL,1);
        _assFallbackFontURL=self.subtitleFallbackFontURL;
        _assCues=self.subtitles;_assSource=track;
    }
    int width=CGRectGetWidth(image.extent),height=CGRectGetHeight(image.extent),changed=0;
    ass_set_frame_size(_assRenderer,width,height);ass_set_storage_size(_assRenderer,width,height);
    ASS_Image *glyph=ass_render_frame(_assRenderer,_assTrack,llround((seconds-self.subtitleOffset)*1000),&changed);
    CGColorSpaceRef space=CGColorSpaceCreateDeviceRGB();
    for(;glyph;glyph=glyph->next) {
        if(glyph->w<=0||glyph->h<=0||glyph->w>8192||glyph->h>8192)continue;
        NSMutableData *rgba=[NSMutableData dataWithLength:(NSUInteger)glyph->w*glyph->h*4];uint8_t *pixels=rgba.mutableBytes;
        unsigned r=glyph->color>>24,g=(glyph->color>>16)&255,b=(glyph->color>>8)&255,a=255-(glyph->color&255);
        for(int y=0;y<glyph->h;y++)for(int x=0;x<glyph->w;x++) {
            unsigned alpha=glyph->bitmap[y*glyph->stride+x]*a/255;
            NSUInteger i=((NSUInteger)y*glyph->w+x)*4;
            pixels[i]=r*alpha/255;pixels[i+1]=g*alpha/255;pixels[i+2]=b*alpha/255;pixels[i+3]=alpha;
        }
        CIImage *overlay=[CIImage imageWithBitmapData:rgba bytesPerRow:glyph->w*4 size:CGSizeMake(glyph->w,glyph->h) format:kCIFormatRGBA8 colorSpace:space];
        overlay=[overlay imageByApplyingTransform:CGAffineTransformMakeTranslation(glyph->dst_x,height-glyph->dst_y-glyph->h)];
        overlay=[overlay imageByApplyingFilter:@"CIColorMatrix" withInputParameters:@{@"inputAVector":[CIVector vectorWithX:0 Y:0 Z:0 W:self.overlayOpacity]}];
        image=[overlay imageByCompositingOverImage:image];
    }
    CGColorSpaceRelease(space);return image;
}
- (CIImage *)composeImage:(CIImage *)source atTime:(CMTime)time {
    @synchronized (self) {
        if (self.contextUsesSoftware != self.softwareRendering) {
            self.context = [CIContext contextWithOptions:@{kCIContextCacheIntermediates:@NO,kCIContextUseSoftwareRenderer:@(self.softwareRendering)}];
            self.contextUsesSoftware = self.softwareRendering;
        }
        SGFilterConfiguration *config = self.filter;
        self.lastError = [config validationError]; if (self.lastError) return nil;
        if (self.textColorRGB>0xffffff || self.textBackgroundColorRGB>0xffffff || !isfinite(self.textBackgroundOpacity) || self.textBackgroundOpacity<0 || self.textBackgroundOpacity>1 || !isfinite(self.textSize) || self.textSize < 8 || self.textSize > 96 || !isfinite(self.overlayOpacity) || self.overlayOpacity < 0 || self.overlayOpacity > 1 || !isfinite(self.subtitleOffset) || !isfinite(self.secondarySubtitleOffset) || !isfinite(self.subtitleVerticalPosition) || self.subtitleVerticalPosition<0 || self.subtitleVerticalPosition>1 || !isfinite(self.secondarySubtitleVerticalPosition) || self.secondarySubtitleVerticalPosition<0 || self.secondarySubtitleVerticalPosition>1) { self.lastError = SGEffectError(5,@"Invalid overlay size, opacity, position or offset"); return nil; }
        CGRect bounds = source.extent;
        if (!isfinite(bounds.size.width) || !isfinite(bounds.size.height) || bounds.size.width < 1 || bounds.size.height < 1 || bounds.size.width > 8192 || bounds.size.height > 8192) { self.lastError = SGEffectError(4, @"Unsupported canvas dimensions"); return nil; }
        CIImage *image = [source imageByApplyingTransform:CGAffineTransformMakeTranslation(-bounds.origin.x, -bounds.origin.y)];
        bounds.origin = CGPointZero;
        if (config.active) {
            if (self.kernel == SGPlaybackKernelFFmpeg) image = [self FFmpegFilter:image config:config time:time];
            else {
                image = [image imageByApplyingFilter:@"CIColorControls" withInputParameters:@{kCIInputBrightnessKey: @(config.brightness), kCIInputContrastKey: @(config.contrast), kCIInputSaturationKey: @(config.grayscale ? 0 : config.saturation)}];
                if (config.colorCurves.length) image=[image imageByApplyingFilter:@"CIColorCurves" withInputParameters:@{@"inputCurvesData":config.colorCurves,@"inputCurvesDomain":[CIVector vectorWithX:0 Y:1]}];
                if (config.horizontalFlip) image = [image imageByApplyingTransform:CGAffineTransformMake(-1, 0, 0, 1, bounds.size.width, 0)];
                if (config.verticalFlip) image = [image imageByApplyingTransform:CGAffineTransformMake(1, 0, 0, -1, 0, bounds.size.height)];
                if (config.blurRadius > 0) image = [[[image imageByClampingToExtent] imageByApplyingFilter:@"CIGaussianBlur" withInputParameters:@{kCIInputRadiusKey: @(config.blurRadius)}] imageByCroppingToRect:bounds];
                if(config.colorCube.length)image=[image imageByApplyingFilter:@"CIColorCube" withInputParameters:@{@"inputCubeDimension":@(config.colorCubeDimension),@"inputCubeData":config.colorCube}];
                if(config.bloomIntensity>0)image=[[[image imageByClampingToExtent] imageByApplyingFilter:@"CIBloom" withInputParameters:@{kCIInputRadiusKey:@(config.bloomRadius),kCIInputIntensityKey:@(config.bloomIntensity)}] imageByCroppingToRect:bounds];
            }
            if (!image) return nil;
        }
        double seconds = CMTIME_IS_NUMERIC(time) ? CMTimeGetSeconds(time) : 0;
        CGFloat w = bounds.size.width, h = bounds.size.height;
        CGFloat fontSize = MIN(MAX(self.textSize, 8), 96) * w / 720.0, opacity = MIN(MAX(self.overlayOpacity, 0), 1);
        if (self.subtitlesEnabled && self.subtitleTrack.ASSHeader.length) {
            image=[self renderASSOver:image atTime:seconds];
            if(!image)return nil;
        }
        if (self.subtitlesEnabled) {
            CGFloat bottom = h * self.subtitleVerticalPosition;
            for (SGSubtitleCue *cue in self.subtitles) {
                double start = CMTimeGetSeconds(cue.start) + self.subtitleOffset, duration = CMTimeGetSeconds(cue.duration);
                if (!isfinite(start) || !isfinite(duration) || seconds < start || seconds >= start + duration) continue;
                if (cue.bitmap) {
                    CGRect r = cue.region;
                    image = [self place:cue.bitmap rect:CGRectMake(r.origin.x*w, (1-r.origin.y-r.size.height)*h, r.size.width*w, r.size.height*h) opacity:opacity on:image];
                } else if (!self.subtitleTrack.ASSHeader.length || !cue.ASS.length) {
                    CIImage *text = [self textImage:cue.text size:fontSize width:w * 0.9];
                    image = [self place:text rect:CGRectMake((w-text.extent.size.width)/2, bottom, text.extent.size.width, text.extent.size.height) opacity:opacity on:image];
                    bottom += text.extent.size.height + 4;
                }
            }
        }
        if(self.subtitlesEnabled&&self.secondarySubtitleTrack){
            if(!self.secondaryRenderer)self.secondaryRenderer=[SGMediaEffects new];
            SGMediaEffects *secondary=self.secondaryRenderer;secondary.softwareRendering=self.softwareRendering;
            secondary.subtitleTrack=self.secondarySubtitleTrack;secondary.subtitles=self.secondarySubtitleTrack.cues;
            secondary.subtitleOffset=self.secondarySubtitleOffset;secondary.subtitleVerticalPosition=self.secondarySubtitleVerticalPosition;
            secondary.textSize=self.textSize;secondary.textColorRGB=self.textColorRGB;secondary.textBackgroundEnabled=self.textBackgroundEnabled;secondary.textBackgroundColorRGB=self.textBackgroundColorRGB;secondary.textBackgroundOpacity=self.textBackgroundOpacity;secondary.overlayOpacity=self.overlayOpacity;secondary.subtitleFallbackFontURL=self.subtitleFallbackFontURL;
            image=[secondary composeImage:image atTime:time];if(!image){self.lastError=secondary.lastError;return nil;}
        }else self.secondaryRenderer=nil;
        if (self.danmakuEnabled) {
            // Reconstruct deterministic lanes from media time, including after seeks.
            NSMutableArray *laneEnd = [NSMutableArray array];
            NSUInteger lanes = MAX(1, MIN(64, (NSUInteger)(h * 0.65 / (fontSize + 8))));
            for (NSUInteger i = 0; i < lanes; i++) [laneEnd addObject:@(-DBL_MAX)];
            NSUInteger visible = 0;
            if (self.sortedDanmakuSource != self.danmaku) {
                self.sortedDanmakuSource = self.danmaku;
                self.sortedDanmaku = [self.danmaku sortedArrayUsingComparator:^NSComparisonResult(SGDanmakuItem *a, SGDanmakuItem *b) { return CMTimeCompare(a.start,b.start) < 0 ? NSOrderedAscending : CMTimeCompare(a.start,b.start) > 0 ? NSOrderedDescending : NSOrderedSame; }];
            }
            NSArray *events = self.sortedDanmaku;
            for (SGDanmakuItem *item in events) {
                double start = CMTimeGetSeconds(item.start), duration = MIN(60, MAX(0.2, item.duration));
                if (!isfinite(start)) continue;
                if (start > seconds) break;
                NSUInteger lane = NSNotFound;
                NSUInteger firstLane = item.mode == SGDanmakuModeTop ? 0 : item.mode == SGDanmakuModeBottom ? lanes * 2 / 3 : lanes / 3;
                NSUInteger lastLane = item.mode == SGDanmakuModeTop ? MAX(1,lanes / 3) : item.mode == SGDanmakuModeBottom ? lanes : MAX(firstLane+1,lanes*2/3);
                for (NSUInteger i = firstLane; i < MIN(lanes,lastLane); i++) if ([laneEnd[i] doubleValue] <= start) { lane = i; break; }
                if (lane == NSNotFound) continue;
                laneEnd[lane] = @(start + duration); // Stable assignments survive seeks and event expiry.
                if (seconds >= start + duration || visible >= MIN(200,self.maximumDanmakuCount)) continue;
                CGFloat itemSize = item.fontSize > 0 ? MIN(96,MAX(8,item.fontSize))*w/720.0 : fontSize;
                CGFloat textWidth = MIN(w * 1.5, MAX(itemSize, item.text.length * itemSize * 0.8));
                CIImage *text = [self textImage:[item.text stringByReplacingOccurrencesOfString:@"\n" withString:@" "] size:itemSize width:textWidth color:item.rgbColor];
                textWidth=text.extent.size.width;
                double phase=(seconds-start)/duration;
                CGFloat x = item.mode == SGDanmakuModeScrolling ? w-(w+textWidth)*phase : item.mode==SGDanmakuModeReverse ? -textWidth+(w+textWidth)*phase : (w-textWidth)/2;
                CGFloat y = h * 0.9 - (lane + 1) * (fontSize + 8);
                image = [self place:text rect:CGRectMake(x, y, text.extent.size.width, text.extent.size.height) opacity:opacity on:image]; visible++;
            }
        }
        for (SGWatermark *mark in (self.watermarksEnabled ? self.watermarks : @[])) {
            CGRect r = mark.rect;
            CGRect target=CGRectMake(r.origin.x*w,(1-r.origin.y-r.size.height)*h,r.size.width*w,r.size.height*h);
            CIImage *overlay=mark.image ?: [self textImage:mark.text size:MIN(fontSize,target.size.height*.7) width:MAX(1,target.size.width)];
            if(overlay && !CGRectIsEmpty(overlay.extent) && !CGRectIsEmpty(target)) {
                // Preserve aspect ratio. Render text at final pixel size instead
                // of stretching a small glyph bitmap to the watermark rectangle.
                CGFloat factor=MIN(target.size.width/overlay.extent.size.width,target.size.height/overlay.extent.size.height);
                factor=MIN(1,factor); // Never enlarge a low-resolution watermark bitmap.
                CGSize fitted=CGSizeMake(overlay.extent.size.width*factor,overlay.extent.size.height*factor);
                CGRect rect=CGRectMake(target.origin.x,target.origin.y+(target.size.height-fitted.height)/2,fitted.width,fitted.height);
                image=[self place:overlay rect:rect opacity:mark.opacity on:image];
            }
        }
        CIImage *sticker = [self.sticker imageAtTime:seconds - self.stickerStart];
        CGRect r = self.stickerRect;
        if (sticker) image = [self place:sticker rect:CGRectMake(r.origin.x*w,(1-r.origin.y-r.size.height)*h,r.size.width*w,r.size.height*h) opacity:opacity on:image];
        return [image imageByCroppingToRect:bounds];
    }
}
- (CVPixelBufferRef)copyPixelBufferForImage:(CIImage *)image atTime:(CMTime)time {
    @synchronized (self) {
        CIImage *composed = [self composeImage:image atTime:time]; if (!composed) return NULL;
        CVPixelBufferRef buffer = NULL;
        CGSize size = composed.extent.size;
        if (!_pixelPool || !CGSizeEqualToSize(_poolSize, size)) {
            if (_pixelPool) CVPixelBufferPoolRelease(_pixelPool);
            _pixelPool = NULL;
            NSDictionary *attributes = @{(id)kCVPixelBufferIOSurfacePropertiesKey: @{}, (id)kCVPixelBufferMetalCompatibilityKey: @YES,
                (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA), (id)kCVPixelBufferWidthKey: @((NSInteger)size.width), (id)kCVPixelBufferHeightKey: @((NSInteger)size.height)};
            if (CVPixelBufferPoolCreate(NULL,NULL,(__bridge CFDictionaryRef)attributes,&_pixelPool) != kCVReturnSuccess) return NULL;
            _poolSize = size;
        }
        NSDictionary *budget = @{(id)kCVPixelBufferPoolAllocationThresholdKey:@6};
        if (CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(NULL,_pixelPool,(__bridge CFDictionaryRef)budget,&buffer) != kCVReturnSuccess) return NULL;
        CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
        [self.context render:composed toCVPixelBuffer:buffer bounds:composed.extent colorSpace:space];
        CGColorSpaceRelease(space); return buffer;
    }
}
- (CGImageRef)copyImageAtTime:(CMTime)time source:(CIImage *)image {
    @synchronized (self) { CIImage *output = [self composeImage:image atTime:time]; return output ? [self.context createCGImage:output fromRect:output.extent] : NULL; }
}
@end
