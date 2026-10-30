#import "SGMediaEffects.h"
#import "SGFFmpeg.h"
#import <stdatomic.h>

@implementation SGSubtitleCue
- (instancetype)init { if ((self = [super init])) { _text = @""; _start = kCMTimeZero; _duration = kCMTimeZero; } return self; }
@end
@implementation SGSubtitleTrack
- (instancetype)init { if ((self = [super init])) { _language = @"und"; _title = @""; _cues = @[]; _fonts = @{}; } return self; }
@end
@implementation SGDanmakuItem
- (instancetype)init { if ((self = [super init])) { _text = @""; _start = kCMTimeZero; _duration = 6; _rgbColor = 0xffffff; } return self; }
@end
@implementation SGWatermark
- (instancetype)init { if ((self = [super init])) { _text = @""; _rect = CGRectMake(0.7, 0.04, 0.25, 0.08); _opacity = 1; } return self; }
@end


@interface SGXMLDanmakuParser : NSObject <NSXMLParserDelegate>
@property(nonatomic,strong) NSMutableArray<SGDanmakuItem *> *items;
@property(nonatomic,strong) SGDanmakuItem *current;
@property(nonatomic,strong) NSMutableString *text;
@end
@implementation SGXMLDanmakuParser
- (void)parser:(NSXMLParser *)parser didStartElement:(NSString *)name namespaceURI:(NSString *)uri qualifiedName:(NSString *)qualified attributes:(NSDictionary<NSString *,NSString *> *)attributes {
    if (![name isEqual:@"d"]) return;
    NSArray<NSString *> *fields=[attributes[@"p"] componentsSeparatedByString:@","];
    if (fields.count < 2) return;
    double seconds=0;NSScanner *scanner=[NSScanner scannerWithString:fields[0]];
    if (![scanner scanDouble:&seconds] || !scanner.isAtEnd || !isfinite(seconds) || seconds < 0) return;
    NSInteger mode=fields[1].integerValue;
    if (mode < 1 || mode > 6) return;
    self.current=[SGDanmakuItem new];self.text=[NSMutableString string];
    self.current.start=CMTimeMakeWithSeconds(seconds,600);
    self.current.mode=mode==4?SGDanmakuModeBottom:mode==5?SGDanmakuModeTop:mode==6?SGDanmakuModeReverse:SGDanmakuModeScrolling;
    if(fields.count>2)self.current.fontSize=MIN(96,MAX(8,fields[2].doubleValue));
    if(fields.count>3)self.current.rgbColor=fields[3].longLongValue&0xffffff;
}
- (void)parser:(NSXMLParser *)parser foundCharacters:(NSString *)text { [self.text appendString:text]; }
- (void)parser:(NSXMLParser *)parser foundCDATA:(NSData *)data { NSString *text=[[NSString alloc]initWithData:data encoding:NSUTF8StringEncoding];if(text)[self.text appendString:text]; }
- (void)parser:(NSXMLParser *)parser didEndElement:(NSString *)name namespaceURI:(NSString *)uri qualifiedName:(NSString *)qualified {
    if(![name isEqual:@"d"])return;
    if(self.current&&self.text.length){self.current.text=self.text;[self.items addObject:self.current];}
    self.current=nil;self.text=nil;
}
@end
@implementation SGDanmakuReader
+ (NSArray<SGDanmakuItem *> *)readURL:(NSURL *)URL error:(NSError **)error {
    NSData *data=[NSData dataWithContentsOfURL:URL options:0 error:error];if(!data)return nil;
    NSXMLParser *parser=[[NSXMLParser alloc]initWithData:data];
    parser.shouldResolveExternalEntities=NO;parser.externalEntityResolvingPolicy=NSXMLParserResolveExternalEntitiesNever;
    SGXMLDanmakuParser *delegate=[SGXMLDanmakuParser new];delegate.items=[NSMutableArray array];parser.delegate=delegate;
    if(![parser parse]){if(error)*error=parser.parserError;return nil;}
    return [delegate.items copy];
}
@end

static NSString *SGSubtitlePlainText(NSString *ass)
{
    // FFmpeg's subtitle decoder returns the ASS event body with eight fields.
    NSArray *parts = [ass componentsSeparatedByString:@","];
    NSString *text = parts.count >= 9 ? [[parts subarrayWithRange:NSMakeRange(8, parts.count - 8)] componentsJoinedByString:@","] : ass;
    NSRegularExpression *tags = [NSRegularExpression regularExpressionWithPattern:@"\\{[^}]*\\}" options:0 error:nil];
    text = [tags stringByReplacingMatchesInString:text options:0 range:NSMakeRange(0, text.length) withTemplate:@""];
    return [[[text stringByReplacingOccurrencesOfString:@"\\N" withString:@"\n"] stringByReplacingOccurrencesOfString:@"\\n" withString:@"\n"] stringByReplacingOccurrencesOfString:@"\\h" withString:@" "];
}

typedef struct { CFAbsoluteTime deadline; } SGSubtitleDeadline;
static int SGSubtitleInterrupt(void *opaque) { return CFAbsoluteTimeGetCurrent() > ((SGSubtitleDeadline *)opaque)->deadline; }

@implementation SGSubtitleReader
+ (NSArray<SGSubtitleTrack *> *)readURL:(NSURL *)URL error:(NSError **)error
{
    AVFormatContext *format = avformat_alloc_context();
    SGSubtitleDeadline deadline = {CFAbsoluteTimeGetCurrent() + 30};
    if (!format) return nil;
    format->interrupt_callback = (AVIOInterruptCB){SGSubtitleInterrupt, &deadline};
    AVDictionary *options = NULL;
    av_dict_set(&options, "rw_timeout", "10000000", 0);
    int status = avformat_open_input(&format, URL.isFileURL ? URL.fileSystemRepresentation : URL.absoluteString.UTF8String, NULL, &options);
    av_dict_free(&options);
    if (status >= 0) status = avformat_find_stream_info(format, NULL);
    NSMutableArray *tracks = [NSMutableArray array];
    NSMutableDictionary<NSNumber *, SGSubtitleTrack *> *byIndex = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSNumber *, NSMutableArray *> *cues = [NSMutableDictionary dictionary];
    AVCodecContext **decoders = format ? calloc(format->nb_streams, sizeof(*decoders)) : NULL;
    if (status >= 0 && !decoders) status = AVERROR(ENOMEM);
    if (status >= 0) {
        for (unsigned i = 0; i < format->nb_streams; i++) {
            AVStream *stream = format->streams[i];
            if (stream->codecpar->codec_type != AVMEDIA_TYPE_SUBTITLE) continue;
            const AVCodec *codec = avcodec_find_decoder(stream->codecpar->codec_id);
            if (!codec) { status = AVERROR_DECODER_NOT_FOUND; break; }
            decoders[i] = avcodec_alloc_context3(codec);
            if (!decoders[i]) { status = AVERROR(ENOMEM); break; }
            status = avcodec_parameters_to_context(decoders[i], stream->codecpar);
            decoders[i]->pkt_timebase = stream->time_base;
            if (status >= 0) status = avcodec_open2(decoders[i], codec, NULL);
            if (status < 0) break;
            SGSubtitleTrack *track = [[SGSubtitleTrack alloc] init];
            track.index = i;
            AVDictionaryEntry *language = av_dict_get(stream->metadata, "language", NULL, 0);
            AVDictionaryEntry *title = av_dict_get(stream->metadata, "title", NULL, 0);
            if (language) track.language = [NSString stringWithUTF8String:language->value] ?: @"und";
            if (title) track.title = [NSString stringWithUTF8String:title->value] ?: @"";
            track.defaultTrack = (stream->disposition & AV_DISPOSITION_DEFAULT) != 0;
            track.forced = (stream->disposition & AV_DISPOSITION_FORCED) != 0;
            byIndex[@(i)] = track;
            cues[@(i)] = [NSMutableArray array];
            [tracks addObject:track];
        }
    }
    NSMutableDictionary *fonts=[NSMutableDictionary dictionary];
    NSUInteger fontBytes=0;
    if (status>=0) for (unsigned i=0;i<format->nb_streams;i++) {
        AVStream *stream=format->streams[i];AVCodecParameters *parameters=stream->codecpar;
        if(parameters->codec_type==AVMEDIA_TYPE_ATTACHMENT && (parameters->codec_id==AV_CODEC_ID_TTF || parameters->codec_id==AV_CODEC_ID_OTF) && parameters->extradata && parameters->extradata_size>0) {
            if ((NSUInteger)parameters->extradata_size>16*1024*1024 || fontBytes+(NSUInteger)parameters->extradata_size>64*1024*1024) {status=AVERROR(ENOMEM);break;}
            AVDictionaryEntry *filename=av_dict_get(stream->metadata,"filename",NULL,0);
            NSString *name=filename?[NSString stringWithUTF8String:filename->value]:[NSString stringWithFormat:@"font-%u",i];
            fonts[name?:@"font"]=[NSData dataWithBytes:parameters->extradata length:parameters->extradata_size];fontBytes+=parameters->extradata_size;
        }
    }
    for (SGSubtitleTrack *track in tracks) {
        AVCodecContext *decoder=decoders[track.index];
        if(decoder->subtitle_header && decoder->subtitle_header_size>0)track.ASSHeader=[NSData dataWithBytes:decoder->subtitle_header length:decoder->subtitle_header_size];
        else if(decoder->codec_id==AV_CODEC_ID_ASS && decoder->extradata_size>0)track.ASSHeader=[NSData dataWithBytes:decoder->extradata length:decoder->extradata_size];
        track.fonts=fonts;
    }
    AVPacket *packet = av_packet_alloc();
    if (!packet && status >= 0) status = AVERROR(ENOMEM);
    NSUInteger totalCues = 0, bitmapBytes = 0;
    while (status >= 0 && (status = av_read_frame(format, packet)) >= 0) {
        int index = packet->stream_index;
        if (decoders[index]) {
            AVSubtitle subtitle = {0};
            int got = 0;
            int decoded = avcodec_decode_subtitle2(decoders[index], &subtitle, &got, packet);
            if (decoded < 0) { status = decoded; avsubtitle_free(&subtitle); break; }
            if (got) {
                AVStream *stream = format->streams[index];
                double base = subtitle.pts == AV_NOPTS_VALUE ? (packet->pts == AV_NOPTS_VALUE ? 0 : packet->pts * av_q2d(stream->time_base)) : subtitle.pts / (double)AV_TIME_BASE;
                double duration = subtitle.end_display_time > subtitle.start_display_time && subtitle.end_display_time < UINT32_MAX ? (subtitle.end_display_time - subtitle.start_display_time) / 1000.0 : packet->duration * av_q2d(stream->time_base);
                if (duration <= 0 || !isfinite(duration)) duration = 0;
                if (subtitle.num_rects==0) {
                    SGSubtitleCue *clear=[[SGSubtitleCue alloc]init];clear.start=CMTimeMakeWithSeconds(base+subtitle.start_display_time/1000.0,1000000);
                    [cues[@(index)] addObject:clear];
                }
                for (unsigned j = 0; j < subtitle.num_rects; j++) {
                    AVSubtitleRect *rect = subtitle.rects[j];
                    SGSubtitleCue *cue = [[SGSubtitleCue alloc] init];
                    cue.start = CMTimeMakeWithSeconds(base + subtitle.start_display_time / 1000.0, 1000000);
                    cue.duration = CMTimeMakeWithSeconds(duration, 1000000);
                    if (rect->ass) { cue.ASS = [NSString stringWithUTF8String:rect->ass]; cue.text = SGSubtitlePlainText(cue.ASS ?: @""); }
                    else if (rect->text) cue.text = [NSString stringWithUTF8String:rect->text] ?: @"";
                    if (rect->type == SUBTITLE_BITMAP && rect->w > 0 && rect->h > 0 && rect->w <= 8192 && rect->h <= 8192 && rect->data[0] && rect->data[1]) {
                        NSUInteger bytes = (NSUInteger)rect->w * rect->h * 4;
                        if (bytes > 64 * 1024 * 1024 || bitmapBytes + bytes > 128 * 1024 * 1024) { status = AVERROR(ENOMEM); break; }
                        NSMutableData *rgba = [NSMutableData dataWithLength:bytes];
                        uint8_t *dst = rgba.mutableBytes;
                        uint32_t *palette = (uint32_t *)rect->data[1];
                        for (int y = 0; y < rect->h; y++) for (int x = 0; x < rect->w; x++) {
                            unsigned color = rect->data[0][y * rect->linesize[0] + x];
                            uint32_t argb = color < (unsigned)rect->nb_colors ? palette[color] : 0;
                            NSUInteger pos = ((NSUInteger)y * rect->w + x) * 4;
                            dst[pos] = argb >> 16; dst[pos + 1] = argb >> 8; dst[pos + 2] = argb; dst[pos + 3] = argb >> 24;
                        }
                        CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
                        cue.bitmap = [CIImage imageWithBitmapData:rgba bytesPerRow:rect->w * 4 size:CGSizeMake(rect->w, rect->h) format:kCIFormatRGBA8 colorSpace:space];
                        CGColorSpaceRelease(space);
                        cue.region = CGRectMake(rect->x / (double)MAX(1, decoders[index]->width), rect->y / (double)MAX(1, decoders[index]->height), rect->w / (double)MAX(1, decoders[index]->width), rect->h / (double)MAX(1, decoders[index]->height));
                        bitmapBytes += bytes;
                    }
                    [cues[@(index)] addObject:cue];
                    if (++totalCues > 100000) { status = AVERROR(ENOMEM); break; }
                }
            }
            avsubtitle_free(&subtitle);
            if (status < 0) break;
        }
        av_packet_unref(packet);
    }
    if (status == AVERROR_EOF) status = 0;
    for (SGSubtitleTrack *track in tracks) track.cues = [cues[@(track.index)] sortedArrayUsingComparator:^NSComparisonResult(SGSubtitleCue *a, SGSubtitleCue *b) { int c = CMTimeCompare(a.start, b.start); return c < 0 ? NSOrderedAscending : c > 0 ? NSOrderedDescending : NSOrderedSame; }];
    for (SGSubtitleTrack *track in tracks) {
        NSArray *events=track.cues;
        for(NSUInteger i=0;i<events.count;i++) {
            SGSubtitleCue *cue=events[i];
            if(CMTimeCompare(cue.duration,kCMTimeZero)>0)continue;
            CMTime end=kCMTimeInvalid;
            for(NSUInteger j=i+1;j<events.count;j++)if(CMTimeCompare(((SGSubtitleCue *)events[j]).start,cue.start)>0){end=((SGSubtitleCue *)events[j]).start;break;}
            if(!CMTIME_IS_NUMERIC(end) && format->duration>0)end=CMTimeMake(format->duration,AV_TIME_BASE);
            CMTime resolved=CMTimeSubtract(end,cue.start);
            cue.duration=CMTIME_IS_NUMERIC(resolved)&&CMTimeCompare(resolved,kCMTimeZero)>0?resolved:CMTimeMake(3,1);
        }
    }
    av_packet_free(&packet);
    if (format && decoders) for (unsigned i = 0; i < format->nb_streams; i++) avcodec_free_context(&decoders[i]);
    free(decoders);
    avformat_close_input(&format);
    if (status < 0) {
        char text[AV_ERROR_MAX_STRING_SIZE]; av_strerror(status, text, sizeof(text));
        if (error) *error = [NSError errorWithDomain:@"SGSubtitleError" code:status userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithUTF8String:text]}];
        return nil;
    }
    return tracks;
}
@end
