# FFmpeg 9.0.2 migration guide

English | [简体中文](ffmpeg-9.0.2-migration.md)

Updated: 2026-10-22. The dependency baseline is the official FFmpeg 9.0.2 release. The implementation retains no old FFmpeg version branches, removed API compatibility aliases or previous build entry points.

## Building and integration

```sh
./build.sh macOS build
./build.sh iOS build
./build.sh tvOS build
# Build all platforms
./build.sh all build --jobs 4
```

The build entry point is `scripts/build-ffmpeg.py`. It uses the official release archive and a pinned SHA-256. Python 3, Xcode 27.1, platform SDKs and Metal Toolchain are required. For offline builds, set `FFMPEG_ARCHIVE` to the same official archive; checksum verification remains mandatory.

Sources, configure arguments, SDK/compiler versions and outputs live under `build/ffmpeg/9.0.2/`. Configuration input changes trigger reconfiguration. The migration uses a new version directory to avoid old `config.h` files.

| Platform | Device/desktop libraries | Simulator libraries |
|---|---|---|
| macOS | arm64, x86_64 | None |
| iOS | arm64 | arm64, x86_64 |
| tvOS | arm64 | arm64, x86_64 |

Matching libraries and headers are in `build/libs/<platform>/universal/` and `build/libs/<platform>/simulator/`. Xcode selects the variant by SDK. Device and simulator arm64 slices are not merged with lipo. Per-library XCFrameworks are in `build/xcframeworks/<platform>/`.

TLS explicitly uses Apple SecureTransport instead of OpenSSL. Consumers must link `Security.framework` and `CoreFoundation.framework`; the demos are configured accordingly. RTMP/RTMPS, HTTP/HTTPS, HLS and RTSP build components are enabled. RTMPE/RTMPTE, which need an additional cryptographic backend, are not enabled. Remote live-stream interaction and reconnection still require acceptance tests against actual services.

Static-library consumers should use `-ObjC`. `-all_load` can load duplicate internal implementations from different FFmpeg libraries. The demos remove `-all_load` and use explicit cross-project target dependencies to prevent the shared `SGPlayer.framework` name from selecting the iOS target for tvOS.

## Player migration

- Remove `AVFrame.pkt_size` access. `SGFrame.size` now counts retained decoded buffer bytes, deduplicated by the underlying allocation. VideoToolbox frames use pixel-buffer size. `SGPacket.size` still reports compressed packet bytes.
- Deep-copy `AVChannelLayout` between descriptors, copies, setters and new frames. Release layouts at destruction and keep channel counts synchronized.
- Allocate audio/video frames with `av_frame_get_buffer()` rather than freeing individual interior YUV plane addresses. Initialize audio to silence for its format. Processing uses active sample bytes rather than copying allocation padding.
- Audio with fixed-size plane arrays supports 1–8 channels. Reject oversized decoded output before processing; invalid descriptor settings raise an argument exception.
- Initialize VideoToolbox devices with `av_hwdevice_ctx_create()`, reuse device references and select a supported software pixel format on failure. Software fallback is a current hardware-decoding policy, not an old FFmpeg compatibility branch.
- Drain output on EAGAIN before resending the original packet; handle EOF explicitly. Drain audio formatting/resampling output at EOF to retain delayed samples.
- Check `AV_NOPTS_VALUE`. Use CoreMedia ratio operations to avoid overflow from multiplying timestamps first. Derive missing audio timestamps/durations from sample continuity.
- Use the FFmpeg 9.0.2 HTTP options `user_agent` and `rw_timeout`. Map RTSP read/write timeout to its dedicated socket timeout instead of deleting the timeout.
- **Remove the public `SGDecoderOptions.refcountedFrames` property.** Modern decoder output is reference-counted. Callers must remove assignments; there is no no-op implementation or compatibility alias.

## Verification methods and limits

See the [validation evidence](ffmpeg-9.0.2-validation.json) and [test record](ffmpeg-9.0.2-testing.en.md). `ffmpeg-upgrade-audit.md` and `ffmpeg-upgrade-audit-evidence.json` are pre-upgrade baseline archives, not descriptions of the current implementation.

```sh
# Data-path and memory regression
python3 scripts/test-ffmpeg.py --asan
# Include local HTTPS and H.264/HEVC hardware encoding/decoding
python3 scripts/test-ffmpeg.py --asan --network --hardware
```

The test program reads the actual macOS target source list, compiles SGPlayer and test sources with AddressSanitizer, and links production FFmpeg static libraries without substitutes. The FFmpeg libraries themselves are not sanitizer-instrumented. These data-path tests do not display Metal output.

Checks cover custom channel-layout lifetimes, audio silence allocation, channel limits, YUV copying/pooling, invalid timestamps, exact 44.1→48 kHz sample counts, full WAV decoding/formatting with repeated EOF, B-frame video decode/seek/flush, real H.264/HEVC software and hardware decoding, local HTTPS, untrusted certificate rejection and the player's User-Agent. Test certificates are local test fixtures and do not alter production certificate settings.

There are eight FFmpeg slices across three platforms. Framework and demo verification covers Debug and Release on five SDKs: 20 builds. macOS and mobile simulators cover arm64/x86_64, and mobile devices cover arm64. The demo builds verify final application linking.

Xcode 27.1 is pinned in `.xcode-version`. Projects and FFmpeg slices directly target iOS/tvOS 15.0 and macOS 12.0, without command-line deployment overrides. Reproduce builds with `python3 scripts/verify-apple-builds.py --include-demos`.

The iPhone test bundle is `com.omnilink.fufucard`. Automatic signing uses OmniLink Exports Inc. (`Z5TKWGS67N`), associated with the signed-in `whevether@outlook.com` account. Signing relies on the local Xcode session and development certificate; no credentials are stored in the repository.

The Debug-only `--sgplayer-smoke-test` entry runs all seven samples, checking playback, pause/resume, 0.5x/2x rates, seek, EOF and video screenshots. Release excludes this entry. The embedded test player resumes the first sample after completion rather than leaving a paused frame.

Devices tested: physical iPhone 11 (iOS 27.0), physical Mac (macOS 27.0.1) and Apple TV 4K simulator (tvOS 27.0). Physical Apple TV, remote live streams, HDR/Main10, long-duration performance and the oldest supported systems require separate acceptance tests. Automation directly calls player APIs; it does not establish complete coverage of UI buttons, remote focus, VR gestures/gyroscope interaction or acoustic speaker output.

## Xcode 27.1 physical-device testing

The iPhone/tvOS demos use the UIScene window lifecycle, avoiding iOS 27 startup termination after building with Xcode 27.1.

Build the iPhone Debug app without deployment-target overrides:

```sh
xcodebuild -workspace demo/demo.xcworkspace -scheme demo-ios -configuration Debug \
  -destination 'id=<connected-iPhone-UDID>' -derivedDataPath build/iPhoneDevice \
  -allowProvisioningUpdates build
```

Xcode uses team `Z5TKWGS67N` to match the development profile for `com.omnilink.fufucard`. Launching with `--sgplayer-smoke-test` writes `Documents/sgplayer-device-smoke.json` and `.png`. A normal iPhone launch shows the existing sample list.

Use `python3 scripts/test-iphone.py --device <UDID>` for end-to-end verification. Each launch receives a unique run ID to avoid stale results. The script verifies the device-reported FFmpeg version is 9.0.2, restores the normal demo interface on success and retains the development-signed IPA, JSON report and video screenshot.

## All-sample runtime regression

```sh
python3 scripts/test-iphone.py --device <iPhone-UDID>
python3 scripts/test-desktop-tv.py macos
python3 scripts/test-desktop-tv.py tvos --simulator <booted-Apple-TV-UDID>
```

Runtime testing found and fixed missing player initialization on storyboard/nib paths, missing tvOS sample media, rate changes that did not immediately update the running clock, and the Metal renderer loading historical embedded binaries.

`scripts/build-metal.py` compiles shaders for the current SDK and generates an embedded header for the static framework. The three historical shader arrays are removed. Library/pipeline creation failures are logged and return failure, avoiding submission of an empty pipeline. Clock regression checks verify immediate speed changes while running and preserved pause state when changing speed while paused.

The seven samples are audiovisual, video-only, audio-only, trimming, segment time scaling, cross-file concatenation and VR. The concatenation test additionally crosses a segment boundary. See the JSON evidence for individual results and the limits above for uncovered functionality.
