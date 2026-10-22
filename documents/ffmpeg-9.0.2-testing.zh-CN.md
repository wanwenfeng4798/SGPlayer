# FFmpeg 9.0.2 测试记录

[English](ffmpeg-9.0.2-testing.en.md) | 简体中文

测试日期：2026-10-22（Asia/Shanghai）。以下为本轮实际结果，机器可读明细见 [验证证据](ffmpeg-9.0.2-validation.json)。

## 环境与构建

FFmpeg 9.0.2；Xcode 27.1（27A9275）。构建 8 个依赖 slice、18 个分库 XCFramework。工程最低系统为 iOS/tvOS 15.0、macOS 12.0，不使用命令行部署目标覆盖。

| SDK | 架构 | Framework Debug/Release | Demo Debug/Release |
|---|---|---|---|
| macosx | arm64、x86_64 | 全通过 | 全通过 |
| iphoneos | arm64 | 全通过 | 全通过 |
| iphonesimulator | arm64、x86_64 | 全通过 | 全通过 |
| appletvos | arm64 | 全通过 | 全通过 |
| appletvsimulator | arm64、x86_64 | 全通过 | 全通过 |

共 20 项构建通过；日志与命令见 `build/verification/xcode-27.1/results.json`。

## 实际运行结果

| 环境 | 系统 | 通过示例 | 视频输出帧 | VideoToolbox 帧 |
|---|---|---|---|---|
| iPhone 11 真机 | iOS 27.0 | 7/7 | 1851 | 1851 |
| 当前 Mac 真机 | macOS 27.0.1 | 7/7 | 1873 | 1873 |
| Apple TV 4K 模拟器 | tvOS 27.0 | 7/7 | 1848 | 0（软件解码） |

帧数是本轮控制流程累计值，受计时影响，不是性能基准或文件总帧数。

每个平台依次运行：

1. `I See Fire`：音视频。
2. `I See Fire, Video Track`：纯视频。
3. `I See Fire, Audio Track`：纯音频。
4. `I See Fire, Range: 30s-40s`：裁剪片段。
5. `I See Fire, Range: 30s-50s, Scale: 0.5`：片段时间缩放。
6. `I See Fire + Google Help`：跨文件拼接。
7. `Google Help VR`：VR 显示模式。

共 21 次示例运行全部通过。每项检查播放时间推进、暂停后保持、恢复、0.5/2 倍速、seek 后恢复及 EOF。视频项检查输出帧与截图；纯音频项不要求视频帧或截图。拼接项额外跨越片段边界。Mac/tvOS 本轮实测速率约为 0.51× 与 1.98×，详细测量值在 JSON 中。

## 数据链路与内存回归

`python3 scripts/test-ffmpeg.py --asan --network --hardware` 通过：

- 自定义声道布局所有权、声道限制、音频静音、YUV 分配/拷贝/回池和时间戳防护。
- 44.1→48 kHz 精确样本数、完整 WAV 解码/格式转换、重复 EOF、重采样尾部排空。
- MPEG-4 B 帧解码、seek/flush；真实 H.264/HEVC 软硬解。
- HTTPS/SecureTransport、自签名证书拒绝和播放器 User-Agent。
- 播放中立即更新倍速时钟，暂停中修改倍速保持暂停。

SGPlayer 与测试源码使用 AddressSanitizer；链接的 FFmpeg 生产库本身未启用 sanitizer。

## 复验与产物

先按[升级说明](ffmpeg-9.0.2-migration.md)构建依赖，再运行：

```sh
python3 scripts/verify-apple-builds.py --include-demos
python3 scripts/test-ffmpeg.py --asan --network --hardware
python3 scripts/test-iphone.py --device <connected-iPhone-UDID>
python3 scripts/test-desktop-tv.py macos
python3 scripts/test-desktop-tv.py tvos --simulator <booted-Apple-TV-UDID>
```

iPhone 需解锁、信任 Mac、开启开发者模式，并配置可用 Xcode 开发签名；tvOS 需安装运行时并启动 Apple TV 模拟器。脚本按独立 run ID 校验结果，拒绝旧报告。

| 产物 | 工作区路径 |
|---|---|
| iPhone 逐项报告 | `build/iPhoneDevice/smoke-result.json` |
| iPhone 开发签名 IPA | `build/iPhoneDevice/com.omnilink.fufucard-development.ipa` |
| iPhone 视频截图 | `build/iPhoneDevice/smoke-frame.png` |
| Mac 逐项报告 | `build/RuntimeMac/runtime-result.json` |
| Mac 逐项截图 | `build/runtime-macos/demo-case-<index>.png` |
| tvOS 逐项报告 | `build/RuntimeTV/runtime-result.json` |
| tvOS 实际显示截图 | `build/RuntimeTV/rendered-screen.png` |
| tvOS 普通启动截图 | `build/RuntimeTV/normal-launch.png` |

`build/` 为本地生成产物，新 checkout 需要重新构建和测试。仓库中的验证 JSON 保存了本轮结果。iPhone 使用 `com.omnilink.fufucard` 和 OmniLink Exports Inc. 团队签名；测试结束恢复普通 demo 界面。tvOS 普通入口也已检查到视频画面。

## 未覆盖范围

这不是所有功能的完整交互验收。未覆盖 UI 点击/导航命中、遥控器焦点、VR 手势/陀螺仪、扬声器声学输出、Apple TV 真机、最低支持系统、远端直播交互/重连、HDR/Main10 色彩渲染和长时性能。协议组件已启用不代表实际远端服务通过测试；SecureTransport 构建未启用 RTMPE/RTMPTE。


当前实现补充：FLV/ASF 时长修复后，多格式严格验收已为 8/8。新增功能具有单独的真机/UI/数据证据，请查阅[当前功能验收](media-features-testing.zh-CN.md)。本迁移记录保留为历史基线。
