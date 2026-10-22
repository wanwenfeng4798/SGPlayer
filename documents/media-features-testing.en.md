# Playback feature validation

English | [简体中文](media-features-testing.zh-CN.md)

Date: 2026-10-22. Toolchain: Xcode 27.1; FFmpeg 9.0.2. [Implementation and limits](media-features.en.md). The completed run is archived in the [machine-readable evidence](media-features-validation.json).

## Final results

| Verification | Result |
|---|---|
| Builds | 20/20 passed |
| Physical iPhone 11 UI | 8/8 passed, including both backends in background PiP and rendered orientation |
| Physical Mac UI | 8 scenarios accepted: 7 passed in the full run, one Accessibility snapshot interruption failed initially and passed an isolated retry without source changes |
| tvOS simulator UI | 7 passed; system PiP unsupported, 1 explicitly skipped |
| Original demos | 7/7 on each platform, 21/21 total |
| Additional FFmpeg formats | 8/8 passed, including FLV/ASF timing and EOF |
| Caption screenshots | Full Chinese phrase recognized in all 6 platform/backend combinations; known missing-glyph screenshot rejected |
| Data/memory checks | ASan-enabled SGPlayer regression, subtitle/filter/GIF checks, HTTPS and H.264/HEVC software/VideoToolbox passed |

The first Mac full UI run remains a failed run in its original xcresult. Only the interrupted control scenario was retried; the evidence manifest keeps both attempts and their individual outcomes. There is no claim of an uninterrupted green 8-test Mac run for this final source snapshot. The tvOS skip is not an active-PiP pass.

## Test environments

- Physical Mac, arm64, macOS 27.0.1 (26A434).
- Physical iPhone 11, iOS 27.0, UDID ending `E9B802E`; bundle `com.omnilink.fufucard`, team OmniLink Exports Inc. (`Z5TKWGS67N`). The configured Xcode account is used; credentials are not stored here.
- Apple TV 4K (3rd generation) tvOS 27.0 simulator. There is no physical Apple TV acceptance in this run.

## Scope and assertions

| Suite | Checks |
|---|---|
| Build matrix | Framework and demo, Debug and Release, macOS / iPhone device / iPhone simulator / tvOS device / tvOS simulator: 20 builds. Eight architecture slices for dependencies. |
| Original demos | All seven inputs: ordinary AV, video-only, audio-only, cropped time range, scaled range, concatenation crossing a segment boundary and panoramic video. Assert playback, stable pause, resume, 0.5×/2× rates, seek, images for video inputs and EOF. |
| Formats UI | Ten sources: two MP4 originals plus FFV1/H.264 MKV, HuffYUV AVI, FLV1 FLV, MPEG-2 TS, WMV2 ASF, MPEG-4 NUT and animated GIF. Require frames and no playback error. |
| Controls | Play/pause, time advancement/stability, seeking, speed and FFmpeg/native switches. |
| Effects/export | Both kernels: subtitle, danmaku, watermark, filter presets, GIF sticker, capture and GIF export. Toggle effects while paused. Screenshots are retained in xcresult attachments. |
| Orientation/font output | A synthetic red-top/blue-bottom MP4 is checked using actual rendered pixels from both backends. Chinese caption screenshots are checked against the full phrase “同步字幕”, with a known missing-glyph screenshot as a negative control. |
| Lifecycle/error | VR with overlays, stop/resume, missing-source rejection/recovery, rapid open/close and stale-capacity notification regression. |
| PiP | Both kernels: active-state checks, foreground/background transition, advancing media time, iPhone background submitted frames, return and stop. Mac activates Finder and restores the app. Unsupported tvOS capability is explicitly checked and skipped. |
| ASan/data | Filter output pixels/validation, RGB curves, SRT/VTT timing, ASS style/position/color, embedded multi-track metadata/font ownership, real DVD bitmap captions, danmaku seek determinism, watermark opacity, GIF frame delays/budget/cancel/EOF/atomic preservation, clocks, buffers, layout, resampling, HTTPS and H.264/HEVC software/VideoToolbox decode. |

Eight UI test methods group many actions; eight passing methods do not mean seven individual button clicks or mathematical 100% coverage. Assertions on state/frame progress are supplemented by data pixel tests and manual inspection of exported test screenshots. `scripts/check-caption-capture.swift` runs Vision OCR on captions; it checks the full subtitle phrase rather than a subtitle button label. `scripts/make-orientation-fixture.swift` regenerates the synthetic direction fixture. There is no claim that screenshots alone verify every rendered glyph or combination.

The tvOS simulator explicitly returns `isPictureInPictureSupported == NO`. The rejection branch is tested; active tvOS PiP is **not accepted**. Earlier iPhone runs while locked never executed tests and do not count as passes. Later unlocked-device result bundles provide the actual evidence.

## Reproduction

```sh
./build.sh all build --jobs 4
python3 scripts/verify-apple-builds.py --include-demos --jobs 2
python3 scripts/test-ffmpeg.py --asan --network --hardware --formats --features
python3 scripts/test-desktop-tv.py macos
python3 scripts/test-iphone.py --device 00008030-000E744C2E9B802E
python3 scripts/test-desktop-tv.py tvos --simulator 5A30B4A8-189B-4C3E-B32D-F237FBB7A02F

xcodebuild -workspace demo/demo.xcworkspace -scheme features-ui-macos \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build/FeatureUIMac CODE_SIGN_IDENTITY=- test
xcodebuild -workspace demo/demo.xcworkspace -scheme features-ui-ios \
  -destination 'id=00008030-000E744C2E9B802E' -derivedDataPath build/FeatureUIPhone \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration test
xcodebuild -workspace demo/demo.xcworkspace -scheme features-ui-tvos \
  -destination 'platform=tvOS Simulator,id=5A30B4A8-189B-4C3E-B32D-F237FBB7A02F' \
  -derivedDataPath build/FeatureUITV CODE_SIGNING_ALLOWED=NO test
```

Use the device/simulator identifiers on the test host. Keep the iPhone unlocked, connected and trusted. UI automation requires the host's existing test/Accessibility permissions. Do not run smoke and UI suites against the same app simultaneously: installation/launch would interrupt each other.

## Evidence and boundaries

Xcode results live under `build/FeatureUI{Mac,Phone,TV}/Logs/Test/*.xcresult`; smoke JSON/images under `build/RuntimeMac`, `build/runtime-macos`, `build/iPhoneDevice` and `build/RuntimeTV`; data results under `build/tests-asan/{formats,features}`. The final evidence manifest captures their paths, outcomes and source hashes. Initial FLV/ASF failures, missing font-resource packaging, the Metal/CI vertical inversion and a Mac EOF stall are retained as findings rather than silently counted as passing runs.

This covers the listed shipped demos and representative exposed feature paths on the specified host/device/runtime. It does not establish exhaustive combinations, oldest supported OS behavior, physical tvOS PiP, 4K/HDR/DRM, arbitrary PGS/DVB streams, all font/GIF dialects, live subtitle streaming, long-run power/memory stability or every system PiP control interaction. Native input support remains AVFoundation-dependent. Physical loudspeaker acoustic output was not instrumented; audio checks establish the decode/output-clock path. ASan instruments SGPlayer/tests, not the production dependency binaries.
