![Logo](documents/banner.jpg)

# SGPlayer

[English](README.md) | 简体中文

SGPlayer 是面向 iOS、macOS 和 tvOS 的媒体播放框架。

## 功能

- 360° 全景视频与复杂媒体组合。
- 后台播放、RTMP/RTSP 流媒体和播放倍速设置。
- 多音视频轨道、H.264/H.265 硬件解码。
- 播放状态通知与线程安全。
- 自动检测并选择 FFmpeg/原生内核，保留显式调试接口，共用字幕、弹幕、水印、GIF 贴纸、画中画合成。
- FFmpeg libavfilter / 原生 Core Image 滤镜、ASS 样式、截图与独立 GIF 片段导出。
- 有限片段视频/效果导出与纯音频双声道 AAC 导出，支持 MP4/M4A、Matroska、MPEG-TS。

以上为框架功能清单，实际验证范围见下方测试记录。

macOS 画中画使用框架内的 AppKit 原生浮动面板，移动同一个视频与控制容器；iOS 使用系统 AVKit。能力快照提供 `pictureInPictureBackend` 和 `systemPictureInPicture`，区分两种实现。`scripts/test-pip-layout.py --logic-only` 验证双内核窗口生命周期；可见像素验收需在解锁桌面后省略该参数重跑。

## 依赖与要求

- FFmpeg 9.0.2、Metal、AudioToolbox。
- Xcode 27.1、Metal Toolchain、对应平台 SDK、Python 3、PATH 中的 `pkg-config`。
- 字幕依赖固定为 libass 0.17.5、FreeType 2.14.3、HarfBuzz 14.4.0、FriBidi 1.0.16；Meson/Ninja 安装在本地构建虚拟环境。
- 最低 iOS 15.0、tvOS 15.0、macOS 12.0；最低系统版本尚未完成实机验收。

`.xcode-version` 固定工具链版本。HTTPS/RTMPS 使用 Apple SecureTransport，无需 OpenSSL。

## 构建

```sh
git clone https://github.com/wanwenfeng4798/SGPlayer.git
cd SGPlayer

./build.sh iOS build
./build.sh tvOS build
./build.sh macOS build
# 一次构建全部平台
./build.sh all build --jobs 4
```

依赖使用官方 FFmpeg 9.0.2 归档并校验固定 SHA-256。离线归档通过 `FFMPEG_ARCHIVE=/absolute/path/ffmpeg-9.0.2.tar.xz` 指定，仍校验同一摘要。`./build.sh <平台> clean` 清理生成产物。

| 平台 | 设备/桌面架构 | 模拟器架构 |
|---|---|---|
| iOS | arm64 | arm64、x86_64 |
| tvOS | arm64 | arm64、x86_64 |
| macOS | arm64、x86_64 | 无 |

源码及构建输入在 `build/ffmpeg/9.0.2/`。静态库与对应头文件在 `build/libs/<平台>/universal/` 和 `build/libs/<平台>/simulator/`，XCFramework 在 `build/xcframeworks/<平台>/`。Xcode 按 SDK 选择变体，设备与模拟器的 arm64 不进行合并。

## 使用与迁移

打开 `demo/demo.xcworkspace` 查看示例。静态库使用方采用 `-ObjC`，需链接：

- `SGPlayer.framework`
- `AVFoundation.framework`、`AudioToolbox.framework`、`VideoToolbox.framework`
- `Security.framework`、`CoreFoundation.framework`、`libz.tbd`

迁移删除 `SGDecoderOptions.refcountedFrames`，调用方须移除赋值；不提供旧版本兼容别名。音频支持 1–8 声道。帧的 `size` 表示解码后 buffer 内存，packet 的 `size` 仍表示压缩字节数。旧构建入口、OpenSSL 构建链路和历史 Metal shader 数组已移除，shader 按当前 SDK 编译。

## 自动验证

```sh
# 五个 SDK 的 framework/demo Debug、Release 构建，共 20 项
python3 scripts/verify-apple-builds.py --include-demos
# 数据、内存、HTTPS、H.264/HEVC 软硬解回归
python3 scripts/test-ffmpeg.py --asan --network --hardware
# iPhone 真机：需连接、解锁并开启开发者模式
python3 scripts/test-iphone.py --device <UDID>
# 当前 Mac 真机
python3 scripts/test-desktop-tv.py macos
# 已启动的 Apple TV 模拟器，需先安装 tvOS 运行时
python3 scripts/test-desktop-tv.py tvos --simulator <UDID>
```

iPhone 包名为 `com.omnilink.fufucard`，签名团队为 OmniLink Exports Inc.（`Z5TKWGS67N`）；使用 Xcode 已登录账号及本机开发证书。iPhone 脚本产物包含 `build/iPhoneDevice/` 下的开发签名 IPA、JSON 和截图。

Debug 自动化逐项运行 7 个示例，检查播放、暂停恢复、0.5/2 倍速、seek、EOF、视频帧与截图，拼接项额外跨越媒体边界。Release 不包含自动化入口。测试结束后 iPhone 恢复普通界面，内置测试播放器在其他平台继续播放首项。

2026-10-22 的结果：iPhone 11 真机 7/7、Mac 真机 7/7、tvOS 模拟器 7/7，20 项构建全部通过。测试直接调用播放器接口，未覆盖全部 UI 点击、遥控器焦点、VR 手势/陀螺仪、扬声器声学输出、远端直播、HDR 和长时性能。tvOS 模拟器使用软件解码。

## 文档

- 升级说明：[中文](documents/ffmpeg-9.0.2-migration.md) / [English](documents/ffmpeg-9.0.2-migration.en.md)
- 验证记录：[中文](documents/ffmpeg-9.0.2-testing.zh-CN.md) / [English](documents/ffmpeg-9.0.2-testing.en.md)
- 修改日志：[中文](CHANGELOG.zh-CN.md) / [English](CHANGELOG.md)
- 历史功能可行性评估：[中文](documents/media-features-assessment.zh-CN.md) / [English](documents/media-features-assessment.en.md)
- 多格式测试（播放器验收 8/8，FLV/ASF 时长问题已修复）：[中文](documents/ffmpeg-formats-testing.zh-CN.md) / [English](documents/ffmpeg-formats-testing.en.md)
- [机器可读验证证据](documents/ffmpeg-9.0.2-validation.json)
- 升级前审核归档：[中文](documents/ffmpeg-upgrade-audit.md) / [English](documents/ffmpeg-upgrade-audit.en.md)。仅记录旧基线，不代表当前实现状态。

## 流程图

![Flow Chart](documents/flow-chart.jpg)

## 原作者

[Single](https://github.com/libobjc) · libobjc@gmail.com

原作者的其他项目：[KTVHTTPCache](https://github.com/ChangbaDevs/KTVHTTPCache)、[KTVVideoProcess](https://github.com/ChangbaDevs/KTVVideoProcess)。

## 播放效果与第三方依赖

- 使用与内核路由：[中文](documents/media-features.zh-CN.md) / [English](documents/media-features.en.md)。
- 能力扩展实施与验收台账：[中文](documents/feature-expansion.zh-CN.md) / [English](documents/feature-expansion.en.md)。
- 当前功能验收：[中文](documents/media-features-testing.zh-CN.md) / [English](documents/media-features-testing.en.md)。
- [第三方许可证](licenses/README.md)。Portions of this software are copyright © The FreeType Project (www.freetype.org). All rights reserved.
