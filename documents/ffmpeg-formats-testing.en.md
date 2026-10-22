# FFmpeg container and codec regression

English | [简体中文](ffmpeg-formats-testing.zh-CN.md)

2026-10-22; physical Mac, FFmpeg 9.0.2, Xcode 27.1, ASan on SGPlayer/test sources. Current strict result: **8/8 passed**. [Current evidence](ffmpeg-formats-validation.json); [initial failure snapshot](ffmpeg-formats-validation.initial.json).

| Sample | Codec | Raw / player frames | Zero-duration frames | Accurate seek / EOF |
|---|---|---|---|---|
| ffv1.mkv | FFV1 | 60 / 60 | 0 | Pass |
| h264.mkv | H.264 | 60 / 60 | 0 | Pass |
| huffyuv.avi | HuffYUV | 60 / 60 | 0 | Pass |
| sorenson.flv | FLV1 | 60 / 60 | 0 | Pass |
| mpeg2.ts | MPEG-2 Video | 60 / 60 | 0 | Pass |
| wmv2.asf | WMV2 | 60 / 60 | 0 | Pass |
| mpeg4.nut | MPEG-4 Part 2 | 60 / 60 | 0 | Pass |
| animated.gif | GIF | 60 / 60 | 0 | Pass |

The original FLV/ASF run failed: each lost its first frame and emitted zero-duration frames. SGVideoDecoder now holds a frame with missing duration until the next PTS establishes its duration. EOF drains the pending frame using observed timing or available rate metadata. This restores positive durations and all 60 frames without a universal hard-coded 30 fps assumption.

Tests generate changing 64×48 video-only media using the linked FFmpeg encoders. They probe actual containers/codecs, use SGCodecContext for raw decoding, then SGURLDemuxer/SGVideoDecoder and YUV420P conversion for the player path. Checks cover checksums, dimensions, monotonic PTS, positive durations, default keyframe seek, explicit zero-tolerance seek and repeated EOF. GIF uses 10 fps; other fixtures use 30 fps. H.264 fixture encoding uses local VideoToolbox; format-case decoding is software.

The same eight fixtures are included in the three demo apps, alongside two MP4 inputs, for rendered-frame UI tests. See [feature testing](media-features-testing.en.md). MKV is a container, not an FFmpeg-exclusive format; tests explicitly select the FFmpeg backend and make no universal AVFoundation capability claim.

```sh
python3 scripts/test-ffmpeg.py --asan --network --hardware --formats --features
```

Expected exit: zero. Source: `tests/ffmpeg-formats.inc`; generated media/results: `build/tests-asan/formats/`. The production FFmpeg libraries are not ASan-instrumented. Synthetic round trips do not establish long/corrupt/VFR/HDR or all third-party-media interoperability. Embedded multi-track ASS/font and DVD bitmap-caption cases are tested separately by `tests/media-features.inc`.
