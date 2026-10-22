# 播放效果与内核选择

[English](media-features.en.md) | 简体中文

实现日期：2026-10-22，FFmpeg 9.0.2 / Xcode 27.1。本文替代此前的可行性评估；实际验收范围和限制见[测试记录](media-features-testing.zh-CN.md)。

## 使用入口

打开 `demo/demo.xcworkspace`。iPhone、Mac demo 新增 **All Features**；tvOS demo 直接展示共用功能界面。16 个按钮分别操作播放、暂停、跳转、内核、字幕、弹幕、水印、滤镜、GIF 贴纸、画中画、GIF 导出、停止、媒体选择、VR、倍速和截图。原有七个媒体示例仍通过原 demo 与自动化 smoke runner 覆盖。

使用 `SGPlaybackController` 显式选择 FFmpeg / 原生内核，并使用共用合成与系统 PiP。直接使用已有 `SGPlayer` 仍为 FFmpeg 播放器，不会自动改用 AVPlayer。控制器方法在主线程调用；独立字幕读取与 GIF 导出应在工作队列执行。

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
    // 检查 success 和 controller.error；保留时间及播放/暂停意图。
}];
```

原生内核使用 AVPlayer 与 AVPlayerItemVideoOutput，输入格式能力由 AVFoundation 决定。切换到原生不会使 FFmpeg 专用输入自动可播放；应用需检查错误并在适当时切回 FFmpeg。demo 对原生 VR 明确报错；VR 使用原有 FFmpeg/Metal 渲染器。

## 功能与配置

| 功能 | 行为 |
|---|---|
| 字幕 | `loadSubtitlesFromURL:completion:` 可读取外部 SRT/WebVTT/ASS，或媒体 URL 中的内嵌字幕流。`subtitleTracks` 提供轨道索引、语言、标题、默认/强制标记及独立持有的 cue/字体。`selectSubtitleTrack:` 选择轨道，`-1` 关闭。demo 按钮使用小型 SRT 示例；应用可自行展示完整轨道选择器。 |
| ASS | libass 渲染样式、字体、颜色、描边、位置及覆盖标签；FreeType、HarfBuzz、FriBidi 提供字形、整形及双向排版。内嵌 TTF/OTF 字节脱离 FFmpeg 源上下文独立持有。随包提供 Noto Sans CJK SC Regular（Sans2.004、OFL 1.1），避免 FreeType 无法读取 Apple 系统字体文件时中文缺字；可通过 `subtitleFallbackFontURL` 替换。 |
| 位图字幕 | FFmpeg 字幕矩形转换为独立 RGBA 图像，保留调色板透明度与归一化位置。已测试生成的 DVD 字幕流；PGS/DVB 格式互操作尚未专项验收。 |
| 字幕同步 | `subtitleOffset` 以秒偏移字幕。基于媒体时间计算，跟随暂停、跳转和倍速；缺失结束时间依次取下一个事件、媒体结束或三秒兜底。 |
| 弹幕 | `SGDanmakuItem` 提供起始时间、持续时间、文本和滚动/顶部/底部模式。按媒体时间确定位置，使用分区、轨道占用、数量限制和字形缓存，避免暂停漂移与同一轨道同时占用。 |
| 水印 | `SGWatermark` 支持文本和/或 CIImage、左上角归一化矩形及透明度。水印进入播放合成像素、截图和启用效果的 GIF 导出。 |
| 滤镜 | 选择 FFmpeg 时运行真正的 **libavfilter 图**；选择原生时使用 **Core Image**。支持亮度、对比度、饱和度、灰度、水平/垂直翻转、模糊及 RGB 曲线。赋值时复制配置并校验参数。 |
| 颜色曲线 | `colorCurves` 为 2–64 个交错 float RGB 采样，分量范围 `[0,1]`；它是一维 RGB 映射曲线，不是任意 3D `.cube` LUT 加载器。 |
| 动态 GIF | `SGAnimatedImage` 使用 ImageIO 解析帧、延时、透明/处置结果与循环信息，并限制解码内存。通过 `sticker`、`stickerRect`、`stickerStart` 设置随媒体时间变化的贴纸。 |
| GIF 导出 | `SGGIFExporter` 独立解码指定片段，支持进度、取消、尺寸、帧率和可选共用效果，不会跳转正在播放的实例。 |

FFmpeg 构建启用 `buffer`、`buffersink`、`format`、`scale`、`lutrgb`、`colorchannelmixer`、`hflip`、`vflip`、`gblur`。没有添加旧版 FFmpeg 分支或空兼容层。FFmpeg 与 Core Image 对同一参数的输出不保证逐像素一致。

共用合成位于 FFmpeg Metal 投影之后，或原生视频输出之后；文字/GIF 使用 CoreText/Core Image。同一合成像素供应显示、截图与 PiP 样本缓冲层。GIF 导出解码原始视频并应用效果，不复现实时 Metal VR 相机投影。iPhone 后台 FFmpeg PiP 使用 CPU 合成，长边限制 640 像素，避免后台提交 Metal；当前后台路径采用平面解码帧，不含 VR 投影。

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

更新效果时建议赋入完整数组/配置。合成与属性赋值同步，但并发修改已经赋入的 cue/水印对象仍由调用方负责。导出使用传入的效果实例；若要求整个导出配置固定，应在导出期间冻结该实例。

## 系统画中画

`startPictureInPicture:` 检查系统支持与当前来源是否就绪，通过 AVKit 和 AVSampleBufferDisplayLayer 启动。控制器实现播放/暂停、跳转完成回调、播放范围、生命周期及界面恢复。使用 `pictureInPictureChanged` 接收异步失败，使用 `restoreInterface` 恢复宿主窗口/视图；永久结束播放时调用 `close`。

应用需要配置音频/后台播放能力与音频会话，demo 已包含播放配置。模拟器或设备可能返回不支持，API 会明确报错；这不代表实际 PiP 已通过。DRM/受保护 AVPlayer 输出及所有系统/设备策略不在本轮验证范围内。

## 资源边界

- 字幕读取：整体中断期限 30 秒、网络 I/O 超时 10 秒，最多 100,000 个 cue、位图合计 128 MiB、字体合计 64 MiB/单字体 16 MiB。当前为有界全文件读取器，不是直播字幕流调度器。
- 字幕位图单边最多 8192、单矩形最多 64 MiB。
- GIF 导出：时长 `(0,30]` 秒、1–30 fps、最大边 32–1920 像素。先写临时文件，成功完成后原子替换；取消、EOF 或错误保留已有输出。
- 取消后新建 exporter，其取消标志不会自动复位；取消无法立即打断同步 demux I/O。
- 动画解码超出调用者预算时拒绝。合成像素缓冲池分配阈值为六个缓冲，字形缓存预算 16 MiB。
- 正确性用例不能证明持续 4K/HDR 性能、长时间内存稳定性、完整无障碍体验或所有字幕/GIF 方言互操作。

## 字幕依赖构建

`./build.sh all build` 构建 FFmpeg 与字幕/字体依赖的八个 SDK/架构切片。仅重建字幕使用 `python3 scripts/build-subtitles.py all --jobs 4`。需要 Python 3、首次下载时的网络及 PATH 中的 `pkg-config`；固定版本 Meson/Ninja 安装到 `build/feature-tools`。

`scripts/subtitle-sources.json` 固定官方下载来源、版本和 SHA-256：libass 0.17.5、FreeType 2.14.3、HarfBuzz 14.4.0、FriBidi 1.0.16。解压前校验，构建参数、归档清单、工具版本、SDK 与架构参与重建指纹。头文件/静态库合并到 `build/libs/<platform>/<universal|simulator>` 并链接进 SGPlayer；原 18 个 FFmpeg XCFramework 只包含 FFmpeg，不包含这四个新增库。

集成应用还需使用 AVKit、CoreImage、CoreText、ImageIO、UniformTypeIdentifiers、libc++、libiconv 及原有媒体框架，可参考项目中的实际构建设置。

**静态框架集成：**必须像三个 demo 一样，把 `NotoSansCJKsc-Regular.otf` 与 OFL 声明加入应用资源阶段。静态链接不会自动嵌入 framework 资源；这些类的 `bundleForClass:` 实际指向宿主应用，也可显式指定 `subtitleFallbackFontURL`。

CJK 字体使每个平台框架增加约 15.7 MiB，其官方来源、SHA-256 和字节数固定于 `scripts/subtitle-font.json`。

第三方声明见 [licenses](../licenses/README.md)。Portions of this software are copyright © The FreeType Project (www.freetype.org). All rights reserved.
