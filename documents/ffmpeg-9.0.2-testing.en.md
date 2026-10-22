# FFmpeg 9.0.2 test record

English | [简体中文](ffmpeg-9.0.2-testing.zh-CN.md)

Test date: 2026-10-22 (Asia/Shanghai). These are observed results from this run. See the [validation evidence](ffmpeg-9.0.2-validation.json) for machine-readable details.

## Environment and builds

FFmpeg 9.0.2; Xcode 27.1 (27A9275). Eight dependency slices and 18 per-library XCFrameworks were built. Projects directly target iOS/tvOS 15.0 and macOS 12.0 without command-line deployment overrides.

| SDK | Architectures | Framework Debug/Release | Demo Debug/Release |
|---|---|---|---|
| macosx | arm64, x86_64 | All passed | All passed |
| iphoneos | arm64 | All passed | All passed |
| iphonesimulator | arm64, x86_64 | All passed | All passed |
| appletvos | arm64 | All passed | All passed |
| appletvsimulator | arm64, x86_64 | All passed | All passed |

All 20 builds passed. Commands and log paths are recorded in `build/verification/xcode-27.1/results.json`.

## Runtime results

| Environment | OS | Samples passed | Video frames output | VideoToolbox frames |
|---|---|---|---|---|
| Physical iPhone 11 | iOS 27.0 | 7/7 | 1851 | 1851 |
| Physical Mac | macOS 27.0.1 | 7/7 | 1873 | 1873 |
| Apple TV 4K simulator | tvOS 27.0 | 7/7 | 1848 | 0 (software decoding) |

Frame counts are cumulative observations during the control sequence. Timing affects them; they are neither performance benchmarks nor total file frame counts.

Each platform runs these samples in order:

1. `I See Fire`: audiovisual playback.
2. `I See Fire, Video Track`: video only.
3. `I See Fire, Audio Track`: audio only.
4. `I See Fire, Range: 30s-40s`: trimmed segment.
5. `I See Fire, Range: 30s-50s, Scale: 0.5`: segment time scaling.
6. `I See Fire + Google Help`: cross-file concatenation.
7. `Google Help VR`: VR display mode.

All 21 sample runs passed. Each checks playback time progression, stable pause, resume, 0.5x/2x rates, recovery after seek and EOF. Video cases check frame output and screenshots; audio-only playback does not require video frames or screenshots. The concatenation case additionally crosses a segment boundary. Observed Mac/tvOS rates were approximately 0.51x and 1.98x; individual measurements are in the JSON.

## Data-path and memory regression

`python3 scripts/test-ffmpeg.py --asan --network --hardware` passed:

- Custom channel-layout ownership, channel limits, audio silence, YUV allocation/copy/pooling and timestamp guards.
- Exact 44.1→48 kHz sample counts, full WAV decoding/formatting, repeated EOF and resampling tail drain.
- MPEG-4 B-frame decoding and seek/flush; real H.264/HEVC software and hardware decoding.
- HTTPS/SecureTransport, self-signed certificate rejection and the player's User-Agent.
- Immediate clock rate changes while playing, with pause preserved when changing rate while paused.

AddressSanitizer instruments SGPlayer and test sources. The linked production FFmpeg libraries are not sanitizer-instrumented.

## Reproduction and artifacts

Build dependencies using the [migration guide](ffmpeg-9.0.2-migration.en.md), then run:

```sh
python3 scripts/verify-apple-builds.py --include-demos
python3 scripts/test-ffmpeg.py --asan --network --hardware
python3 scripts/test-iphone.py --device <connected-iPhone-UDID>
python3 scripts/test-desktop-tv.py macos
python3 scripts/test-desktop-tv.py tvos --simulator <booted-Apple-TV-UDID>
```

The iPhone must be unlocked, trust the Mac, have Developer Mode enabled and use valid Xcode development signing. For tvOS, install the runtime and boot an Apple TV simulator. Scripts validate a unique run ID to reject stale reports.

| Artifact | Workspace path |
|---|---|
| iPhone per-sample report | `build/iPhoneDevice/smoke-result.json` |
| iPhone development-signed IPA | `build/iPhoneDevice/com.omnilink.fufucard-development.ipa` |
| iPhone video screenshot | `build/iPhoneDevice/smoke-frame.png` |
| Mac per-sample report | `build/RuntimeMac/runtime-result.json` |
| Mac per-sample screenshots | `build/runtime-macos/demo-case-<index>.png` |
| tvOS per-sample report | `build/RuntimeTV/runtime-result.json` |
| tvOS rendered-screen capture | `build/RuntimeTV/rendered-screen.png` |
| tvOS normal-launch capture | `build/RuntimeTV/normal-launch.png` |

`build/` contains local generated artifacts; a fresh checkout must rebuild and rerun tests. The repository validation JSON preserves this run's results. The iPhone uses `com.omnilink.fufucard` with OmniLink Exports Inc. signing and returns to the normal demo interface after testing. Video was also observed through the normal tvOS entry point.

## Uncovered scope

This is not complete interactive acceptance testing of every feature. UI click/navigation hit testing, remote focus, VR gestures/gyroscope interaction, acoustic speaker output, physical Apple TV, oldest supported systems, remote live-stream interaction/reconnection, HDR/Main10 color rendering and long-duration performance were not tested. Enabled protocol components do not establish compatibility with actual remote services. RTMPE/RTMPTE are not enabled in the SecureTransport build.
