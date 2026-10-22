![Logo](https://github.com/libobjc/SGPlayer/blob/master/documents/banner.jpg?raw=true)


![Build Status](https://img.shields.io/badge/build-%20passing%20-brightgreen)  ![License](https://img.shields.io/badge/license-MIT-red) ![Platform](https://img.shields.io/badge/Platform-%20iOS%20macOS%20tvOS%20-blue)

# SGPlayer

English | [简体中文](README.zh-CN.md)

- SGPlayer is a powerful media play framework for iOS, macOS, and tvOS.

## Features

- iOS, tvOS, macOS.
- 360° panorama video.
- Compose complex asset.
- Background playback.
- RTMP/RTSP streaming.
- Setting playback speed.
- Multiple audio/video tracks.
- H.264/H.265 hardware accelerator.
- Accurate status notifications.
- Thread safety.
- Explicit FFmpeg/native playback kernels with shared subtitle, danmaku, watermark, GIF sticker and PiP composition.
- FFmpeg libavfilter / native Core Image filters, styled ASS, captures and independent GIF clip export.

The list above describes framework features; observed verification coverage is documented below.

## Based On

- FFmpeg
- Metal
- AudioToolbox

## Requirements

- iOS 15.0 or later
- tvOS 15.0 or later
- macOS 12.0 or later

The oldest supported systems have not been tested on devices.

## Getting Started

#### Build FFmpeg 9.0.2

The build uses the official FFmpeg 9.0.2 release archive with a pinned SHA-256.
HTTPS/RTMPS use Apple SecureTransport; OpenSSL is not required.
Xcode 27.1 (including the Metal Toolchain), its platform SDKs, Python 3, and `pkg-config` on PATH are required.
The build also pins libass 0.17.5, FreeType 2.14.3, HarfBuzz 14.4.0 and FriBidi 1.0.16;
Meson/Ninja are installed in a local build virtual environment.
The required Xcode version is pinned in `.xcode-version`.

```sh
git clone https://github.com/wanwenfeng4798/SGPlayer.git
cd SGPlayer

# iOS: arm64 device + arm64/x86_64 simulator
./build.sh iOS build

# tvOS: arm64 device + arm64/x86_64 simulator
./build.sh tvOS build

# macOS: arm64 + x86_64
./build.sh macOS build
```

Build all platforms with `./build.sh all build`. Adjust parallelism with `--jobs 4`.
To use a pre-downloaded official archive, set `FFMPEG_ARCHIVE=/absolute/path/ffmpeg-9.0.2.tar.xz`;
the same checksum is verified. `./build.sh <platform> clean` removes generated outputs.

Sources and per-SDK/architecture build inputs are under `build/ffmpeg/9.0.2/`.
Libraries and matching headers are under `build/libs/<platform>/universal/` (device/macOS)
and `build/libs/<platform>/simulator/`. Xcode selects the variant using the SDK.
Each library is also packaged in `build/xcframeworks/<platform>/`.
Device and simulator arm64 slices remain separate.

Run the macOS data-path regression tests after building dependencies:

```sh
python3 scripts/test-ffmpeg.py --asan
```

The migration removes `SGDecoderOptions.refcountedFrames`; FFmpeg's decoding API always
returns reference-counted frames. Audio supports up to eight channels; unsupported input
is rejected before fixed-size plane arrays are used. Frame `size` now reports decoded
buffer memory, while packet `size` retains compressed bytes.

All projects and FFmpeg slices target macOS 12.0 and iOS/tvOS 15.0 directly.
Validate all platform/configuration builds with
`python3 scripts/verify-apple-builds.py --include-demos`. No deployment-target overrides are needed.
The iPhone demo uses `com.omnilink.fufucard` and OmniLink Exports Inc. (`Z5TKWGS67N`).
With the account signed in to Xcode and an iPhone connected, sign, install and test it with
`python3 scripts/test-iphone.py --device <UDID>`.
The Debug test runs all seven samples and checks playback, pause/resume, 0.5x/2x rates,
seek, EOF, VideoToolbox frames and screenshots;
its results, frame image and development IPA are saved under `build/iPhoneDevice/`.
Run the same seven samples on the physical Mac with
`python3 scripts/test-desktop-tv.py macos`, or on a booted Apple TV simulator with
`python3 scripts/test-desktop-tv.py tvos --simulator <UDID>`.
Metal shaders are rebuilt and embedded per SDK; the historical shader binaries are removed.
These runtime checks exercise player APIs, rather than UI gestures or acoustic output.
On 2026-10-22, all seven samples passed on physical iPhone 11, physical Mac and tvOS simulator,
and all 20 framework/demo Debug/Release builds passed. The tvOS simulator uses software decoding.
Remote live streams, HDR, long-duration performance, remote focus and VR gestures/gyroscope
interaction remain outside this verification scope.

## Documentation

- Migration guide: [English](documents/ffmpeg-9.0.2-migration.en.md) / [中文](documents/ffmpeg-9.0.2-migration.md)
- Test record: [English](documents/ffmpeg-9.0.2-testing.en.md) / [中文](documents/ffmpeg-9.0.2-testing.zh-CN.md)
- Changelog: [English](CHANGELOG.md) / [中文](CHANGELOG.zh-CN.md)
- Playback features and backend routing: [English](documents/media-features.en.md) / [中文](documents/media-features.zh-CN.md)
- Feature test record: [English](documents/media-features-testing.en.md) / [中文](documents/media-features-testing.zh-CN.md)
- Historical feature assessment: [English](documents/media-features-assessment.en.md) / [中文](documents/media-features-assessment.zh-CN.md)
- Additional format tests (8/8 after FLV/ASF timing fix): [English](documents/ffmpeg-formats-testing.en.md) / [中文](documents/ffmpeg-formats-testing.zh-CN.md)
- [Machine-readable validation evidence](documents/ffmpeg-9.0.2-validation.json)
- Pre-upgrade audit archive: [English](documents/ffmpeg-upgrade-audit.en.md) / [中文](documents/ffmpeg-upgrade-audit.md). It describes the old baseline, not the current implementation.

#### Open demo project in Xcode

- Open demo/demo.xcworkspace. You can see simple use cases.

#### Check Dependencies

```obj-c
- SGPlayer.framework
- AVKit.framework
- CoreImage.framework
- CoreText.framework
- ImageIO.framework
- UniformTypeIdentifiers.framework
- libc++.tbd
- libiconv.tbd
- AVFoundation.framework
- AudioToolBox.framework
- VideoToolBox.framework
- Security.framework
- CoreFoundation.framework
- libz.tbd
```

## Flow Chart

![Flow Chart](https://github.com/libobjc/SGPlayer/blob/master/documents/flow-chart.jpg?raw=true)

## Author

- GitHub : [Single](https://github.com/libobjc)
- Email : libobjc@gmail.com

## Developed by Author

- [KTVHTTPCache](https://github.com/ChangbaDevs/KTVHTTPCache) - A smart media cache framework.
- [KTVVideoProcess](https://github.com/ChangbaDevs/KTVVideoProcess) - A High-Performance video effects processing framework.

## Third-party notices

See [subtitle dependency licenses](licenses/README.md). Portions of this software are copyright © The FreeType Project (www.freetype.org). All rights reserved.
