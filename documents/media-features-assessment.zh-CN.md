> 本文保留为实现前的历史评估。功能现已实现，请以[当前使用文档](media-features.zh-CN.md)和[测试记录](media-features-testing.zh-CN.md)为准；下方方案与覆盖描述仅代表此前快照。

# 字幕、弹幕、画中画、水印、滤镜与 GIF 可行性评估

[English](media-features-assessment.en.md) | 简体中文

评估日期：2026-10-22。范围：当前 FFmpeg 9.0.2 / Xcode 27.1 分支，iOS 15+、macOS 12+、tvOS 15+。本轮只评估功能，不修改播放器、demo 或依赖构建配置；新增代码限于多格式回归测试。下述模块名、方案和工期均是建议，不表示功能已经实现。

## 结论与实施难度

六类功能均有实现路径。字幕、弹幕、水印需要共用时间线及叠加层；画中画和“带效果的截图/GIF”需要真正的合成帧输出，不能只叠加普通 UI。建议先确立共享输出架构，再分阶段实现。

| 功能 | 当前状态 | 推荐实现 | 难度 |
|---|---|---|---|
| 字幕 | 已识别字幕轨类型，无解码/选择/显示链路 | cue 时间线 + 文本/位图渲染；复杂 ASS 单独接 libass | 中；完整 ASS/PGS 较高 |
| 弹幕 | 无调度/轨道避碰/渲染模块 | 媒体时钟驱动的轨道调度 + 字形缓存 + GPU 合成 | 中 |
| 系统画中画 | Metal 显示，无系统 PiP 数据源 | CVPixelBuffer → CMSampleBuffer → AVSampleBufferDisplayLayer → AVKit | 较高 |
| 水印 | 无水印 API | 文本/图片纹理合成；区分预览叠加与输出内嵌 | 低至中 |
| 滤镜 | 有视频 processor 扩展点，无滤镜图；FFmpeg filters 被禁用 | 基础实时效果先用 Metal/Core Image | 中；复杂滤镜链较高 |
| GIF | FFmpeg GIF 编解码已启用，无动画产品功能/导出服务 | 分别实现 GIF 播放、动画叠加、视频片段导出 | 中 |

## 代码核对依据

- [SGDefines.h](../SGPlayer/Classes/Core/SGCommon/SGDefines.h)、[SGMapping.m](../SGPlayer/Classes/Core/SGDefine/SGMapping.m) 已有 `SGMediaTypeSubtitle` 与 `AVMEDIA_TYPE_SUBTITLE` 映射。
- [SGURLDemuxer.m](../SGPlayer/Classes/Core/SGDemuxer/SGURLDemuxer.m) 枚举全部流；[SGFrameOutput.m](../SGPlayer/Classes/Core/SGSession/SGFrameOutput.m) 只创建音视频解码循环，只默认选择/分发音视频包。
- [SGPlayerItem.h](../SGPlayer/Classes/Core/SGSession/SGPlayerItem.h) 只有音视频选择接口；[SGTrack.h](../SGPlayer/Classes/Core/SGAsset/SGTrack.h) 不提供语言、标题、默认/强制轨等公开属性。
- [SGClock.m](../SGPlayer/Classes/Core/SGRenderer/SGClock.m) 已有媒体时钟；[SGCodecDescriptor.m](../SGPlayer/Classes/Core/SGDescription/SGCodecDescriptor.m) 与 extracting demuxer 已有裁剪、时间缩放和偏移映射。
- [SGProcessorOptions.h](../SGPlayer/Classes/Core/SGOption/SGProcessorOptions.h) 允许替换 `videoClass`；[SGVideoProcessor.m](../SGPlayer/Classes/Core/SGProcessor/SGVideoProcessor.m) 默认只筛选轨道并透传。
- [SGVideoRenderer.m](../SGPlayer/Classes/Core/SGRenderer/SGVideoRenderer.m) 直接绘制至 Metal drawable；`currentImage` 从当前解码帧生成图片，不是最终屏幕/VR/叠加结果。`frameOutput` 是观察即将渲染的帧，不是效果处理后帧的替换接口。
- [build-ffmpeg.py](../scripts/build-ffmpeg.py) 配置 `--disable-filters --disable-autodetect`。本机构建的 `CONFIG_ASS_FILTER`、`CONFIG_SUBTITLES_FILTER`、`CONFIG_OVERLAY_FILTER`、`CONFIG_DRAWTEXT_FILTER`、`CONFIG_PALETTEGEN_FILTER`、`CONFIG_PALETTEUSE_FILTER` 均为 0。存在 `libavfilter.a` 不等于这些滤镜可用。

## 字幕

建议首版支持外挂 UTF-8 SRT/WebVTT、容器内文本字幕、单轨选择/关闭、语言/强制标记、字体/颜色/字号、底部安全区和时间偏移。轨道列表要复制语言/title/disposition 等信息，不能让调用方长期依赖生命周期有限的 `AVStream *`。

需要新增 cue 数据模型（起止时间、文本/位图、样式、区域）、字幕解码器、稀疏队列、选轨状态和 renderer。字幕通常很稀疏，队列不能让音视频等待“字幕缓冲充足”，也不能延迟主媒体 EOF。seek、换轨、换媒体要清空旧 cue 并用会话标识丢弃迟到结果；暂停、倍速、裁剪和拼接均使用同一媒体时间映射。

**不能直接复用音视频 send/receive 假设。** 实际 9.0.2 头文件仍提供 `avcodec_decode_subtitle2()`、`AVSubtitle`、`AVSubtitleRect` 和 `avsubtitle_free()`；须为字幕设计独立的内存释放、flush、时长推导与清屏逻辑。[FFmpeg 解码 API](https://ffmpeg.org/doxygen/trunk/group__lavc__decoding.html)；最终实现以本地固定版本头文件为准。

ASS/SSA 应区分“提取纯文本”和“完整样式兼容”。CoreText 能做普通排版，但不能据此承诺 ASS 动画、卡拉 OK、描边、字体附件与定位兼容。完整 ASS 建议接 [libass](https://github.com/libass/libass)，增加其字体整形依赖、八个构建 slice、字体附件处理及资源限制。PGS/DVD/DVB 位图字幕需要调色板、透明度、画布/区域和持续/清除事件。OCR 不属于此功能的必要部分。

验收：中文/英文/RTL、多行重叠、缺失结束时间、外挂与内嵌切换、快速 seek、变速/拼接、开启关闭、无字幕文件、PiP 与截图的可见性。HLS/直播字幕单独验收，不能从文件字幕推导支持。

## 弹幕

建议首版以离线 JSON/内存事件列表输入，支持滚动与顶部/底部固定、开关、透明度、字号、密度限制和屏蔽。网络服务、账户和审核系统属于独立范围，本轮不设计或接入这些 API。

调度使用媒体时间，不使用独立墙钟动画；暂停即停，倍速改变媒体推进，seek 后按时间重新索引。轨道分配需检查前后弹幕相对速度，防止后发长文本追上前发文本；还要为字幕和控制区域留空间。大量文字采用 CoreText 字形/纹理缓存、对象复用和最大可见数量，不能每帧创建大量 UILabel/NSView。

普通 view 叠加可以快速形成原型，但不会自动进入系统 PiP、导出或当前 `currentImage`。需要进入这些输出时，弹幕必须参与像素合成，并明确是否在小窗中启用。VR 首版建议屏幕固定叠加；球面/左右眼空间弹幕另作范围。

验收：低/高密度、长中文与 emoji、相向速度/避碰、暂停/倍速/seek、前后台、横竖屏与窗口缩放、字幕避让、PiP 开关和内存上限。

## 系统画中画

本机 Xcode 27.1 三平台 SDK 的 AVKit 头文件均声明 sample-buffer content source，最低 iOS/tvOS 15、macOS 12，正好覆盖工程最低版本。API 可编译不代表每台设备都可运行，须检查系统支持与当前 possible 状态，并分别验收三平台。[Apple content source](https://developer.apple.com/documentation/avkit/avpictureinpicturecontroller/contentsource-swift.class)；[sample-buffer 初始化](https://developer.apple.com/documentation/avkit/avpictureinpicturecontroller/contentsource-swift.class/init(samplebufferdisplaylayer:playbackdelegate:))。

现有 Metal view 不能直接作为系统 PiP source。建议保留 FFmpeg 解码和现有音频，用 `AVSampleBufferDisplayLayer` 接受视频 sample buffer，并由 `AVPictureInPictureController` 接入播放/暂停、可播放时间范围、skip 和状态变化。需要新增 AVKit 集成、像素缓冲/格式描述/sample-buffer 管理、背压、时间基同步、seek flush、恢复界面与中断生命周期。不能漏掉 skip 完成回调，否则系统 UI 可能卡在 seeking。

无效果的 VideoToolbox NV12 帧可评估直接复用；软件帧需转兼容像素缓冲；带字幕/水印/滤镜/VR 的画面需从离屏合成结果输出。禁止把解码复用的缓冲直接原地改写。音频继续使用同一个播放器实例，不能另开第二套音轨造成重音或漂移。

iOS 还须核对后台模式、AVAudioSession、中断及现有后台暂停策略，尤其纯视频。tvOS 自动从 inline 启动等能力与 iOS 不完全相同，不能复制所有属性。tvOS 无真机时只能记录模拟器结果，不能完成系统 PiP 真机验收。

## 水印

区分预览水印和实际进入截图/PiP/导出像素的水印。前者可以用 view/layer，后者应以 Metal 混合文本/图片纹理；动态时间/用户标识按需刷新缓存，不要每帧重排静态文字。

建议定义归一化位置、锚点、透明度、缩放、安全边距、图片/文字内容与输出策略。必须明确坐标是视频内容区还是整个控件；处理 letterbox、aspect-fill 裁切、旋转、VR 和小窗缩放。水印不等同于防截屏或 DRM。

验收：透明 PNG、中文、旋转/裁切、窗口变化、多层水印、导出一致性与按输出关闭策略。

## 滤镜

首版建议亮度、对比度、饱和度、灰度、简单 LUT，并定义参数范围、执行顺序及重置。推荐 Metal 或复用 CIContext 的 Core Image 路径，尽量保持 GPU 数据流；`videoClass` 可承载 CPU 类处理，但仅替换 processor 并不能自动提供最终屏幕合成。

如果明确需要 FFmpeg filter graph，必须重新启用所需 filters 及 buffer/buffersink 等组件、复建八个 slice，并实现图创建/重建、参数变化、格式协商、EOF drain、seek flush。`drawtext`/`subtitles` 等还涉及外部依赖；不能假设现有配置可直接调用。

VideoToolbox 帧若为 CPU 滤镜反复下载/上传，可能失去硬解收益。异步 GPU 必须保持帧引用直到 command buffer 完成，使用缓冲池与背压；处理色域、矩阵、limited/full range、预乘 alpha。首版可限定 SDR 8-bit，HDR/Main10 需单独设计与测量，不能自动继承支持。

验收：已知颜色参考、参数边界、多级顺序、软硬解切换、0.5/2 倍速、seek/flush、内存与持续负载。

## GIF：输入、叠加、导出是三项能力

1. **GIF 作为媒体播放**：现有 GIF 解复用/解码组件已启用。本轮新增测试覆盖 60 帧动画与零容差 seek；具体结果见多格式报告。产品仍须定义循环次数、变帧延迟、暂停/拖动及结束策略。
2. **GIF 作为动画水印/贴纸**：用 FFmpeg 或 ImageIO 解码，再作为有自身时间轴的纹理叠加。需实现 disposal、透明度、循环、零/过短延迟策略与缓存上限，不能无界预解码所有大图帧。
3. **视频片段导出 GIF**：新增后台任务，从指定区间的已解码/合成帧进行降帧、缩放和调色板量化，再编码输出，支持取消、进度和资源预算。先做例如 5 秒/10 fps/不超过 720 像素的受限档位，再测性能；这些数值是建议范围，不是现有能力。

本机已启用 GIF encoder，但 `palettegen/paletteuse` 被禁用；FFmpeg GIF 编码器不等于完整视频转 GIF 服务。可选 ImageIO `CGImageDestination` 或显式颜色量化后交给 FFmpeg。两条路径均须验证帧延迟、循环、透明色、disposal 与输出读取兼容性。[Apple ImageIO](https://developer.apple.com/documentation/imageio/cgimagedestination)。

不要轮询 `currentImage` 导出：它取原始帧，不能保证帧率、最终滤镜/字幕/水印或导出期间的播放独立性。离线导出可用独立解码会话，避免 seek 当前正在播放的视频；输出包含哪些叠加内容应由显式策略决定。

## 推荐共享架构与工作量

建议架构：`FFmpeg 解码 → 时间映射 → 可选滤镜 → VR/平面投影 → 字幕/弹幕/水印合成 → 显示 / PiP / 截图 / GIF`。字幕等屏幕固定叠加在投影后合成；视频坐标水印按产品定义决定顺序。使用独立 overlay/event model，避免把 UI 控件直接混入底层解码器。

先建立有版本标识的会话、单一媒体时钟查询、离屏纹理/像素缓冲输出、资源预算及 seek flush；再实现简单字幕/水印、弹幕、PiP、滤镜与 GIF。先处理新增格式测试暴露的时长问题，避免新功能继承时间线缺陷。

以下为工程判断，假设一名熟悉 Objective-C/Metal/FFmpeg 的工程师、已有交互设计、首版 SDR、跨三平台，不含复杂 ASS/PGS、在线弹幕后端和 HDR：

| 工作项 | 估计人日 |
|---|---|
| 共享时间线、离屏输出与缓冲管理 | 5–8 |
| 简单外挂/内嵌文本字幕 | 5–8 |
| 离线弹幕 | 4–7 |
| 三平台 PiP 接入 | 7–12 |
| 文本/图片水印 | 2–4 |
| 基础滤镜 | 4–7 |
| GIF 播放完善、贴纸与受限导出 | 4–7 |
| 集成、真机和压力回归 | 6–10 |

合计约 37–63 人日，是粗估而非交付承诺；共享工作避免重复计算，仍需原型后细化。完整 ASS、位图字幕、复杂滤镜链及 HDR 会增加范围；缺少 Apple TV 真机是该平台最终 PiP 验收条件的缺口。

## 多格式测试与边界

详见[多格式测试记录](ffmpeg-formats-testing.zh-CN.md)及[机器可读证据](ffmpeg-formats-validation.json)。容器和编码必须分别描述：MKV 不等于一种视频编码，也不是全世界只有 FFmpeg 能解析；本轮通过实际调用链确认使用项目链接的 FFmpeg，不依赖 AVPlayer 的格式能力。

本轮新样本在 Mac 上验证，不把结果扩展为 iPhone/tvOS 新格式已完成真机播放。现有三平台 7 个 MP4 示例回归属于前一次独立测试。新发现只记录，未修改生产播放器。
