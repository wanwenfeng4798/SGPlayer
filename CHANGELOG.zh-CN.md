# 修改日志

[English](CHANGELOG.md) | 简体中文

## 尚未发布 — 2026-10-22

以下改动已在工作区实现。本条记录不表示已发布版本或创建 Git 标签。

### 不兼容变更

- 要求 FFmpeg 9.0.2、Xcode 27.1 和 Metal Toolchain。工程最低系统直接设为 iOS/tvOS 15.0、macOS 12.0。
- 删除 `SGDecoderOptions.refcountedFrames`，不提供别名或空实现；调用方须删除相关赋值。
- 解码后 `SGFrame.size` 改为持有的 buffer 字节数，按底层分配去重；`SGPacket.size` 保持压缩包字节数语义。
- 音频支持 1–8 声道，在访问固定大小平面数组前拒绝不支持的布局。
- 删除旧 FFmpeg 构建脚本、版本兼容分支和 OpenSSL 构建链路，统一使用 `build.sh` 与 `scripts/build-ffmpeg.py`。

### 依赖与构建

- 固定官方 FFmpeg 9.0.2 归档及 SHA-256，构建 8 个 SDK/架构 slice，生成 18 个分库 XCFramework。
- 设备与模拟器 arm64 独立存放，按 SDK 匹配库和头文件；记录配置、编译器与 SDK 输入以决定重建。
- TLS 改用 Apple SecureTransport。启用 HTTP/HTTPS、HLS、RTMP/RTMPS 和 RTSP 组件；未启用 RTMPE/RTMPTE。
- demo 将 `-all_load` 改为 `-ObjC`，增加显式跨工程 target 依赖。
- `scripts/build-metal.py` 按当前 SDK 编译并内嵌 Metal shader，删除三份历史 shader 二进制数组。
- iPhone demo 包名设为 `com.omnilink.fufucard`，使用 Xcode 配置账号下的 OmniLink Exports Inc.（`Z5TKWGS67N`）签名；凭据不进入仓库。

### 播放修复

- `AVChannelLayout` 深拷贝并释放，保持声道数同步。
- 音视频帧使用 `av_frame_get_buffer()` 分配，正确初始化音频静音，区分实际样本字节和分配对齐填充。
- 使用 `av_hwdevice_ctx_create()` 初始化 VideoToolbox，硬解初始化失败时保留软件解码回退策略。
- EAGAIN 时先取出解码输出再重发原包，明确处理 EOF，排空音频重采样延迟输出。
- 防护缺失时间戳和时间转换溢出，从连续样本推导缺失的音频时间信息。
- 使用 `user_agent`、`rw_timeout`，将 RTSP 超时映射到其协议选项。
- 截图转换期间保持像素缓冲锁定。
- iPhone/tvOS demo 迁移到 UIScene，补齐 storyboard/nib 创建路径中的播放器初始化，并打包缺失的 tvOS 示例媒体。
- 播放中调整倍速立即更新时钟，暂停时改速保持暂停。
- Metal 库或管线创建失败时输出错误，避免提交空管线。

### 验证与文档

- 增加可重复依赖构建、五个 SDK 下 framework/demo Debug/Release 共 20 项构建检查，以及 AddressSanitizer、数据链路、HTTPS、VideoToolbox 回归。
- 增加 Debug 共享自动化，逐项运行音视频、纯视频、纯音频、裁剪、片段时间缩放、拼接和 VR 共 7 个示例。
- iPhone 11 真机、Mac 真机、Apple TV 模拟器各 7 项通过，共 21 次示例运行。检查播放、暂停恢复、0.5/2 倍速、seek、EOF、帧输出与视频截图；拼接项额外跨越片段边界。
- 提供内容对应的中英文 README、升级说明、测试记录与修改日志；升级前审核保留为历史归档。

### 验证边界

播放器接口自动化不代表所有 UI 点击、遥控器焦点、VR 手势/陀螺仪交互或扬声器声学输出均已验收。未测试 Apple TV 真机、最低支持系统、远端直播流、HDR/Main10 渲染及长时性能。tvOS 模拟器使用软件解码。AddressSanitizer 覆盖 SGPlayer 和测试源码，链接的生产 FFmpeg 库未启用 sanitizer 编译。

详见[测试记录](documents/ffmpeg-9.0.2-testing.zh-CN.md)和[升级说明](documents/ffmpeg-9.0.2-migration.md)。
