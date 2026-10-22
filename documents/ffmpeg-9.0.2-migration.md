# FFmpeg 9.0.2 升级说明

[English](ffmpeg-9.0.2-migration.en.md) | 简体中文

更新日期：2026-10-22。

本次统一以官方 FFmpeg 9.0.2 为依赖基线。代码中不保留旧 FFmpeg 版本分支、弃用接口或旧构建入口。

## 构建与集成

```sh
./build.sh macOS build
./build.sh iOS build
./build.sh tvOS build
# 或一次构建全部平台
./build.sh all build --jobs 4
```

构建入口为 `scripts/build-ffmpeg.py`，使用官方发布归档和固定 SHA-256。Python 3、Xcode、各平台 SDK 和 Metal Toolchain 为构建要求。离线构建可设置 `FFMPEG_ARCHIVE` 指向同一官方归档，仍然校验 SHA-256。

每个平台的源文件、编译参数、SDK/编译器版本和输出放在 `build/ffmpeg/9.0.2/`。配置输入变化时重新 configure，首次升级使用全新的版本目录，避免读取旧 `config.h`。

| 平台 | 设备/桌面库 | 模拟器库 |
|---|---|---|
| macOS | arm64、x86_64 | 无 |
| iOS | arm64 | arm64、x86_64 |
| tvOS | arm64 | arm64、x86_64 |

匹配的库和头文件位于 `build/libs/<平台>/universal/` 与 `build/libs/<平台>/simulator/`，Xcode 按 SDK 选择。设备和模拟器的 arm64 不进行 lipo 合并。每个库的 XCFramework 位于 `build/xcframeworks/<平台>/`。

TLS 显式使用 Apple SecureTransport，不再链接 OpenSSL。消费者需要链接 `Security.framework` 和 `CoreFoundation.framework`，各 demo 已配置。RTMP/RTMPS、HTTP/HTTPS、HLS、RTSP 的构建组件启用；依赖额外加密后端的 RTMPE/RTMPTE 未启用。远端直播服务的交互与重连仍应使用实际业务流验收。

静态库消费者应使用 `-ObjC`，避免 `-all_load` 强行载入 FFmpeg 不同库中重复的内部实现。demo 已去掉 `-all_load`，并通过显式跨工程 target 依赖解决同名 `SGPlayer.framework` 导致 tvOS 误选 iOS target 的问题。

## 播放器迁移

- 删除 `AVFrame.pkt_size` 访问。`SGFrame.size` 改为持有的解码 buffer 字节数，按底层 buffer 去重；VideoToolbox 帧使用像素缓冲大小。`SGPacket.size` 仍表示压缩包大小。
- `AVChannelLayout` 在 descriptor、copy、setter 和新帧之间进行深拷贝；析构释放布局，声道数与布局同步。
- 音视频帧使用 `av_frame_get_buffer()` 分配，避免对 YUV 内部平面地址分别释放。音频显式初始化为相应格式的静音，处理代码继续使用实际样本字节数，避免复制对齐填充。
- 固定平面数组的音频支持范围为 1–8 声道。超限解码输出在进入处理链前拒绝，非法 descriptor 设置抛出参数异常。
- VideoToolbox 设备使用 `av_hwdevice_ctx_create()` 完成初始化；复用已有设备引用，失败时选择支持的软件像素格式。软件回退属于当前硬解运行策略，与旧 FFmpeg 兼容分支无关。
- send/receive 在 EAGAIN 时取出输出再重发原包，显式处理 EOF；音频 EOF 排空格式转换/重采样尾部，避免丢失延迟样本。
- 时间转换检查 `AV_NOPTS_VALUE`，使用 CoreMedia 比率运算避免先乘时间戳导致整数溢出；音频缺失时间戳/时长时从连续采样信息推导。
- HTTP 默认选项使用 9.0.2 支持的 `user_agent` 和 `rw_timeout`，RTSP 将读写超时映射到其专用 socket timeout，不再使用原先删除 RTSP timeout 的逻辑。
- **删除公开属性 `SGDecoderOptions.refcountedFrames`**。新版解码接口返回引用计数帧，调用方须移除对该属性的赋值。本次不保留空实现或兼容别名。

## 验证方法与边界

完整记录见 [升级验证结果](ffmpeg-9.0.2-validation.json)与[测试记录](ffmpeg-9.0.2-testing.zh-CN.md)。此前的 `ffmpeg-upgrade-audit.md` 和 `ffmpeg-upgrade-audit-evidence.json` 是升级前基线归档。

```sh
# 纯数据链路及内存回归
python3 scripts/test-ffmpeg.py --asan
# 增加本地 HTTPS 与 H.264/HEVC 硬件编码/解码
python3 scripts/test-ffmpeg.py --asan --network --hardware
```

测试程序从 Xcode macOS target 中读取实际源文件列表，编译 SGPlayer 和测试代码并启用 AddressSanitizer。链接真实生产 FFmpeg 静态库，不使用替身；FFmpeg 库本身未启用 sanitizer 编译。测试不负责展示 Metal 画面。

运行检查包括：自定义声道布局生命周期、音频静音分配、超限声道、YUV 帧复制/回池、无效时间戳、44.1→48 kHz 精确采样数、完整 WAV 音频解码/格式转换及重复 EOF、带 B 帧视频解码/seek/flush、真实 H.264/HEVC 软硬解、本地 HTTPS 读取、拒绝不受信任证书和实际播放器 User-Agent。测试证书只用于本机测试，不改变播放器的生产证书配置。

三平台 FFmpeg 共八个 slice；SGPlayer 验证覆盖五个 SDK 的 Debug/Release，移动端模拟器和 macOS 同时覆盖 arm64/x86_64。framework 与 demo 均覆盖五个 SDK 的 Debug/Release，共 20 项构建全部通过，包含最终应用链接。

工具链统一为 Xcode 27.1（`.xcode-version`），工程和 FFmpeg 各 slice 直接设置最低 iOS/tvOS 15.0、macOS 12.0，无需命令行部署目标覆盖。`python3 scripts/verify-apple-builds.py --include-demos` 可复验全部平台、架构与 Debug/Release 构建。

真机测试包：`com.omnilink.fufucard`；自动签名使用已登录的 `whevether@outlook.com` 所属 OmniLink Exports Inc. 团队 `Z5TKWGS67N`。签名依赖 Xcode 中的账号会话和本机开发证书，不在仓库中保存凭据。

Debug demo 通过 `--sgplayer-smoke-test` 运行七个示例，逐项检查播放、暂停恢复、0.5/2 倍速、seek、EOF 和视频截图。Release 不包含测试入口。测试结束后继续播放首项，避免留下暂停画面。

测试设备为 iPhone 11（iOS 27.0）、当前 Mac（macOS 27.0.1）、Apple TV 4K 模拟器（tvOS 27.0）。tvOS 真机、远端直播、HDR/Main10、长时性能、最低系统版本仍需对应验收。自动化直接调用播放器接口，不代表每个 UI 按钮、遥控器焦点、VR 手势/陀螺仪和扬声器声学输出已完成交互或人工验收。


## Xcode 27.1 真机测试

已将 iPhone/tvOS demo 迁移到 UIScene 窗口生命周期，避免使用 Xcode 27.1 构建后被 iOS 27 在启动阶段终止。

iPhone 11 使用的 Debug 应用构建命令（无需部署目标覆盖）：

```sh
xcodebuild -workspace demo/demo.xcworkspace -scheme demo-ios -configuration Debug \
  -destination 'id=<已连接 iPhone 的 UDID>' -derivedDataPath build/iPhoneDevice \
  -allowProvisioningUpdates build
```

Xcode 自动使用团队 `Z5TKWGS67N` 匹配 `com.omnilink.fufucard` 的开发描述文件。安装到真机后，以 `--sgplayer-smoke-test` 参数启动可生成 `Documents/sgplayer-device-smoke.json` 和 `.png`；常规启动显示原有视频列表。

真机端到端复验入口：`python3 scripts/test-iphone.py --device <UDID>`。脚本为每次启动生成独立 run ID，避免误读上一次测试结果，并验证真机报告的 FFmpeg 版本为 9.0.2。成功后恢复常规 demo 界面，同时保留开发签名 IPA、JSON 与视频截图。

## 全部示例运行回归

```sh
python3 scripts/test-iphone.py --device <iPhone-UDID>
python3 scripts/test-desktop-tv.py macos
python3 scripts/test-desktop-tv.py tvos --simulator <booted-Apple-TV-UDID>
```

本轮发现并修复：storyboard/nib 创建路径遗漏播放器初始化；tvOS 未打包示例媒体；播放时改变倍速未立即更新时钟；Metal 渲染器仍使用旧的内嵌二进制。

`scripts/build-metal.py` 按当前 SDK 编译 shader 并生成静态 framework 使用的内嵌头文件，已删除三份历史 shader 数组。管线与库创建失败会记录错误并返回失败，避免提交空管线。时钟回归检查运行中改速立即生效，暂停中改速保持暂停。

7 个示例依次为音视频、纯视频、纯音频、裁剪、片段时间缩放、跨文件拼接、VR。拼接项额外检查跨越媒体片段边界。实际逐项结果见验证 JSON；未覆盖范围见上文。
