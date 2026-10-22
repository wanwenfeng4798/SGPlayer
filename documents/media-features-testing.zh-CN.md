# 播放功能验收

[English](media-features-testing.en.md) | 简体中文

日期：2026-10-22；Xcode 27.1、FFmpeg 9.0.2。[实现与限制](media-features.zh-CN.md)。已完成运行的[机器证据](media-features-validation.json)已归档。

## 最终结果

| 验证项 | 结果 |
|---|---|
| 编译 | 20/20 通过 |
| iPhone 11 真机 UI | 8/8 通过，包含双内核后台 PiP 与实际画面方向 |
| Mac 真机 UI | 8 个场景完成：全量首轮 7 项通过，1 项辅助功能快照中断失败；未修改源码，独立重试该项通过 |
| tvOS 模拟器 UI | 7 项通过；系统不支持 PiP，1 项明确跳过 |
| 原有 demo | 每平台 7/7，合计 21/21 |
| FFmpeg 扩展格式 | 8/8，包括 FLV/ASF 时长与 EOF |
| 字幕截图 | 三平台×双内核，共 6 组完整中文短语识别通过；已知缺字截图被拒绝 |
| 数据/内存检查 | SGPlayer 启用 ASan 的回归、字幕/滤镜/GIF、HTTPS、H.264/HEVC 软解与 VideoToolbox 均通过 |

Mac 首轮完整 UI 的原始 xcresult 仍保留失败结果，仅单独重试了被中断的控制场景；机器清单保留两次尝试及逐项结果。没有把当前源码快照描述为 Mac 一次连续全绿的 8 项运行。tvOS 跳过项不计实际 PiP 通过。

## 测试环境

- 物理 Mac，arm64，macOS 27.0.1（26A434）。
- 物理 iPhone 11，iOS 27.0，UDID 尾号 `E9B802E`；包名 `com.omnilink.fufucard`，团队 OmniLink Exports Inc.（`Z5TKWGS67N`）。使用已配置的 Xcode 账号，仓库不存凭据。
- Apple TV 4K 第三代 tvOS 27.0 模拟器；本轮没有 Apple TV 真机验收。

## 覆盖与断言

| 套件 | 内容 |
|---|---|
| 编译矩阵 | 框架与 demo、Debug/Release、macOS / iPhone 真机 / iPhone 模拟器 / tvOS 真机 / tvOS 模拟器，共 20 项构建；依赖覆盖八个架构切片。 |
| 原有 demo | 七个输入全部测试：普通音视频、纯视频、纯音频、时间区间、缩放区间、跨片段拼接、全景视频。断言播放、稳定暂停、恢复、0.5×/2× 倍速、seek、视频截图与 EOF。 |
| 格式 UI | 十个来源：两个原 MP4，以及 FFV1/H.264 MKV、HuffYUV AVI、FLV1 FLV、MPEG-2 TS、WMV2 ASF、MPEG-4 NUT、动态 GIF，要求实际出帧且无播放错误。 |
| 控制 | 播放/暂停、时间推进/稳定、跳转、倍速和 FFmpeg/原生切换。 |
| 效果/导出 | 双内核测试字幕、弹幕、水印、滤镜预设、GIF 贴纸、截图和 GIF 导出；暂停时修改效果。截图保留于 xcresult 附件。 |
| 方向/字体输出 | 使用红上蓝下的合成 MP4，断言双内核实际显示像素；中文字幕截图核对完整短语“同步字幕”，并用已知缺字截图作反例。 |
| 生命周期/错误 | 带效果 VR、停止/恢复、无效媒体报错与恢复、快速开关、过期容量通知确定性回归。 |
| PiP | 双内核检查实际激活、前后台转换、时间推进、iPhone 后台提交帧数、恢复应用与停止；Mac 切到 Finder 后返回。不支持的 tvOS 分支明确验证并跳过实际启动。 |
| ASan/数据 | 滤镜像素/参数校验、RGB 曲线、SRT/VTT 同步、ASS 样式/位置/颜色、内嵌多轨元数据/字体所有权、真实 DVD 位图字幕、弹幕 seek 确定性、水印透明度、GIF 延时/预算/取消/EOF/原子保留、时钟、缓冲、声道、重采样、HTTPS、H.264/HEVC 软解/VideoToolbox。 |

八个 UI 测试方法包含大量操作；八项通过不等于只点击八次，也不代表数学意义的 100% 覆盖。状态/出帧断言辅以数据像素测试及导出截图人工查看，不能仅凭截图断言所有字形、所有组合均正确。`scripts/check-caption-capture.swift` 使用 Vision OCR 核对完整字幕短语，避免把“字幕”按钮当作成功；`scripts/make-orientation-fixture.swift` 可重新生成方向素材。

tvOS 模拟器明确返回 `isPictureInPictureSupported == NO`，已验证拒绝分支，但**实际 tvOS PiP 未验收**。此前 iPhone 锁定时未执行的运行不计通过，以后来解锁后的结果包作为证据。

## 复现

```sh
./build.sh all build --jobs 4
python3 scripts/verify-apple-builds.py --include-demos --jobs 2
python3 scripts/test-ffmpeg.py --asan --network --hardware --formats --features
python3 scripts/test-desktop-tv.py macos
python3 scripts/test-iphone.py --device 00008030-000E744C2E9B802E
python3 scripts/test-desktop-tv.py tvos --simulator 5A30B4A8-189B-4C3E-B32D-F237FBB7A02F

xcodebuild -workspace demo/demo.xcworkspace -scheme features-ui-macos \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build/FeatureUIMac CODE_SIGN_IDENTITY=- test
xcodebuild -workspace demo/demo.xcworkspace -scheme features-ui-ios \
  -destination 'id=00008030-000E744C2E9B802E' -derivedDataPath build/FeatureUIPhone \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration test
xcodebuild -workspace demo/demo.xcworkspace -scheme features-ui-tvos \
  -destination 'platform=tvOS Simulator,id=5A30B4A8-189B-4C3E-B32D-F237FBB7A02F' \
  -derivedDataPath build/FeatureUITV CODE_SIGNING_ALLOWED=NO test
```

设备/模拟器标识需匹配测试主机；iPhone 保持解锁、连接与信任，UI 自动化使用主机已有测试/辅助功能权限。同一应用的 smoke 与 UI 套件不能同时运行，否则安装/启动会相互中断。

## 证据与边界

Xcode 结果位于 `build/FeatureUI{Mac,Phone,TV}/Logs/Test/*.xcresult`；smoke JSON/图片位于 `build/RuntimeMac`、`build/runtime-macos`、`build/iPhoneDevice`、`build/RuntimeTV`；数据结果位于 `build/tests-asan/{formats,features}`。最终清单记录路径、结果及源码校验值。首次 FLV/ASF 失败、字体资源未进入应用包、Metal/CI 上下翻转及 Mac EOF 停滞保留为发现，不悄悄计为通过。

本轮覆盖指定主机/设备/运行时的已列 demo 和代表性功能路径，不代表穷尽所有组合、最低支持系统、tvOS 真机 PiP、4K/HDR/DRM、任意 PGS/DVB、所有字体/GIF 方言、直播字幕、长时间功耗/内存稳定性及所有系统 PiP 控件交互。原生格式能力由 AVFoundation 决定。未用声学设备测量物理扬声器出声；音频检查证明的是解码/输出时钟路径。ASan 仅覆盖 SGPlayer/测试源码，不覆盖生产依赖二进制。
