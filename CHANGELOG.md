# Changelog

English | [简体中文](CHANGELOG.zh-CN.md)

## Unreleased — 2026-10-22

These changes are present in the working tree. This entry does not indicate a published release or Git tag.

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

### Verification limits

Player-API automation does not validate every UI click, remote focus, VR gesture/gyroscope interaction or acoustic speaker output. Physical Apple TV, oldest supported systems, remote live streams, HDR/Main10 rendering and long-duration performance were not tested. The tvOS simulator uses software decoding. AddressSanitizer covers SGPlayer/test sources; the linked production FFmpeg libraries are not sanitizer-instrumented.

See the [test record](documents/ffmpeg-9.0.2-testing.en.md) and [migration guide](documents/ffmpeg-9.0.2-migration.en.md).
