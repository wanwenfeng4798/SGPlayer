# SGPlayer：FFmpeg 7.0.1 → 9.0.2 迁移审核

[English](ffmpeg-upgrade-audit.en.md) | 简体中文

> 本文为升级前审核归档。升级实施与当前验证结果见 [9.0.2 升级说明](ffmpeg-9.0.2-migration.md)。

审核日期：2026-10-22。项目基线：`d0c7ab85776fdb60979c60611a4b8085a6ef9a59`。

## 结论

**可以迁移，现有播放架构可以保留，但当前代码不能只修改版本号直接升级。** 已复现两类硬阻断：构建参数 `--disable-postproc` 已失效；`SGFrame.m` 两处读取的 `AVFrame.pkt_size` 已删除。另有既存的声道布局所有权、视频内存释放和硬解初始化问题，建议在迁移中修复，否则编译通过不足以证明可用。

目标选官方稳定发布 **9.0.2**，不追随 master。官方实时下载页显示其发布日期为 2026-09-18，9.0 分支切自 2026-06-26。搜索索引仍可能显示旧版本，因此本次以实际下载页及发布源码为准。[官方发布页](https://ffmpeg.org/download.html#release_9.0)

本次交付为迁移审核及验证证据，未修改播放器代码、构建版本和生产依赖。尚未完成全量静态库构建、链接、真机播放及最低系统版本测试，不能将本报告解释为升级已经完成。

## 1. 当前基线及证据边界

| 项目 | 当前仓库 | 迁移要求 |
|---|---|---|
| FFmpeg | `build.sh:8` 指定 `7.0.1` | 固定官方发布标签 `n9.0.2` 和对应提交/源码校验值 |
| 源码来源 | `scripts/init-ffmpeg.sh:21–22` 使用 `libobjc/FFmpeg` fork | 先对比实际旧提交与官方 `n7.0.1` 的差异，再决定切换官方仓库或移植补丁 |
| OpenSSL | `OpenSSL_1_1_1w` | 独立决定 TLS 后端及更新策略，不能把 TLS 构建成功当作 HTTPS 回归通过 |
| 平台 | iOS/tvOS arm64；macOS arm64、x86_64 | 三处架构清单及 Xcode 产物配置一起核对 |
| 模拟器 | iOS/tvOS 模拟器清单处于注释状态 | 如需交付，分别构建并用 XCFramework 组织设备与模拟器产物 |
| 最低系统 | iOS/tvOS 13.0、macOS 10.15 | arm64 macOS 用实际支持的最低版本校准；最低系统验收使用可用设备/系统 |
| 已有二进制 | 当前 checkout 无 `build/` 依赖产物 | 只能确认脚本声明版本，不能确认某个现有 App 的实际链接版本 |
| 自动测试 | 未发现项目测试 target/测试集 | 建立迁移专项用例和媒体样本基线 |

本次没有取得 fork 的完整提交差异，因此不声称它与官方 7.0.1 完全相同。升级时必须保存旧源码提交、configure 输出、旧库及代表性播放结果，才能可靠回退和比较。

## 2. 已执行验证

使用 Xcode 27.1（27A9275），下载官方 `ffmpeg-9.0.2.tar.xz` 并解包检查。该下载文件 SHA-256：

```text
8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e
```

此值记录本次下载内容，不代表已完成官方签名认证。

1. 原样加载项目 `scripts/module.sh` 的启用参数，在完整 9.0.2 源码中执行 configure，复现：`Unknown option "--disable-postproc"`。
2. 仅在临时审核环境去掉此参数，附加 `--disable-asm --disable-autodetect --disable-everything`，configure 成功，用于生成语法验证所需头文件。此配置**不验证**实际解码器、硬件加速、TLS、汇编或完整项目构建。
3. 排除注释后，检查到 57 个实际调用的 FFmpeg 函数，均能在新版公共头文件中找到声明。对包含调用的 17 个 Objective-C 实现文件，以 9.0.2 头文件执行 `clang -fsyntax-only -fobjc-arc -fblocks`。macOS arm64/x86_64、iOS arm64 设备/模拟器、tvOS arm64 设备/模拟器六种目标均为 **16/17 通过**；共 102 次文件级检查，96 次通过。唯一失败文件都是 `SGFrame.m`，错误均在 113、140 行的 `pkt_size`。
4. 单独检查当前编译器接受 macOS/iOS arm64 的 `-fembed-bitcode`，因此没有把该参数列为已复现的编译阻断；它仍应在现代构建方案中重新审视。

详细语法结果及方法见 [验证证据](ffmpeg-upgrade-audit-evidence.json)。这里只检查直接使用 FFmpeg 的文件；没有宣称全部 SGPlayer 源文件或 demo 已通过构建。跨平台语法检查共用 macOS 最小配置生成的公共配置头，只用于接口兼容性检查，不能替代各平台独立 configure 和链接。

## 3. 必须修改的迁移项

### P1：删除无效的 postproc 构建参数

位置：`scripts/module.sh:41`。

9.0.2 已不接受 `--disable-postproc`。原项目配置在编译之前就会停止。删除该参数后还必须运行完整生产配置；本次最小配置成功不证明外部依赖完整可用。

来源：[9.0.2 configure](https://github.com/FFmpeg/FFmpeg/blob/n9.0.2/configure)。

### P1：替换已删除的 AVFrame.pkt_size

位置：`SGPlayer/Classes/Core/SGData/SGFrame.m:113,140`。

7.0.1 中该字段已经弃用，9.0.2 中不存在。不能用简单的字段改名解决，也不应无条件置零。

需要先确定 `SGFrame.size` 的语义：

- 若表示解码帧内存占用，软件帧按实际持有的 buffer/平面计算，避免重复计算同一块 buffer；硬件帧需制定像素缓冲内存的估算策略。
- 若需保留原来的压缩包大小含义，可评估 `AV_CODEC_FLAG_COPY_OPAQUE` 与 `AVPacket.opaque_ref` 的元数据传递，但包和帧可能是多对多关系，不能假设总是一包对应一帧。

建议将帧内存统计与压缩包队列大小分别定义并记录，防止改变缓存控制行为。`SGFrameOutput.m:376–388` 使用容量大小的 15 MiB 门限控制读包，必须追踪此修改对容量通知和背压的实际影响。

来源：[7.0.1 frame.h](https://github.com/FFmpeg/FFmpeg/blob/n7.0.1/libavutil/frame.h)、[9.0.2 frame.h](https://github.com/FFmpeg/FFmpeg/blob/n9.0.2/libavutil/frame.h)。

### P1：构建必须能可靠切换源码和配置

位置：`scripts/init-ffmpeg.sh`、`scripts/do-compile-ffmpeg.sh:270–283`、`scripts/compile-ffmpeg.sh`。

当前只要发现 `config.h` 就复用 configure。修改版本、SDK、编译参数、TLS 或架构后，都可能继续使用旧配置。建议产物路径包含版本/平台/架构，并用源码提交、SDK、工具链及参数摘要控制重配。

迁移首次构建必须使用新输出目录，并核验头文件和静态库来自相同版本；所有 libav*、libsw* 库与消费者都重编译，不能混入旧 ABI。避免在有本地补丁的旧目录直接运行脚本中的强制 checkout/clean 操作。

## 4. 迁移时应修复的既存问题

以下问题不是由 9.0.2 新引入，语法编译也不会全部发现。

### P1：AVChannelLayout 浅拷贝造成所有权错误

位置：`SGAudioDescriptor.m:21,42`、`SGAudioFrame.m:37`，以及内部 `channelLayout` 属性的默认 setter。

`AV_CHANNEL_ORDER_CUSTOM` 布局包含动态 map。直接结构体赋值使 descriptor 和 frame 共享 map。源帧回池执行 `av_frame_unref()` 后，descriptor 可能持有悬空指针；将同一布局再直接交给新帧，可能出现重复释放。

迁移方案：descriptor 持有独立布局，初始化、copy、setter 使用 `av_channel_layout_copy()` 并检查失败；析构使用 `av_channel_layout_uninit()`；给新 AVFrame 设置布局同样深拷贝。若 setter 支持自赋值，先复制到临时布局再交换。将声道数与布局保持一致，拒绝或明确处理未知/不合法布局。

`SGSWResample.m:44–45` 的临时结构体只借用布局供函数读取，不能把所有结构体赋值一概认定为错误；重点是持有者的生命周期和 API 是否复制数据。

来源：[官方声道布局 API](https://github.com/FFmpeg/FFmpeg/blob/n9.0.2/libavutil/channel_layout.h)。

### P1：YUV 视频帧逐平面包装导致非法释放

位置：`SGVideoFrame.m:39–60`。

`av_image_alloc()` 为图像分配一整块内存，多个 plane 指向块内部。当前为每个 plane 创建默认释放回调的独立 `AVBufferRef`，并且 buffer size 只填一行宽度。帧释放时会尝试释放内部地址，buffer 记录范围也与真实图像不符。

建议使用 `av_frame_get_buffer()` 管理分配、平面和所有权；若保持手工分配，使用单一拥有整块内存的 buffer，并让 data/linesize 指向对应平面。分配失败必须向上返回错误，不能继续解引用空 buffer。

来源：[av_image_alloc 的分配/释放约定](https://github.com/FFmpeg/FFmpeg/blob/n9.0.2/libavutil/imgutils.h)。

### P1：VideoToolbox 设备未初始化，失败回退不可靠

位置：`SGCodecContext.m:152–183`。

当前只调用 `av_hwdevice_ctx_alloc()`，随后直接赋给 `hw_device_ctx`，没有完成 `av_hwdevice_ctx_init()`。应使用 `av_hwdevice_ctx_create()`，或明确 alloc/init 并检查结果。重复调用 `get_format` 时要处理已有引用，避免覆盖泄漏。

当前找不到可用硬件格式后直接返回 `fmt[0]`，可能再次选到硬件格式。应在候选列表中明确选择可支持的软件格式，并验证该格式能被现有缩放/渲染链路消费；无可用格式返回 `AV_PIX_FMT_NONE`。不需要为了升级强行启用目前注释的自定义 frames context；先保留 FFmpeg 自动管理帧池的路径。

来源：[官方硬件设备初始化约定](https://github.com/FFmpeg/FFmpeg/blob/n9.0.2/libavutil/hwcontext.h)。

### P2：多声道和平面数组边界

位置：`SGFrame.h:13`、`SGAudioFrame.m:39–47,123–126`、`SGSWResample.m:63–80`、`SGAudioDecoder.m:211`。

播放器固定使用 8 个 plane，读取 `frame->data` 而非完整的 `extended_data`。对超过 8 个声道的 planar 音频，现有实现可能越界或丢失平面。需要选择明确支持上限并在入口拒绝超限输入，或整体改用动态平面存储和 `extended_data`。只替换音频分配函数不足以完成后者。

同时检查 `swr_get_out_samples()`、`av_buffer_realloc()` 等失败返回及大小计算溢出，避免负值或空指针继续传入读写路径。

### P2：解码返回值、无效时间戳和旧选项

位置：`SGCodecContext.m:80–98,132–135`、`SGFrame.m:116–118`、`SGAudioFrame.m:87–89`、`SGAudioDecoder.m:199`。

- send/receive 架构可保留。send 返回 EAGAIN 时应先取出输出再重送原包；不能把所有负返回都直接当成空结果丢掉。当前通常会取尽输出，因此不能据此声称日常播放必然丢包，但应补齐错误路径及 EOF drain 验证。
- `best_effort_timestamp`、`pkt_dts` 仍存在，但必须检查 `AV_NOPTS_VALUE` 再转换 CMTime；duration=0 需要明确回退策略，尤其是变帧率及音频尾部。
- `refcounted_frames` 已不在新版 decoder 选项表中；当前把未消费 opts 直接释放，会掩盖无效设置。移除该内部选项；公开属性如保留，应明确兼容语义，调试时报告未识别选项。

来源：[官方解码状态机](https://github.com/FFmpeg/FFmpeg/blob/n9.0.2/libavcodec/avcodec.h)、[选项表](https://github.com/FFmpeg/FFmpeg/blob/n9.0.2/libavcodec/options_table.h)。

## 5. 可保留的接口与行为

| 模块 | 现有用法 | 9.0.2 核对结果 |
|---|---|---|
| 解复用 | `avformat_open_input/find_stream_info/read_frame/seek_file/close_input`、`stream->codecpar` | 现有调用语法通过，仍需网络和 seek 回归 |
| 解码 | `const AVCodec *`、`avcodec_parameters_to_context`、send/receive/flush/free | 无须回退到旧 decode 接口；补齐错误状态机 |
| 声道布局 | `ch_layout`、default/compare、`swr_alloc_set_opts2` | 已使用新接口；修复深拷贝和生命周期 |
| 重采样 | `swr_init/convert/get_delay/get_out_samples/free` | 现有调用语法通过；采样数、延迟、尾部仍需数值测试 |
| 缩放 | `sws_getCachedContext/sws_scale/freeContext` | 现有调用语法通过，不必强制重写成新 SwsContext 使用方式 |
| 帧/包 | alloc/ref/unref/free、`frame->duration`、`pkt_dts` | 仍可使用，`pkt_size` 必须替换 |
| VideoToolbox 取帧 | `AV_PIX_FMT_VIDEOTOOLBOX`、`frame->data[3]` 转 CVPixelBuffer | 官方实现仍使用该承载方式；保留 AVFrame 引用保证像素缓冲寿命 |
| 日志/字典/时间换算 | `av_log_*`、`av_dict_*`、`av_rescale*` | 现有调用语法通过 |

本次没有发现必须重写 Metal 或 AudioToolbox 播放架构的接口证据。新版增加解码器并不自动增加 SGPlayer 的渲染格式、HDR 映射或硬件支持。现有映射只覆盖有限格式，HEVC Main10/P010 等须检查实际输出、转换及颜色表现。

## 6. 构建和 TLS 决策

1. 初始化脚本使用官方仓库时，标签名要由当前 `7.0.1` 改成官方 `n9.0.2`；先完成 fork 补丁审计。不要假定 fork 具有相同标签和补丁。
2. `init-ffmpeg.sh`、`compile-ffmpeg.sh`、OpenSSL 对应脚本的架构清单要一致。设备 arm64 与模拟器 arm64 不能放入同一个 fat archive；每个平台变体分别 lipo，再用 XCFramework 交付。
3. 现有 `avconfig.h/ffversion.h/config.h` 按 CPU 分发，不表达设备/模拟器差异；新打包应让每个 slice 使用独立且匹配的头文件。
4. 9.0.2 configure 仍有 OpenSSL >=1.1.1 的探测路径，因此不能声称“升级 FFmpeg 必须升级 OpenSSL 3 才能编译”。但保留旧 TLS 库和采用受维护 TLS 方案是不同决策，建议另行迁移 TLS 依赖。当前禁用 GPL/nonfree，后续如改变许可开关需重新核对最终组合。
5. 当前脚本只有在 `libssl.a` 存在时显式启用 OpenSSL；缺失时存在后端自动探测带来的差异。必须记录最终 TLS 后端，分别验证 HTTPS、TLS HLS、RTMPS，不能仅凭文件存在判断。
6. `-fembed-bitcode`、固定 `make -j12`、Intel 全禁汇编等是构建现代化/性能检查项。当前编译器接受 bitcode 参数，不把它夸大为已确认故障。不同架构性能和最低 OS 兼容性以完整构建及运行测量为准。

来源：[9.0.2 configure 的 OpenSSL 检查](https://github.com/FFmpeg/FFmpeg/blob/n9.0.2/configure)。

## 7. 建议执行顺序及验收门槛

1. 固化 7.0.1 实际 fork 提交、补丁、库、configure 和媒体基线；保存可回退构建。
2. 在独立版本目录接入官方 9.0.2，修复 postproc 参数和配置缓存；完整构建所需平台/slice，核对库与头文件版本。
3. 修复 `pkt_size`、布局所有权和视频 buffer 分配；明确统计语义，补齐失败路径。
4. 修复硬解初始化和回退；收紧解码错误处理、无效时间戳及多声道边界。
5. 完成所有 SGPlayer target 和 demo 的编译、链接、运行及性能比较，再切换默认依赖。TLS 后端调整使用单独可比较的变更。

| 验收组 | 最少覆盖 | 通过条件 |
|---|---|---|
| 构建 | 三平台设备、所需模拟器、macOS 双架构；Debug/Release | 干净构建、版本一致，无混链旧库；demo 链接通过 |
| 软件视频 | H.264 B 帧、HEVC、YUV420P/NV12、奇数尺寸、变帧率、截图 | 帧数/时长对照合理，无非法释放和花屏 |
| 硬解 | H.264、HEVC、Main10；不支持硬解时回退；分辨率变化 | 明确记录是否实际走硬解；重建/回退不崩溃，无引用增长 |
| 音频 | AAC/MP3/FLAC；mono/stereo/5.1/7.1/custom layout；超限声道 | 声道无错位；复制后回收源帧仍可用；超限拒绝或完整处理 |
| 重采样/变速 | 44.1↔48 kHz、planar↔packed、0.5/1/2 倍速、EOF | 输出采样数和时长符合延迟/舍入约定，无尾音丢失和累计漂移 |
| 容器/时间 | MP4/MKV/TS；缺 PTS/DTS、非零起点、EOF/seek/重复 seek | 时间有效、音画同步，seek 后可继续解码 |
| 网络 | HTTP/HTTPS/HLS、RTSP、RTMP/RTMPS；断连/重连/取消 | 后端和选项明确；超时/取消有效，不在打开/读取时永久阻塞 |
| 内存/压力 | 帧回池、布局复制、反复开关、切轨、长时播放 | ASan/可用平台的内存检查无越界/UAF/非法释放，内存稳定 |
| 最低系统 | 支持的最低 iOS/tvOS/macOS 及当前系统 | 实机/对应系统可启动播放，无未满足符号和格式差异 |

最终放行标准：两项硬阻断修复，P1 所有权/硬解问题修复并测试，完整生产构建和代表性播放矩阵通过。当前审核证明迁移范围可控，并未证明这些验收条件已经满足。
