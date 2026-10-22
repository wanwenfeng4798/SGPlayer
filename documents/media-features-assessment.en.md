> Historical assessment before implementation. The features are now implemented; use the [current implementation guide](media-features.en.md) and [test record](media-features-testing.en.md). The proposed designs and coverage statements below describe that earlier snapshot.

# Feasibility: subtitles, danmaku, Picture in Picture, watermarks, filters and GIF

English | [简体中文](media-features-assessment.zh-CN.md)

Assessment date: 2026-10-22. Scope: the current FFmpeg 9.0.2 / Xcode 27.1 branch, iOS 15+, macOS 12+ and tvOS 15+. This is an assessment, with no player, demo or dependency-build configuration changes. New code is limited to multi-format regression tests. Proposed modules, designs and estimates below are not implemented capabilities.

## Conclusion and complexity

All six features have feasible implementation paths. Subtitles, danmaku and watermarks should share a timeline and overlay system. PiP and screenshots/GIFs containing effects require composed output frames, beyond ordinary UI overlays. Establish that output architecture before staged implementation.

| Feature | Current state | Recommended approach | Complexity |
|---|---|---|---|
| Subtitles | Subtitle type recognized; no decode/selection/display path | Cue timeline, text/bitmap rendering; separate libass integration for complex ASS | Medium; full ASS/PGS higher |
| Danmaku | No scheduler, collision allocator or renderer | Media-clock scheduling, glyph caches and GPU composition | Medium |
| System PiP | Metal display without a system PiP source | CVPixelBuffer → CMSampleBuffer → AVSampleBufferDisplayLayer → AVKit | Higher |
| Watermarks | No watermark API | Text/image textures; distinguish preview overlays from embedded output | Low–medium |
| Filters | Video processor extension point, but no filter graph; FFmpeg filters disabled | Metal/Core Image for basic real-time effects | Medium; complex graphs higher |
| GIF | FFmpeg GIF codecs enabled, without product-level animation/export features | Separate GIF playback, animated overlays and clip export | Medium |

## Code evidence

- [SGDefines.h](../SGPlayer/Classes/Core/SGCommon/SGDefines.h) and [SGMapping.m](../SGPlayer/Classes/Core/SGDefine/SGMapping.m) already map `SGMediaTypeSubtitle` and `AVMEDIA_TYPE_SUBTITLE`.
- [SGURLDemuxer.m](../SGPlayer/Classes/Core/SGDemuxer/SGURLDemuxer.m) enumerates all streams. [SGFrameOutput.m](../SGPlayer/Classes/Core/SGSession/SGFrameOutput.m) creates only audio/video decode loops and defaults to selecting/dispatching those media types.
- [SGPlayerItem.h](../SGPlayer/Classes/Core/SGSession/SGPlayerItem.h) exposes only audio/video selection. [SGTrack.h](../SGPlayer/Classes/Core/SGAsset/SGTrack.h) lacks public language/title/default/forced-track properties.
- [SGClock.m](../SGPlayer/Classes/Core/SGRenderer/SGClock.m) supplies a media clock. [SGCodecDescriptor.m](../SGPlayer/Classes/Core/SGDescription/SGCodecDescriptor.m) and the extracting demuxer already map trimming, time scaling and offsets.
- [SGProcessorOptions.h](../SGPlayer/Classes/Core/SGOption/SGProcessorOptions.h) allows replacing `videoClass`. The default [SGVideoProcessor.m](../SGPlayer/Classes/Core/SGProcessor/SGVideoProcessor.m) filters selected tracks and passes frames through.
- [SGVideoRenderer.m](../SGPlayer/Classes/Core/SGRenderer/SGVideoRenderer.m) renders directly into the Metal drawable. `currentImage` converts the current decoded frame, rather than final screen/VR/overlay output. `frameOutput` observes a frame before rendering; it is not an effect-output replacement interface.
- [build-ffmpeg.py](../scripts/build-ffmpeg.py) uses `--disable-filters --disable-autodetect`. Local `CONFIG_ASS_FILTER`, `CONFIG_SUBTITLES_FILTER`, `CONFIG_OVERLAY_FILTER`, `CONFIG_DRAWTEXT_FILTER`, `CONFIG_PALETTEGEN_FILTER` and `CONFIG_PALETTEUSE_FILTER` are all 0. Shipping `libavfilter.a` does not make those filters available.

## Subtitles

A first version should cover external UTF-8 SRT/WebVTT, embedded text subtitles, single-track selection/off, language/forced flags, font/color/size, bottom safe areas and timing offset. Copy language/title/disposition metadata rather than exposing long-lived dependence on a borrowed `AVStream *`.

Add a cue model with start/end, text/bitmap, style and region; a decoder; sparse queue; selection state; and renderer. Sparse subtitles must not stall audiovisual buffering or delay main-media EOF. On seek, track switch or media replacement, clear old cues and discard stale asynchronous results using session identifiers. Pause, rate, trimming and concatenation must share media-time mapping.

**Do not assume the audiovisual send/receive path applies unchanged.** The actual 9.0.2 headers still expose `avcodec_decode_subtitle2()`, `AVSubtitle`, `AVSubtitleRect` and `avsubtitle_free()`. Subtitle memory release, flush, inferred duration and clearing need separate handling. See [FFmpeg decoding APIs](https://ffmpeg.org/doxygen/trunk/group__lavc__decoding.html); implementation must follow the locally pinned headers.

Distinguish plain-text extraction from full ASS/SSA styling. CoreText does not by itself establish compatibility with ASS animation, karaoke, outlines, font attachments or positioning. For full ASS, consider [libass](https://github.com/libass/libass), its font-shaping dependencies, eight build slices, attachment handling and resource limits. PGS/DVD/DVB bitmap subtitles require palettes, alpha, canvas/regions and duration/clear events. OCR is not required for bitmap display.

Acceptance: Chinese/English/RTL, overlapping multiline cues, missing end times, external/embedded switching, rapid seek, rate/composition, on/off, absent subtitles, and visibility in PiP/capture. HLS/live subtitles require separate acceptance.

## Danmaku

Start with offline JSON/in-memory events: scrolling and fixed top/bottom items, on/off, opacity, font size, density and blocking. Network services, accounts and moderation are separate scope; this assessment does not design or integrate their APIs.

Schedule against media time, rather than independent wall-clock animations. Pause freezes motion; rate changes alter media progression; seek reindexes events. Lane allocation must compare relative velocities to prevent later long comments catching earlier ones, and reserve space for subtitles/controls. Use CoreText glyph/texture caching, object reuse and a visible-item limit rather than creating many UILabel/NSView objects every frame.

View overlays are suitable for prototypes but do not automatically appear in system PiP, exports or the existing `currentImage`. Pixel composition is required for those outputs, with an explicit small-window policy. Screen-fixed VR overlays are a reasonable first version; spherical/stereo spatial comments are additional scope.

Acceptance: low/high density, long CJK text and emoji, collision avoidance, pause/rate/seek, foreground/background, orientation/window changes, subtitle avoidance, PiP policy and bounded memory.

## System Picture in Picture

The local Xcode 27.1 AVKit headers for all three SDKs declare sample-buffer content sources at iOS/tvOS 15 and macOS 12, matching project minimums. API availability is not a runtime guarantee. Check support and current possibility and validate each platform. See Apple's [content source](https://developer.apple.com/documentation/avkit/avpictureinpicturecontroller/contentsource-swift.class) and [sample-buffer initializer](https://developer.apple.com/documentation/avkit/avpictureinpicturecontroller/contentsource-swift.class/init(samplebufferdisplaylayer:playbackdelegate:)).

The current Metal view cannot directly become a system PiP source. Retain FFmpeg decoding and existing audio, feed video sample buffers to `AVSampleBufferDisplayLayer`, and connect playback/pause, playable range, skipping and state through `AVPictureInPictureController`. Add AVKit integration, pixel-buffer/format-description/sample-buffer management, backpressure, synchronized timebases, seek flushing, UI restoration and interruption lifecycle. Always complete skip callbacks to avoid leaving system UI in a seeking state.

Unmodified VideoToolbox NV12 frames may be reusable directly. Software output needs compatible pixel buffers. Subtitles/watermarks/filters/VR require offscreen-composed output. Do not modify leased decoder buffers in place. Keep one audio/player instance to avoid duplicate audio or clock drift.

On iOS, review background modes, AVAudioSession, interruptions and current background-pause policies, especially video-only playback. tvOS differs from iOS in capabilities such as automatic inline PiP initiation; do not copy all properties indiscriminately. A tvOS simulator cannot complete physical-device PiP acceptance.

## Watermarks

Separate preview watermarks from content embedded in capture/PiP/export pixels. View/layer overlays serve the former; Metal blending of text/image textures serves the latter. Refresh dynamic timestamps/user identifiers when needed and cache static layout.

Define normalized position, anchor, opacity, scale, safe margins, content and output policy. Specify video-content coordinates versus whole-control coordinates. Handle letterboxing, aspect-fill cropping, rotation, VR and small windows. Watermarking is not screen-capture prevention or DRM.

Acceptance: transparent PNG, CJK text, rotation/cropping, resizing, multiple layers, export consistency and per-output disabling.

## Filters

A first version could provide brightness, contrast, saturation, grayscale and simple LUTs, with explicit ranges, ordering and reset. Prefer Metal or a reused Core Image CIContext to retain GPU flow. `videoClass` can host CPU processing, but replacing a processor alone does not implement final-screen composition.

FFmpeg filter graphs require enabling selected filters plus buffer/buffersink components, rebuilding eight slices, and implementing graph construction/reconstruction, parameter updates, format negotiation, EOF drain and seek flush. Filters such as `drawtext`/`subtitles` also introduce external dependencies; they are unavailable in the present configuration.

Repeated CPU download/upload of VideoToolbox frames can erase hardware-decoding benefits. Retain frame references until asynchronous GPU completion and use pools/backpressure. Define gamut, matrix, limited/full range and premultiplied alpha. Limit the first version to SDR 8-bit if desired; HDR/Main10 needs separate design and measurement.

Acceptance: known color references, parameter boundaries, chain order, hardware/software changes, 0.5x/2x playback, seek/flush, memory and sustained load.

## GIF: input, overlay and export are separate capabilities

1. **GIF media playback:** GIF demuxing/decoding components are enabled. New tests cover a 60-frame animation and zero-tolerance seek; see the format report. Product behavior still needs loop-count, variable-delay, pause/seeking and end policies.
2. **Animated GIF watermark/sticker:** decode through FFmpeg or ImageIO and overlay textures on a local timeline. Handle disposal, transparency, loops, zero/short-delay policy and cache limits. Avoid unbounded predecoding of large animations.
3. **Video clip to GIF:** add a background task that samples decoded/composed frames over a selected interval, scales and quantizes a palette, then encodes with cancellation, progress and resource budgets. A suggested initial limit is 5 seconds, 10 fps and no more than 720 pixels; these are proposed limits, not existing functionality.

The local GIF encoder is enabled but `palettegen/paletteuse` are disabled. A GIF encoder alone is not a complete video-to-GIF service. Options include ImageIO `CGImageDestination` or explicit quantization before FFmpeg encoding. Validate delays, looping, transparency, disposal and reader interoperability either way. See [Apple ImageIO](https://developer.apple.com/documentation/imageio/cgimagedestination).

Do not export by polling `currentImage`: it reads original frames and cannot guarantee output frame rate, final effects/overlays or independence from current playback. Offline export may use an independent decoder session rather than seeking the playing video. Explicitly select which overlays enter exported pixels.

## Shared architecture and effort

Suggested pipeline: `FFmpeg decode → time mapping → optional filters → VR/plane projection → subtitle/danmaku/watermark composition → display / PiP / screenshot / GIF`. Screen-fixed overlays follow projection; video-coordinate watermarks need an explicitly defined order. Keep overlay/event models separate from decoding and UI widgets.

Establish versioned sessions, one media-clock query, offscreen texture/pixel-buffer output, budgets and seek flushing. Then implement simple subtitles/watermarks, danmaku, PiP, filters and GIF. Address duration issues exposed by the new format tests before extending the timeline.

These are engineering estimates for one engineer experienced with Objective-C/Metal/FFmpeg, existing interaction designs, an SDR first version across three platforms, excluding complex ASS/PGS, online danmaku services and HDR:

| Work item | Estimated person-days |
|---|---|
| Shared timeline, offscreen output and buffer management | 5–8 |
| Simple external/embedded text subtitles | 5–8 |
| Offline danmaku | 4–7 |
| Three-platform PiP integration | 7–12 |
| Text/image watermarks | 2–4 |
| Basic filters | 4–7 |
| GIF playback refinements, stickers and bounded export | 4–7 |
| Integration, devices and stress regression | 6–10 |

Total: approximately 37–63 person-days, a rough estimate rather than a delivery commitment. Shared work should not be counted twice; refine after prototypes. Full ASS, bitmap subtitles, complex filter chains and HDR expand scope. Missing physical Apple TV remains a gap in final PiP acceptance.

## Format tests and limits

See the [format test record](ffmpeg-formats-testing.en.md) and [machine-readable evidence](ffmpeg-formats-validation.json). Describe containers separately from codecs: MKV is not a video codec, and FFmpeg is not its only possible parser. This run proves use of the project's linked FFmpeg path rather than relying on AVPlayer support.

New fixtures were tested on the Mac, without claiming new-format playback on iPhone/tvOS. The earlier three-platform seven-MP4-sample regression is separate evidence. New production issues are recorded without player changes.
