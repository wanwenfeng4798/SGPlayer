# Playback effects and backend selection

English | [简体中文](media-features.zh-CN.md)

Implementation: 2026-10-22, FFmpeg 9.0.2 / Xcode 27.1. This supersedes the earlier feasibility assessment. See the [test record](media-features-testing.en.md) for measured coverage and remaining limits.

## Entry points

Open `demo/demo.xcworkspace`. The iPhone and Mac demos include **All Features**; the tvOS demo opens the shared feature screen. Its 16 buttons exercise play, pause, seek, kernel selection, subtitles, danmaku, watermarks, filters, GIF stickers, PiP, GIF export, stop, media selection, VR, speed and capture. The original seven sample cases remain available through their existing demos and automated smoke runner.

Use `SGPlaybackController` for explicit FFmpeg/native selection, common composition and system PiP. Existing direct `SGPlayer` use remains the FFmpeg player; it does not silently select AVPlayer. All controller calls belong on the main thread. The standalone reader and GIF exporter run on a worker queue.

```objc
SGPlaybackController *controller = [[SGPlaybackController alloc]
    initWithKernel:SGPlaybackKernelFFmpeg view:videoView];
[controller replaceWithURL:videoURL];
[controller play];

SGFilterConfiguration *filter = [[SGFilterConfiguration alloc] init];
filter.grayscale = YES;
filter.brightness = 0.1;
controller.effects.filter = filter;

[controller switchToKernel:SGPlaybackKernelNative completion:^(BOOL success) {
    // Check success and controller.error. Time and play/pause intent are retained.
}];
```

The native backend uses AVPlayer and AVPlayerItemVideoOutput. Its supported input formats depend on AVFoundation. Switching to native does not make FFmpeg-only inputs playable. Inspect errors and return to FFmpeg when appropriate. Native VR projection is rejected by the demo; VR belongs to the existing FFmpeg/Metal renderer.

## Effects

| Function | Configuration and behavior |
|---|---|
| Subtitles | `loadSubtitlesFromURL:completion:` reads external SRT/WebVTT/ASS or embedded subtitle streams from a media URL. `subtitleTracks` exposes stream index, language, title, default/forced flags and owned cues/font attachments. `selectSubtitleTrack:` selects an index; `-1` disables. The demo button supplies a small SRT example. Applications can present their own track picker. |
| ASS | libass renders script styles, font selection, color, outline, placement and overrides. FreeType, HarfBuzz and FriBidi provide font rendering, shaping and bidirectional layout. Embedded TTF/OTF bytes are retained independently of FFmpeg's source context. A bundled Noto Sans CJK SC Regular (Sans2.004, OFL 1.1) provides a readable fallback when Apple system font files are inaccessible to FreeType. Override `subtitleFallbackFontURL` to supply another font. |
| Bitmap captions | FFmpeg subtitle rectangles become owned RGBA images with palette transparency and normalized placement. A generated DVD subtitle stream is tested; PGS/DVB-specific interoperability is not yet validated. |
| Subtitle timing | `subtitleOffset` shifts cues in seconds. Media-time evaluation follows pause, seek and speed changes. Unknown event ends resolve at the next event, media end or a bounded three-second fallback. |
| Danmaku | `SGDanmakuItem` provides start, duration, text and scrolling/top/bottom mode. Deterministic media-time placement, separate bands, lane occupancy, count limits and cached glyphs avoid time drift and overlapping occupants in a lane. |
| Watermarks | `SGWatermark` accepts text and/or a CIImage, normalized top-left rectangle and opacity. These pixels appear in composed playback, captures and effect-enabled GIF export. |
| Filters | FFmpeg selection executes a **libavfilter graph**; native selection uses **Core Image**. Brightness, contrast, saturation, grayscale, horizontal/vertical flip, blur and RGB color curves are available. Configuration is validated and copied on assignment. |
| Color curves | `colorCurves` holds 2–64 interleaved float RGB samples in `[0,1]`. This is a one-dimensional RGB transfer curve, not an arbitrary 3D `.cube` LUT loader. |
| Animated GIF | `SGAnimatedImage` uses ImageIO frames, delays, transparency/disposal decoding and loop metadata, with an explicit decoded-memory budget. Set `sticker`, `stickerRect` and `stickerStart` for a timed overlay. |
| GIF export | `SGGIFExporter` independently decodes a source interval and writes an animated GIF. It supports progress, cancellation, dimensions, frame rate and optional shared effects. It does not seek the active player. |

FFmpeg filters enabled in this build: `buffer`, `buffersink`, `format`, `scale`, `lutrgb`, `colorchannelmixer`, `hflip`, `vflip`, `gblur`. No legacy FFmpeg-version branch or disabled compatibility shim was added. Equivalent filter parameters need not produce bit-identical pixels across FFmpeg and Core Image.

Common composition happens after the FFmpeg Metal projection or native video output. Text/GIF overlays use CoreText/Core Image. The same composed pixels feed display, capture and the PiP sample-buffer layer. GIF export decodes the original video and applies effects; it does not reproduce the live Metal VR camera projection. iPhone background FFmpeg PiP uses CPU composition, capped to a 640-pixel long edge, to avoid prohibited background Metal submissions. Its current background path uses the flat decoded frame, not the VR projection.

```objc
[controller loadSubtitlesFromURL:subtitleOrMediaURL completion:^(NSError *error) {
    if (!error && controller.subtitleTracks.count)
        [controller selectSubtitleTrack:controller.subtitleTracks.firstObject.index];
}];
controller.effects.subtitleOffset = 0.25;
SGWatermark *watermark = [[SGWatermark alloc] init];
watermark.text = @"SGPlayer";
controller.effects.watermarks = @[watermark];
```

Assign complete arrays/configurations when changing settings. Composition and assignments are synchronized, but mutating a previously assigned cue/watermark object concurrently with rendering is the caller's responsibility. Export takes the supplied effects object; freeze its configuration if a consistent export is required.

## System Picture in Picture

`startPictureInPicture:` checks system support and current source readiness, then uses AVKit with AVSampleBufferDisplayLayer. The controller implements play/pause, skip completion, playback range, lifecycle callbacks and interface restoration. Set `pictureInPictureChanged` for asynchronous failures and `restoreInterface` to restore the host window/view. Call `close` when playback ends permanently.

An app must enable the appropriate audio/background playback capability and audio session. The demos include the playback setup. A simulator/device can report PiP unsupported; the API returns a concrete error. Such a result is not evidence that active PiP worked. DRM/protected AVPlayer output and every OS/device policy are outside this validation.

## Resource limits

- Subtitle read: 30-second overall interrupt deadline, 10-second network I/O timeout, 100,000 cues, 128 MiB total decoded bitmap data, 64 MiB font attachments and 16 MiB per font. This is a bounded complete-file reader, not a live subtitle-stream scheduler.
- Caption bitmap: at most 8192 per dimension and 64 MiB per rectangle.
- GIF export: interval `(0,30]` seconds, 1–30 fps, maximum dimension 32–1920 pixels. Output is written to a temporary file and atomically replaced after successful finalization. Cancellation/EOF/error preserves an existing output.
- Create a new exporter after cancellation; its cancellation flag remains set. Cancel cannot interrupt a synchronous demux I/O call immediately.
- Animated-image decoding rejects a file whose decoded frames exceed the caller's budget. Composed pixel buffers use a pool with a six-buffer allocation threshold; glyph cache budget is 16 MiB.
- Correctness tests do not establish sustained 4K/HDR performance, long-duration memory stability, accessibility completeness or exhaustive subtitle/GIF dialect compatibility.

## Building the subtitle stack

`./build.sh all build` builds FFmpeg and the subtitle/font dependencies for eight matching SDK/architecture slices. `python3 scripts/build-subtitles.py all --jobs 4` rebuilds only the subtitle stack. The build requires Python 3, network access for first-time downloads and `pkg-config` on PATH; pinned Meson/Ninja install in `build/feature-tools`.

`scripts/subtitle-sources.json` pins official archives, versions and SHA-256 values: libass 0.17.5, FreeType 2.14.3, HarfBuzz 14.4.0 and FriBidi 1.0.16. Archives are verified before extraction. Build configuration, archive manifest, tool versions, SDK and architecture enter the rebuild fingerprint. Libraries/headers merge into `build/libs/<platform>/<universal|simulator>` and link into SGPlayer. FFmpeg's 18 XCFrameworks remain FFmpeg-only packages; they do not include these four extra libraries.

Apps linking SGPlayer also use AVKit, CoreImage, CoreText, ImageIO, UniformTypeIdentifiers, libc++ and libiconv in addition to the existing media frameworks. See the project build settings as the concrete integration example.

**Static-framework integration:** copy `NotoSansCJKsc-Regular.otf` and its OFL notice into the application resource phase, as all three demos do. Static linking does not embed framework resources automatically. `bundleForClass:` resolves to the host application for these linked classes; alternatively set `subtitleFallbackFontURL` explicitly.

The bundled CJK font adds approximately 15.7 MiB to each framework. Its official source, SHA-256 and byte count are pinned in `scripts/subtitle-font.json`.

Third-party notices are in [licenses](../licenses/README.md). Portions of this software are copyright © The FreeType Project (www.freetype.org). All rights reserved.
