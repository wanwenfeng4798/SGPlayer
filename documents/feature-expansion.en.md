# Player expansion and acceptance

Work implements applicable KSPlayer / GSYVideoPlayer capabilities independently within SGPlayer's architecture. The union is not yet complete; remaining work is listed below. A feature declaration does not establish equivalent performance or device coverage.

Test allocation: the current physical Mac; iPhone and tvOS simulators initially. Physical iPhone acceptance is deferred, as requested, until the device is connected on 2026-10-26. Simulator results cannot replace that acceptance.

## New modules

| Module | Behavior | Current acceptance |
| --- | --- | --- |
| SGPlaybackSession | Playlist, previous/next, resume, independent rendition URLs, item/list/A–B loops | Policy regression passed; iPhone/tvOS simulator playlist interactions passed |
| Kernel policy | Manual / prefer Native / prefer FFmpeg; at most one fallback; preserve time and playback intent | Policy regression passed; actual iPhone/tvOS simulator kernel switching passed |
| Diagnostics | First frame, media-clock stalls, presented frames, fallback/events, JSON; real native access-log bitrate/bytes/downloaded media duration/dropped frames/stalls | Policy regression passed; empty without an access log; FFmpeg throughput/decode drops are not yet measured |
| SGNativePlaybackPolicy | Native bitrate/resolution/buffering/paused network preferences, validation, snapshot isolation and source persistence | Validation/isolation/rejected-update preservation/real AVPlayerItem propagation passed; HLS variant transitions and adverse-network acceptance remain pending |
| SGPlaybackCoordinator | Explicit activation pauses other sessions; weak registration | Policy regression passed |
| SGMediaCache | Complete HTTP downloads, optional SHA-256, quota/LRU, pinned playback files, cancellation, authenticated request isolation | Real URLSession, media-extension and restart-index regressions passed |
| SGTimelinePreview | Independent FFmpeg seek/decode, deadline/cancel, 32 MB preview cache | Independent decode/cancellation regression passed |
| SGTimelineSpriteIndex | WebVTT intervals, relative URLs, xywh crops, overlap/bounds/memory limits | Interval boundaries/relative URLs/overlap rejection passed |
| SGPlaybackControls | Progress, play/pause, skipping, playlist, kernel, audio/subtitle/quality/speed, retry/lock, PiP and AirPlay route picker | Full iPhone/tvOS simulator and physical Mac UI regressions passed |
| SGPlaybackPresentation | Reparent the existing render surface into a draggable mini player or full container; restore layout | iPhone/tvOS mini-player/full-container restoration passed, including tvOS remote focus |
| SGPlaybackCover | Show while waiting for a first frame/on failure, hide after presentation; restore accessibility labels on close/release | Lifecycle ASan and actual iPhone failure→frame tests passed; tvOS cover visual acceptance passed; Mac targeted acceptance passed |
| Automatic hiding | Configurable playing-idle timeout on all three platforms; iPhone tap, Mac hover/keyboard and focused tvOS remote receiver reveal controls; paused/loading/locked states stay visible | Complete Mac/iPhone/tvOS UI suites passed; disabled by default until the host supplies a positive interval |
| Mac keyboard | Video-focused playback/seek/volume/mute/rate/lock and presentation restore; preserve input controls and system modifiers | Physical Mac complete 13-case suite includes keyboard/text-focus and automatic hiding; ASan lifetime passed; ABC text-key automation restores the original source |
| Dual subtitles | Separate ASS renderer, independent offsets/plain-text positions; preserve selection across kernel changes | Dual rendering/independent timing pixel regression passed |
| 3D LUT / Bloom | Core Image for Native; lut3d / split / gblur / blend for FFmpeg; strict .cube parser | All slices rebuilt; constant-red 3D cube and Bloom regression passed in both kernels |

`SGMediaRemuxer` independently records/remuxes packets into Matroska, MP4 or MPEG-TS, retaining keyframe boundaries and reporting the actual interval. All three outputs passed full decoding, timestamp, cancellation and past-EOF atomic-preservation ASan checks. MPEG-4 to MPEG-TS includes global headers; the actual keyframe-aligned interval is reported.

Added `SGMediaTranscoder`: independent finite-range Matroska / MP4 / MPEG-TS exports, portable software MPEG-4 by default, with explicit H.264 / HEVC VideoToolbox choices that fail when unavailable. It limits dimensions/frame rate, bakes the display transform, and converts the first audio track to stereo 48 kHz AAC with gain. Subtitles, dual tracks, danmaku, watermarks, GIF stickers and filters burn through the selected effects kernel. `SGMediaEffects.snapshot` isolates mutable settings for background video and GIF export. Default MPEG-4 output targets FFmpeg playback; Apple native players do not guarantee support for that profile. The demo explicitly selects H.264 VideoToolbox and checks playback with both kernels, without implicit encoder fallback. Fix non-square-pixel (SAR) exports that enlarged the canvas without expanding image pixels; dimensions and decoded pixels are asserted.

Mac ASan regression covers six container/kernel combinations, decoded pixels, CJK subtitles/danmaku/GIF, delayed-audio PCM and synchronization, trimming, rotation, hardware H.264/HEVC, cancellation/deadline/atomic failure preservation, and snapshot isolation. This exporter supports SDR/8-bit; explicitly marked PQ/HLG input is rejected. Multichannel preservation and advanced processing remain pending; audio-only export is implemented in the follow-up below.

Fixed end-boundary GOP reading so reordered B frames within a segment are retained; exact trimming verifies all 15 frame contents, timestamps and end. `SGDecoderOptions.padAudioToRangeStart` defaults to padding for playback; offline export disables it to retain delayed audio without allocating silence proportional to long gaps. All three demos expose video export followed by explicit result playback; targeted UI acceptance is recorded separately.

`SGHLSAssetStore` adds macOS/iPhone background HLS tasks, relaunch restoration, offline-package records, cancellation and removal. Actual downloading and offline restoration in a new process passed on the physical Mac, with real native frames and zero offline HTTP requests. The modern AVAssetDownloadConfiguration implementation requires macOS 14+/iOS 18+ and reports unsupported on earlier systems; Apple does not provide this API on tvOS. System download locations are stored as NSURL bookmarks, preserving the returned /.nofollow path. Physical iPhone background-download acceptance remains pending.

`SGPlaybackCapabilities` reports runtime support; AV1 VideoToolbox selection is hardware-gated. Capability flags do not replace physical-device AV1 playback tests.

Swift 6.4 / SwiftUI wrappers and `scripts/build-package.py` generate `build/Package` with an SPM binary core, UI and font/license resources. All five SDK binary frameworks, independent linking and three package tests passed. Package tests explicitly drive Metal to verify the rendering pipeline, cached playback in both kernels and bundled fonts. With the Mac unlocked, the final real application passed four default automatic-rendering checks: ordinary FFmpeg, reopening on the same view, and cached playback in both kernels, without a custom display clock. Locked-screen experiments are excluded. The iPhone and tvOS SwiftUI cross-builds also passed. Package tests preserve the configured hiding interval across reopening; real-app reports record package, source and executable digests.

All 20 Xcode 27.1 Debug/Release framework/demo builds passed. The ASan suite includes eight formats, networking, VideoToolbox, dual subtitles/filters and remux recording. Static framework linkage uses an explicit archive input and a generated framework-digest compilation input, compensating for Xcode 27 omitting the extensionless archive from linker dependency information. Changed framework bytes relink the demo; unchanged bytes do not. The demo embeds its linked framework digest for independent verification. Linking the framework and its archive simultaneously is avoided because iOS `-ObjC` would load duplicate symbols.

## Acceptance evidence

| Target | Result and limits |
| --- | --- |
| iPhone 18 Pro / iOS 27.0 simulator | Latest complete run: 13 tests, 12 passed, 1 unsupported-PiP skip, 0 failures; includes covers, gestures, audio/video export and video-only background recovery |
| Apple TV / tvOS 27.0 simulator | Latest complete run: 12 tests, 11 passed, 1 unsupported-PiP skip, 0 failures; includes covers, audio/video export and remote-driven floating/full-container restoration |
| Physical Mac | Complete controls run: 13/13 UI tests passed, including real PiP, cover lifecycle and both-kernel transcoding. Historical Desktop-output GIF stalls remain diagnostic evidence |
| HLS / physical Mac | Actual download produced 10 frames; a new process restored the offline asset and produced 5 frames with zero offline HTTP requests |
| SPM | Five-SDK package generated; three package tests cover input, fonts and real rendering pipelines. Four final real-app automatic-display checks passed |

Developer testing mode was enabled with explicit user authorization. Initialization failures with that mode disabled, locked-screen activation failures and stale demo linkage are retained as diagnostic evidence and are not functional passes. Unsupported PiP skips do not establish start/background/restore behavior on supported hardware. The separate validation record identifies logs, xcresults and source digests.

New `SGPlaybackGestures` (iPhone) adds double-tap play/pause, horizontal seek preview/commit, right-side player volume and left-side screen brightness. Locking blocks gestures, finite-timeline guards reject invalid seeking, and VoiceOver retains system gestures. Brightness restoration respects changes made elsewhere. The separate actual-touch regression passed double-tap, drag seeking, volume/brightness and locking, in addition to the earlier complete 10-test simulator run. Physical touch behavior, system brightness and accessibility still require iPhone hardware acceptance.

## Remaining implementation scope

These remain in scope. Interfaces, placeholder buttons and feasibility decisions do not count as completed implementations.

| Area | Implementation and acceptance requirements |
| --- | --- |
| Complete controls | Track/style menus, physical accessibility acceptance, rotation and further keyboard/focus edge cases |
| Download/preload | Resume/Range playback while downloading, physical iPhone HLS background/system-termination restoration, preload/list reuse; complete-file caching does not provide these |
| Adaptive/live | HLS/DASH/Native ABR policies, FFmpeg variant switching, reconnect/jitter/catch-up, DVR and latency measurements |
| Deeper diagnostics | Throughput, actual decode drops/hardware mode, resource budgets, long-running multi-instance stress |
| Subtitle extensions | System appearance, word timing, online search/translation, offline AI captions/translation, style editing |
| Output/processing | Advanced transcoding/processing, multichannel output, separate A/V synchronization, gapless, deinterlacing, upscale/multipass graphs |
| Sources/casting | SMB/NFS credentials/random access, DLNA sessions/local restoration; distinguish original-URL AirPlay from custom composed output |
| Platforms/distribution | External-host SPM distribution integration, Catalyst and visionOS |
| Business module | Ad scheduling, content/ad time mapping, error/skip policy |
| Color/hardware | HDR/10-bit/HDR10+ metadata through display/effects/export; capability-gated AV1; measured device-specific 8K/120 fps |
| Advanced media | Blu-ray/ISO/BDMV/DVD titles/playlists; separate BD-J/menu/encryption review; validate system APIs, licensing and hardware for Dolby Vision/Atmos/passthrough/DRM |

## Integration contracts

Session policy and UI operations run on the main thread. A session owns its controller's source: replace media through the session to keep playlist state consistent. Call `close` when finished. Superseded asynchronous operations must not overwrite newer items or playback intent.

Resume data uses stable item identifiers; inject a dedicated `NSUserDefaults` suite or nil for testing. Diagnostics contain numbers, indexes and controlled event names. They exclude URLs, query strings, authorization headers and arbitrary error descriptions.

Use a private application cache directory. Call `pinRequest:` before handing a cached file to a player, then `unpinRequest:` after releasing that item. Headers participate in identity; only digests and media extensions are persisted; raw URLs/headers are not written. This cache downloads complete progressive files. HLS/DASH manifests require segment-aware asset management. Optional SHA-256 verification runs before publication; failure preserves the existing cache entry.

Decode previews on a worker queue using their independent reader. Sprite parsing/cropping does not fetch images: the host's authenticated source/cache layer supplies the bytes. Dual ASS tracks retain authored positions and can overlap; plain-text tracks have separate positions.

## Validation

```sh
python3 scripts/build-package.py
swift test --package-path build/Package
python3 scripts/test-swiftui.py  # requires an unlocked Mac
python3 scripts/test-hls-download.py
python3 scripts/test-cache.py
python3 scripts/test-ffmpeg.py --features --formats --network --hardware --asan
python3 scripts/verify-apple-builds.py --include-demos --jobs 2
python3 scripts/verify-demo-linkage.py
```

See the [machine-readable validation record](feature-expansion-validation.json) for exact logs, xcresults, platform skips, tested binary digests and the current source snapshot. New changes must rerun relevant validation; earlier records do not establish acceptance of later changes.

## SPM / SwiftUI integration

Run `python3 scripts/build-package.py`, add the local `build/Package` package to the host and select the `SGPlayerUI` product. Own `SGPlayerModel` on the main actor, call `open(_:identifier:title:)` with a stable media ID, and embed `SGPlayerView(model:)`. One model binds one live view; dismantling closes the session and saves resume state. The resource bundle includes Noto CJK and dependency licenses. The default SwiftUI wrapper has no host full-screen/mini-player container, so those buttons are disabled; apps can integrate native `SGPlaybackPresentation` with their containers.

Supply a `CGImage` through `setCoverImage(_:)`. On all three platforms, `setControlsAutoHideInterval(_:)` sets the idle interval; zero disables hiding. Objective-C hosts use `SGPlaybackControls`' `setCoverImage:forView:`, `attachGesturesToView:` and `autoHideInterval`. Covers belong to the presentation view.

After `close()`, `open` can recreate the session on the same mounted view. Old controls, covers, constraints and timers are released. The package test verifies new presented frames and exactly one set of controls after reopening.

After unlocking, the final package passed all four foreground automatic-display checks with 7 / 6 / 6 / 6 frames. Raw JSON, independent run history and last-passed.json are preserved. A historical locked rerun had overwritten an earlier three-check raw report; that historical limitation does not affect this newly saved four-check acceptance.

Native ABR configuration expresses AVPlayer preferences, not a guarantee of variant selection. FFmpeg uses the session's independent rendition URLs; native preferences do not implement FFmpeg automatic adaptation. `nativeAccessLog` contains only system-reported numerical fields; unknown/negative values, URIs, server addresses and request headers are excluded.

### Video export usage

Snapshot effects on their configuration-owning queue (usually main), then call the synchronous exporter on a worker queue. The range uses the input media timeline. Output starts at the clip origin while retaining relative audio/video delay. Each job instance is single-use.

```objc
SGMediaEffects *effects = [controller.effects snapshot];
SGTranscodeConfiguration *config = [SGTranscodeConfiguration new];
config.videoCodec = SGTranscodeVideoCodecH264VideoToolbox;
config.maximumDimension = 1280;
SGMediaTranscoder *job = [SGMediaTranscoder new];
job.maximumWallTime = 120;
dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    NSError *error = nil;
    BOOL success = [job transcodeURL:sourceURL toURL:destinationURL
                     configuration:config
                             range:CMTimeRangeMake(CMTimeMake(5, 1), CMTimeMake(10, 1))
                           effects:effects error:&error];
    // Update UI on main; call [job cancel] for external cancellation.
    NSLog(@"export: %d, %@", success, error);
});
```

Input and output must differ. Successful export atomically replaces the destination; failure or cancellation preserves an existing file. Select embedded subtitle tracks with the subtitle reader and configure effects first; the exporter does not guess all subtitle selections.

The latest complete simulator runs also verify both effects kernels produce H.264/AAC reports with 30 video frames and 37,024 audio samples per channel, followed by real output playback. Their UI binaries precede the isolated SAR fix, which passed decoded-pixel ASan assertions, 20 cross-SDK builds and three final SPM tests. Four-scenario foreground SwiftUI acceptance passed; complete Mac controls UI passed 13/13; the full feature expansion remains incomplete.

Final Mac UI acceptance uses a fresh temporary output directory per case, subsequently collected into the evidence folder. The same GIF case still overwrites its output. Historical Desktop GIF metadata/replacement waits and the ineffective POSIX-publication experiment are preserved; production publication retains the original implementation.

### Mac keyboard integration

Bind the surface with `attachKeyboardToView:`; nil detaches. Clicking video takes focus. Space toggles playback, arrows seek ±10 seconds (Shift: ±30), up/down adjust player volume, M mutes/restores, brackets change rate by 0.25 within 0.25–4, and L locks/unlocks. F invokes `toggleFullScreen`; Escape invokes `dismissPresentation` to restore an existing presentation. SwiftUI binds its surface automatically; its default wrapper still requires a host presentation container.

Command/Control/Option combinations and input controls retain system handling. Players are scoped by focus. Text-key automation temporarily selects ABC and restores the original input source; other IME composition states remain unaccepted.

## Controls validation checkpoint — 2026-10-24

All seven original demos passed separately on the physical Mac, iPhone simulator and tvOS simulator. The complete feature UI suites above precede the subsequent long-drag/accessibility progress fixes; targeted acceptance for those fixes is recorded separately in the validation JSON. A locked Mac is a blocked foreground run, never a functional pass.

The private temporary-output GIF regression passed, including within-case overwrite. Replacing a historical file in a protected Desktop directory previously stalled inside system file publication; its exact cause and external-directory acceptance remain unresolved. No system privacy settings were changed.

Active slider tracking and iPhone pans keep the controls visible. Mac timer refresh preserves the thumb while its cell is tracking. The iPhone progress control handles value changes without touch-up, while touch dragging still commits on release. Simulator slider automation checks the final thumb position against the media clock; it does not establish physical VoiceOver acceptance.

The targeted iPhone simulator follow-up passed both progress tests. A separate six-second hold run also passed; an externally captured screenshot during the hold shows the controls and tracking thumb visible before the seek commits. Mac ASan asserts that highlighted slider tracking prevents hiding and timer-driven thumb replacement. After unlocking, both final Mac foreground progress tests passed; the package foreground SwiftUI rerun is recorded separately. Earlier four-scenario SwiftUI success applies to its recorded package digest.

## Audio-only output

Set `SGTranscodeConfiguration.includeVideo = NO` and keep `includeAudio = YES`. The same exporter writes stereo 48 kHz AAC in MP4/M4A, Matroska or MPEG-TS. It never creates a video encoder or compositor; video settings are ignored. Both outputs disabled, missing audio, or supplying visual effects to an audio-only operation fail before replacing the destination. The existing finite-range, gain, cancellation, deadline and atomic-publication contracts apply. This is lossy AAC extraction/re-encoding, with the existing stereo conversion policy.

The three demos now expose Audio Export: a list entry on iPhone, an application menu entry on Mac and the fourth Menu-cycled mode on tvOS. `--sgplayer-audio-export` opens it directly. Export and playback are separate actions; reports contain `includeVideo`, zero video frames and the encoded audio sample count. Real decode/PCM assertions and dual-kernel UI playback are recorded separately; successful clocks do not establish subjective speaker listening quality.

Final audio-export checkpoint: all 20 Xcode builds, ten demo linkage checks, three package tests and four real Mac SwiftUI scenarios passed. Each platform also passed the two targeted audio-only/video-export tests; both kernels exported and replayed the result. Mac progress follow-up passed 2/2; the revised iPhone actual-position assertion passed 1/1. These are incremental suites, not a new combined complete-suite run. The overall expansion remains incomplete and physical iPhone acceptance remains deferred.
