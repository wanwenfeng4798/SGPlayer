# FFmpeg 容器与编码格式回归

[English](ffmpeg-formats-testing.en.md) | 简体中文

2026-10-22；物理 Mac、FFmpeg 9.0.2、Xcode 27.1，SGPlayer/测试源启用 ASan。当前严格验收：**8/8 通过**。[当前证据](ffmpeg-formats-validation.json)；[首次失败快照](ffmpeg-formats-validation.initial.json)。

| 样本 | 编码 | 原始 / 播放器帧数 | 零时长帧 | 精确跳转 / EOF |
|---|---|---|---|---|
| ffv1.mkv | FFV1 | 60 / 60 | 0 | 通过 |
| h264.mkv | H.264 | 60 / 60 | 0 | 通过 |
| huffyuv.avi | HuffYUV | 60 / 60 | 0 | 通过 |
| sorenson.flv | FLV1 | 60 / 60 | 0 | 通过 |
| mpeg2.ts | MPEG-2 Video | 60 / 60 | 0 | 通过 |
| wmv2.asf | WMV2 | 60 / 60 | 0 | 通过 |
| mpeg4.nut | MPEG-4 Part 2 | 60 / 60 | 0 | 通过 |
| animated.gif | GIF | 60 / 60 | 0 | 通过 |

首次运行中 FLV/ASF 均丢失首帧并输出零时长帧。现在 SGVideoDecoder 暂存缺失时长的帧，以后续 PTS 推导时长，EOF 时使用已观察的时间或可用帧率元数据排出待定帧，恢复全部 60 帧和正时长，没有统一硬编码为 30 fps。

测试使用链接的 FFmpeg 编码器生成像素变化的 64×48 纯视频。先探测实际容器/编码，通过 SGCodecContext 检查原始解码，再经 SGURLDemuxer/SGVideoDecoder 与 YUV420P 转换检查播放路径。断言包括像素校验、尺寸、单调 PTS、正时长、默认关键帧跳转、显式零容差跳转和重复 EOF。GIF 为 10 fps，其他样本 30 fps；H.264 样本由本机 VideoToolbox 编码，多格式用例明确采用软件解码。

这八个样本连同两个 MP4 输入加入三平台 demo，执行实际出帧 UI 测试，见[功能验收](media-features-testing.zh-CN.md)。MKV 是容器，并非只有 FFmpeg 才能解析；测试明确选择 FFmpeg 内核，不对 AVFoundation 做普遍能力结论。

```sh
python3 scripts/test-ffmpeg.py --asan --network --hardware --formats --features
```

预期退出码为零。源码为 `tests/ffmpeg-formats.inc`，生成媒体/结果位于 `build/tests-asan/formats/`。生产 FFmpeg 静态库未启用 ASan。合成样本回环不能证明长视频、损坏索引、VFR、HDR 或所有第三方媒体兼容性。内嵌多轨 ASS/字体、DVD 位图字幕由 `tests/media-features.inc` 单独验证。
