# Changelog

English | [简体中文](CHANGELOG.zh-CN.md)

## Unreleased — 2026-10-24

- Add audio-only AAC export in MP4/M4A, Matroska and MPEG-TS, reusing clipping, gain and atomic cancellation; expose export/playback in all three demos without creating a video encoder.
- Extend idle controls hiding to Mac and tvOS, including hover/keyboard reveal, remote focus restoration and SwiftUI configuration; preserve active slider/pan interaction and handle non-touch progress value changes.
- Add focus-scoped Mac keyboard controls for seeking, volume/mute, rate, lock and full-screen/Escape restoration; preserve text-field input and system modifiers, with demo/SwiftUI integration.
- Isolate Mac UI outputs in a fresh temporary directory per case to avoid historical Desktop GIF replacement stalls; preserve failure stacks/logs and retain within-case overwrite checks.
- Add finite-range video transcoding/effect burning and export entries in all three demos; six container/effects-kernel combinations and hardware H.264/HEVC pass decoded-output ASan regression.
- Add isolated effect export snapshots; retain reordered boundary B frames during exact trimming and preserve offline audio delay while keeping playback padding enabled by default; fix non-square-pixel export letterboxing.
- Add iPhone double-tap, seek, player-volume and screen-brightness gestures with locking, VoiceOver gesture preservation and conditional brightness restoration.
- Add first-frame/failure covers with lifecycle cleanup and iPhone idle hiding/tap-to-reveal controls. Paused/loading/locked states retain controls; SwiftUI exposes cover/hiding configuration.
- Allow SwiftUI reopening on the same mounted view after closing, replacing old controls/constraints; verify real frames and a single set of controls after reopening.
- Add native bitrate/resolution/buffering/paused-network preferences with isolated snapshots and source persistence; preferences do not guarantee HLS variant selection.
- Export real numerical AVPlayer access-log metrics, leaving unavailable data empty; FFmpeg throughput/decode-drop metrics remain pending.

## Unreleased — 2026-10-23

- Add Swift 6 / SwiftUI wrappers and a five-SDK local SPM binary package with bundled fonts/licenses.
- Preserve media extensions in cache files and bookmark system HLS packages; fix foreground deadlines, video-only resume, FrameReader abort delegation and non-EOF error propagation.
- Add a tvOS mini-player focus guide and model the framework archive as a demo build input for incremental relinking.
- Add playlists, resume, rendition switching, A–B/item/list loops, bounded kernel fallback, private diagnostic export and exclusive playback groups.
- Preserve current play/pause intent across asynchronous kernel changes and reject superseded session completions.
- Add authenticated complete-file downloads with quota/pinning, independent timeline previews, WebVTT sprite indexes, shared controls and mini-player/container-full-screen presentation.
- Add audio track selection, volume, original-source AirPlay routing, dual subtitles, .cube 3D LUT and Bloom through the selected kernel.
- Add atomic packet recording/remux into Matroska/MP4/MPEG-TS, native HLS asset downloads on macOS/iPhone, capability-gated AV1 VideoToolbox selection and a runtime capability inventory.
- Expansion acceptance is in progress. The [implementation ledger](documents/feature-expansion.en.md) distinguishes completed implementation, pending validation and remaining work. Physical iPhone acceptance is deferred to 2026-10-26 by request.

## Unreleased — 2026-10-22

These changes are present in the working tree. This entry does not indicate a published release or Git tag.

### Playback effects and backend control

- Add `SGPlaybackController` with explicit FFmpeg/native selection, time-preserving switches and common composed output for display, capture and system PiP.
- Decode external/embedded subtitles with owned cues, track metadata, font attachments and bitmap placement; render styled ASS through libass, FreeType, HarfBuzz and FriBidi.
- Add media-clock danmaku, text/image watermarks, animated GIF stickers and independent cancellable GIF clip export with atomic output replacement.
- Route filters through libavfilter for FFmpeg and Core Image for native playback: brightness, contrast, saturation, grayscale, flips, blur and RGB curves.
- Add the shared 16-control feature demo and eight cross-platform UI scenarios, additional format playback, pixel/data assertions and deterministic stale-capacity regression.
- Infer missing video duration from adjacent PTS, preserving FLV/ASF frames and EOF timing. Reject stale decoder-capacity snapshots so older notifications cannot overwrite drained state.
- Avoid synchronous main-thread renderer initialization from the demux operation and remove self-retaining deallocation callbacks during rapid replacement/teardown.
- Correct the Metal-to-Core Image vertical origin and ASS glyph orientation; check real red-top/blue-bottom output pixels in both backends.
- Bundle and register a pinned Noto CJK font, copy static-framework resources into all demo apps, and verify the full Chinese subtitle phrase using screenshot OCR with a missing-glyph negative control.
- Add bounded CPU output for iPhone background PiP and retain composed buffers for lazy capture. Count frames only after submission to the system display layer.
- Preserve the pre-implementation assessment and initial format failures as historical evidence; see the current bilingual feature implementation/testing documents for exact acceptance and limits.

### Breaking changes

- Require FFmpeg 9.0.2 and Xcode 27.1 with Metal Toolchain. Set deployment targets directly to iOS/tvOS 15.0 and macOS 12.0.
- Remove `SGDecoderOptions.refcountedFrames` without an alias or no-op replacement. Callers must remove assignments to it.
- Define decoded `SGFrame.size` as retained buffer bytes, deduplicated by the underlying allocation; `SGPacket.size` remains compressed packet bytes.
- Support 1–8 audio channels and reject unsupported layouts before fixed-size plane arrays are accessed.
- Remove the previous FFmpeg build scripts, version compatibility branches and OpenSSL build chain. Use `build.sh` and `scripts/build-ffmpeg.py`.

### Dependency and build changes

- Pin the official FFmpeg 9.0.2 archive and SHA-256. Build eight SDK/architecture slices and package 18 per-library XCFrameworks.
- Keep device and simulator arm64 libraries separate; select matching libraries and headers by SDK. Track configuration, compiler and SDK inputs for rebuilds.
- Use Apple SecureTransport for TLS. Enable HTTP/HTTPS, HLS, RTMP/RTMPS and RTSP components; RTMPE/RTMPTE are not enabled.
- Replace demo `-all_load` with `-ObjC` and add explicit cross-project target dependencies.
- Compile and embed Metal shaders for the selected SDK using `scripts/build-metal.py`; remove the three historical embedded shader binaries.
- Configure the iPhone demo bundle as `com.omnilink.fufucard`, using OmniLink Exports Inc. (`Z5TKWGS67N`) through the configured Xcode account. Credentials remain outside the repository.

### Playback fixes

- Deep-copy and release `AVChannelLayout` values; keep channel counts synchronized.
- Allocate audio/video frames with `av_frame_get_buffer()`, initialize audio silence correctly and distinguish active sample bytes from allocation padding.
- Initialize VideoToolbox devices with `av_hwdevice_ctx_create()` and retain software fallback for hardware initialization failures.
- Drain decoder output before retrying EAGAIN packets, handle EOF explicitly and drain delayed audio resampling output.
- Guard missing timestamps and timestamp conversion overflow. Derive missing audio timing from sample continuity.
- Use `user_agent` and `rw_timeout`; map RTSP timeout to its protocol option.
- Hold the pixel-buffer lock during screenshot conversion.
- Migrate iPhone/tvOS demos to UIScene and initialize players on storyboard/nib loading paths. Include the missing tvOS sample media.
- Apply rate changes immediately to the running playback clock while preserving pause state.
- Report Metal library/pipeline creation failures and avoid submitting an empty pipeline.

### Verification and documentation

- Add repeatable dependency builds, 20 framework/demo Debug/Release build checks across five SDKs, and AddressSanitizer/data-path/HTTPS/VideoToolbox regression tests.
- Add shared Debug automation for seven samples: audiovisual, video-only, audio-only, trimming, segment time scaling, concatenation and VR.
- Pass all seven samples on physical iPhone 11, physical Mac and Apple TV simulator: 21 sample runs. Check playback, pause/resume, 0.5x/2x rates, seek, EOF, frame output and video screenshots; cross a segment boundary in the concatenation case.
- Publish matching Chinese/English READMEs, migration guides, test records and changelogs. Preserve the pre-upgrade audit as a historical archive.

### Historical assessment and initial format findings (2026-10-22)

Before implementation, the bilingual assessment proposed these capabilities. The first format run passed raw decoding 8/8 but strict player acceptance only 6/8: FLV/ASF lost a frame and emitted zero-duration frames. These findings led to the duration fix above; current strict acceptance is 8/8. The initial evidence is retained in `documents/ffmpeg-formats-validation.initial.json`.
