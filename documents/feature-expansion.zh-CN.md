# 播放器能力扩展与验收

本轮按 SGPlayer 架构独立实现 KSPlayer / GSYVideoPlayer 的适用能力，不复制其实现。以下状态是当前工程状态，不表示竞品宣传的能力已经获得相同性能或设备覆盖。

测试安排：macOS 使用当前 Mac；iPhone / tvOS 先使用模拟器。iPhone 真机验收按用户要求留到 2026-10-26 连接设备后进行，不能用模拟器结果替代。

## 当前新增模块

| 模块 | 行为 | 当前验收 |
| --- | --- | --- |
| SGPlaybackSession | 播放列表、上一条/下一条、续播、独立地址清晰度切换、单条/列表/A–B 循环 | 数据策略回归通过；iPhone/tvOS 模拟器列表交互通过 |
| 内核策略 | 手动 / 优先 Native / 优先 FFmpeg；错误后最多回退一次；保留时间与播放意图 | 数据策略回归通过；iPhone/tvOS 模拟器实际内核切换通过 |
| 诊断 | 首帧、媒体时钟停滞、帧数、回退与状态事件、JSON 导出；原生访问日志的真实码率/字节/下载媒体时长/丢帧/停顿 | 数据策略回归通过；无访问日志时返回空数据，FFmpeg 吞吐/解码丢帧尚未统计 |
| SGNativePlaybackPolicy | 原生码率/最大分辨率/预缓冲/暂停时网络资源策略；参数验证、快照隔离、跨媒体保留 | 参数/隔离/拒绝更新/真实 AVPlayerItem 应用回归通过；实际 HLS 变体切换及弱网测试仍待验收 |
| SGPlaybackCoordinator | 显式激活会话时暂停组内其他播放器；弱引用管理 | 数据策略回归通过 |
| SGMediaCache | 完整 HTTP 文件下载、可选 SHA-256、配额/LRU、播放固定文件、取消、鉴权请求隔离 | 真实 URLSession 回归、媒体扩展名与重启索引通过 |
| SGTimelinePreview | 独立 FFmpeg 定位解码、超时/取消、32 MB 预览缓存 | 独立解码与取消回归通过 |
| SGTimelineSpriteIndex | WebVTT 时间索引、相对地址、xywh 裁切、重叠/越界/内存限制 | 区间边界/相对地址/重叠拒绝回归通过 |
| SGPlaybackControls | 进度、播放/暂停、前后跳、列表、内核、音轨、字幕、清晰度、速度、重试、锁定、PiP、AirPlay 路由入口 | iPhone/tvOS 模拟器和实体 Mac 的完整 UI 回归通过 |
| SGPlaybackPresentation | 同一渲染视图重挂载、应用内小窗/容器全屏、拖动、恢复位置 | iPhone/tvOS 模拟器小窗/全屏/恢复通过，tvOS 遥控器焦点通过 |
| SGPlaybackCover | 等待首帧/失败时显示，出帧后隐藏；关闭/释放恢复无障碍标签 | 生命周期 ASan 与 iPhone 实际失败→出帧专项通过；tvOS 封面视觉专项通过；Mac 专项已通过 |
| 三平台自动隐藏 | 播放空闲超时可配置；iPhone 轻点、Mac 悬停/键盘、tvOS 获得焦点的遥控接收层恢复；暂停/加载/锁定时保持可见 | Mac/iPhone/tvOS 完整 UI 回归通过；宿主设置正数间隔后启用 |
| Mac 键盘 | 视频聚焦后的播放、定位、音量、静音、倍速、锁定与呈现恢复；保留输入控件和系统修饰键 | 实体 Mac 完整 13 项包含键盘/文本焦点和自动隐藏；ASan 生命周期通过，文字键使用 ABC 后恢复原输入源 |
| 双字幕 | 独立 ASS 渲染器、独立偏移、普通文本独立位置；切换内核保留选择 | 双轨显示/独立时间偏移像素回归通过 |
| 3D LUT / Bloom | Native 为 Core Image；FFmpeg 为 lut3d / split / gblur / blend；.cube 严格解析 | 所有切片已重建；双内核恒红立方体像素与 Bloom 回归通过 |

新增 `SGMediaRemuxer`：独立数据包录制/封装转换，支持 Matroska、MP4、MPEG-TS，保留关键帧边界并报告实际范围。三种输出再次完整解码、时间戳、取消与超 EOF 原子保留已通过 ASan 回归。MPEG-4 → MPEG-TS 补充全局头；报告实际关键帧范围。

新增 `SGMediaTranscoder`：独立有限片段转码，支持 Matroska / MP4 / MPEG-TS，默认软件 MPEG-4，显式选择 H.264 / HEVC VideoToolbox；硬件编码不可用时返回错误。视频按配置限制尺寸和帧率，应用显示矩阵方向；首音轨输出双声道 48 kHz AAC，支持增益。字幕、双字幕、弹幕、水印、GIF 与滤镜使用所选内核的效果管线烧录。`SGMediaEffects.snapshot` 隔离可变配置，供后台导出使用；GIF 导出也使用快照。 默认 MPEG-4 输出面向 FFmpeg 播放；Apple 原生播放器不保证接受此编码档次。demo 明确选择 H.264 VideoToolbox，验证双内核实际回放，不隐式回退编码器。 修复非方形像素（SAR）只扩画布而未展开图像导致的黑边，增加尺寸与实际像素断言。

Mac 的 ASan 数据回归已覆盖六种容器/内核组合、实际解码像素、CJK 字幕/弹幕/GIF、延迟音频的 PCM 与同步、裁切、旋转、H.264/HEVC 硬件编码、取消/超时/失败原子保留及快照隔离。导出只支持 SDR/8-bit；显式标记的 PQ/HLG 输入会拒绝，不能冒充 HDR 色调映射。第一音/视频轨为当前选择策略，多声道保留和高级处理仍待实施；音频单独导出见后续章节。

修复片段结束关键帧后的参考 GOP 读取，保留结束前乱序 B 帧；精确裁切回归断言 15 帧的内容、时间戳和结束。新增 `SGDecoderOptions.padAudioToRangeStart`，播放默认仍补齐，离线转码关闭以保留音轨延迟并避免按长间隙分配静音。三平台 demo 新增“视频导出”入口，先导出、再显式播放结果；UI 专项验收结果另行记录。

新增 `SGHLSAssetStore`：macOS/iPhone 后台 HLS 下载、跨启动任务恢复、离线包记录、取消与删除。当前 Mac 上实际下载与新进程离线恢复通过；离线阶段 HTTP 请求为零，原生内核实际出帧。使用现代 AVAssetDownloadConfiguration API，要求 macOS 14+/iOS 18+，其他系统返回不支持；tvOS 的 Apple API 不可用。系统下载包用 NSURL bookmark 保存，保留系统返回的 /.nofollow 路径，不改写系统位置。iPhone 后台下载仍待真机验收。

新增 `SGPlaybackCapabilities` 和按设备能力选择的 AV1 VideoToolbox。未用支持标记替代 AV1 真机播放测试。

新增 Swift 6.4 / SwiftUI 包装和 `scripts/build-package.py`，生成 `build/Package`，提供独立的 SPM 二进制核心、UI 与字体/许可证资源。五 SDK 二进制框架生成、独立链接与包内三项测试通过。包内测试显式驱动 Metal 绘制以验证管线、缓存双内核与字体；解锁后的最终正式应用包默认自动显示通过四项验证：普通 FFmpeg、同视图关闭重开、缓存 FFmpeg、缓存原生内核，无自定义显示时钟。锁屏下的实验不计入验收。iPhone 和 tvOS SwiftUI 包交叉编译通过；包内测试检查自动隐藏配置跨重开保留，正式应用报告记录包、源码和可执行文件摘要。

当前 20 项 Xcode 27.1 Debug/Release 框架/demo 构建全部通过；ASan 数据回归包含八种格式、网络、VideoToolbox、双字幕/滤镜及录制。静态框架链接使用明确归档输入，并生成框架摘要编译输入以弥补 Xcode 27 链接依赖信息的遗漏，保证框架更新后 demo 重链；不同时重复链接框架与归档，避免 iOS `-ObjC` 重复符号。

## 本轮验收证据

| 项目 | 结果与限制 |
| --- | --- |
| iPhone 18 Pro / iOS 27.0 模拟器 | 新增功能后的完整单轮 13 项：12 通过、1 PiP 能力不支持跳过、0 失败；含封面、手势、有声视频导出与无音轨视频后台恢复 |
| Apple TV / tvOS 27.0 模拟器 | 新增功能后的完整单轮 12 项：11 通过、1 PiP 能力不支持跳过、0 失败；含封面、有声视频导出与遥控器浮窗/全屏恢复 |
| 当前实体 Mac | 完整控件回归 13/13 UI 通过，包括实际系统 PiP、封面和双内核转码；旧桌面产物复用导致的 GIF 超时保留为历史诊断 |
| HLS / 当前实体 Mac | 实际下载后 10 帧；全新进程离线恢复 5 帧，离线 HTTP 请求为零 |
| SPM | 五 SDK 包生成；三项包内测试验证输入、字体及实际渲染管线，最终正式应用默认自动显示四项通过 |

Mac 开发者测试模式已按用户明确授权启用。模式关闭时的初始化失败、后来的锁屏激活失败与旧 demo 链接问题均保留为诊断证据，不能计作功能通过。PiP 的能力跳过不能代替支持设备上的启动、后台与恢复验收。精确日志、xcresult 与源码摘要见本轮独立验证记录。

新增 `SGPlaybackGestures`（iPhone）：双击播放/暂停、横向预览并提交定位、右侧播放器音量、左侧屏幕亮度；控制锁阻止手势，有限时间轴边界保护，VoiceOver 开启时保留系统手势。亮度只恢复本实例仍拥有的修改。demo 和 SwiftUI 已接入；实际双击、拖动定位、音量/亮度、锁定专项通过，独立于此前 10 项完整模拟器回归记录。iPhone 真机触感、系统亮度和无障碍仍须实机验收。

## 尚须实施的范围

以下均保留在总范围内，不能将接口、占位按钮或可行性判断标记为完成：

| 范围 | 实施与验收要点 |
| --- | --- |
| 完整控制与交互 | 轨道/字幕样式菜单、无障碍实机验收、横竖屏及更多键盘/焦点边界 |
| 下载与预加载 | 渐进文件断点续传/Range 边下边播、HLS iPhone 真机后台/系统终止恢复、预加载与列表复用；现有完整文件缓存不冒充以上能力 |
| 自适应与直播 | HLS / DASH / Native ABR 策略、FFmpeg 切码率、重连/抖动/追帧、DVR 与低延迟测试 |
| 诊断深度 | 吞吐、真实解码丢帧、硬解状态、资源预算、长时与多实例压力 |
| 字幕扩展 | 系统样式、逐词字幕、在线检索/翻译、离线 AI 字幕/翻译、字幕样式编辑 |
| 输出与处理 | 高级转码/处理、多通道音频、分离音视频地址同步、无缝衔接、反交错、放大与多阶段图 |
| 输入与投屏 | SMB / NFS 凭据与随机访问、DLNA 会话与本地恢复；AirPlay 原始地址能力须与自定义效果输出区分 |
| 平台与分发 | SPM 外部宿主分发集成验证、Catalyst、visionOS |
| 业务模块 | 广告时序、内容/广告时间映射、错误与跳过策略 |
| 色彩和硬件 | HDR / 10-bit / HDR10+ 元数据到显示/特效/导出的全链路；AV1 硬解按能力检查；8K/120 fps 按设备实测 |
| 高级来源与音画 | Blu-ray / ISO / BDMV / DVD 标题与播放列表；BD-J / 菜单 / 加密盘独立审查；Dolby Vision、Atmos、直通与 DRM 的系统接口、授权及硬件约束验证 |

## 集成约定

所有会话策略与 UI 操作在主线程进行。会话拥有控制器的媒体源；通过会话更换媒体，避免直接替换控制器后留下过期的列表状态。调用 `close` 终止会话。异步切换完成回调不得覆盖更新后的媒体与播放意图。

续播按稳定的媒体 ID 存储；演示/测试可注入独立 `NSUserDefaults` 或传 nil。诊断导出只记录数值、序号和受控事件，不输出 URL、查询参数、鉴权头或未经清洗的错误说明。

缓存目录应为应用私有目录。将缓存文件交给播放器之前调用 `pinRequest:`，释放对应媒体后 `unpinRequest:`。请求头参与缓存身份，磁盘仅保存摘要与媒体扩展名，不写入原始 URL/请求头。此模块下载完整单文件；HLS / DASH 清单必须交给分段资源管理器。可选 SHA-256 在发布文件之前校验；失败不替换旧缓存。

缩略图解码在工作队列执行，不使用当前播放解码器。精灵图读取器仅解析索引与裁切数据，图片下载由宿主的鉴权/缓存层负责。ASS 两条字幕均保留作者指定位置；同一区域可能重叠，普通文本可分别调整位置。

## 验证命令

```sh
python3 scripts/build-package.py
swift test --package-path build/Package
python3 scripts/test-swiftui.py  # 要求 Mac 解锁
python3 scripts/test-hls-download.py
python3 scripts/test-cache.py
python3 scripts/test-ffmpeg.py --features --formats --network --hardware --asan
python3 scripts/verify-apple-builds.py --include-demos --jobs 2
python3 scripts/verify-demo-linkage.py
```

本批精确日志、xcresult、平台跳过、测试二进制摘要和当前源码摘要见 [机器可读验收记录](feature-expansion-validation.json)。新代码必须重新执行相关验证；旧版本记录不能视为新改动已通过的证据。

## SPM / SwiftUI 接入

先运行 `python3 scripts/build-package.py`，在宿主工程添加本地包 `build/Package`，使用 `SGPlayerUI` 产品。`SGPlayerModel` 在主线程持有，调用 `open(_:identifier:title:)` 提供稳定媒体 ID，嵌入 `SGPlayerView(model:)`。一个模型只绑定一个活动视图；视图拆除时关闭会话并保存续播。资源包包含 Noto CJK 与依赖许可证。默认 SwiftUI 包装没有宿主全屏/浮窗容器，因此禁用相应按钮；应用可通过原生 `SGPlaybackPresentation` 集成容器。

封面通过 `setCoverImage(_:)` 接收 `CGImage`；三平台均可调用 `setControlsAutoHideInterval(_:)` 设置空闲隐藏秒数，零关闭。Objective-C 使用 `SGPlaybackControls` 的 `setCoverImage:forView:`、`attachGesturesToView:` 和 `autoHideInterval`。封面属于视图呈现层。

`close()` 后可在同一个仍挂载的视图上再次调用 `open`，重新建立会话；旧控件、封面、约束和计时器随之释放。包内测试验证重开后实际出帧且只存在一套控件。

Mac 解锁后，最终 SPM 包的四项前台自动显示复核全部通过，实际帧数为 7 / 6 / 6 / 6，原始 JSON、独立运行历史与 last-passed.json 已保存。历史上一次锁屏重试覆盖过更早的三项原始 JSON；该历史限制保留，不影响本次新保存的四项验收。

原生 ABR 配置是 AVPlayer 的偏好参数，不保证系统必选某个变体。FFmpeg 模式通过会话的独立 rendition URL 切换；原生策略不冒充 FFmpeg 的自动自适应实现。`nativeAccessLog` 只包含系统提供的数值字段，未知/负值不输出，不包含 URI、服务端地址或请求头。

### 视频导出调用

在配置所属队列（通常为主队列）取效果快照，再在工作队列调用同步导出。片段时间为输入媒体时间轴；输出从片段原点计时，并保留音视频相对延迟。任务实例只使用一次。

```objc
SGMediaEffects *effects = [controller.effects snapshot];
SGTranscodeConfiguration *config = [SGTranscodeConfiguration new];
config.videoCodec = SGTranscodeVideoCodecH264VideoToolbox;
config.maximumDimension = 1280;
SGMediaTranscoder *job = [SGMediaTranscoder new];
job.maximumWallTime = 120;
dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    NSError *error = nil;
    BOOL success = [job transcodeURL:sourceURL toURL:destinationURL
                     configuration:config
                             range:CMTimeRangeMake(CMTimeMake(5, 1), CMTimeMake(10, 1))
                           effects:effects error:&error];
    // 在主队列更新 UI；外部取消时调用 [job cancel]。
    NSLog(@"export: %d, %@", success, error);
});
```

同一路径不能同时作为输入和输出。成功后原子替换目标，失败或取消保留已有文件。内嵌字幕需要先由字幕读取器选定轨道并配置到 effects；导出器不会自动猜选全部字幕。

本次模拟器完整回归同时核对两种效果内核的 H.264/AAC 导出报告：每次 30 视频帧、37,024 每声道音频样本，输出文件实际回放通过。完整 UI 所测二进制早于单独的 SAR 修复；该修复已通过实际解码像素 ASan 断言、20 项跨 SDK 构建和最终 SPM 三项测试。SwiftUI 四场景前台验证已通过；Mac 完整控件 UI 13/13 已通过，整个扩展范围尚未完成。

Mac 最终 UI 验收为每用例创建独立临时输出目录，再收集到验收产物目录；同次 GIF 测试仍覆盖旧文件替换。历史桌面 GIF 的元数据/替换等待及未奏效的 POSIX 发布实验已保存，生产发布逻辑保持原实现。

### Mac 键盘接入

通过 `attachKeyboardToView:` 绑定视频区域，传 nil 移除。点击视频取得焦点。空格播放/暂停，左右定位 ±10 秒（Shift 为 ±30），上下调整播放器音量，M 静音/恢复，方括号以 0.25 调整倍速（0.25–4），L 锁定/解锁。F 使用宿主的 `toggleFullScreen`，Escape 只调用 `dismissPresentation` 恢复已有呈现。SwiftUI 自动绑定视频，默认包装仍需要宿主全屏容器。

Command / Control / Option 与输入控件保留系统处理，多播放器按各自焦点限定。文字键自动化临时选择 ABC 并恢复原输入源，不据此宣称全部输入法组合状态已验收。

## 控件验证检查点 — 2026-10-24

七个原始 demo 在实体 Mac、iPhone 模拟器和 tvOS 模拟器分别全部通过。上表完整功能 UI 回归先于后续长拖动和辅助功能进度修复；这些修复的专项验收单独记入验证 JSON。Mac 锁屏导致的前台阻塞不能计作功能通过。

私有临时输出目录的 GIF 回归通过，包含同用例覆盖旧文件。此前覆盖受保护桌面目录中的历史文件曾在系统文件发布阶段等待，确切原因及外部目录验收仍未解决；未修改系统隐私设置。

滑块跟踪和 iPhone 平移手势期间保持控件可见；Mac 定时刷新不会覆盖正在跟踪的滑块位置。iPhone 进度控件处理没有触摸松开事件的数值调整，触摸拖动仍在松开时提交。模拟器滑块自动化核对最终滑块位置与媒体时钟一致，不能代替真机 VoiceOver 验收。

iPhone 模拟器专项两项均通过；另一次六秒按住复验通过，按住中途外部截图显示控制层和拖动滑块仍可见，尚未提前提交定位。Mac ASan 验证高亮跟踪时不隐藏、不被定时刷新覆盖。解锁后，最终 Mac 前台进度两项专项均已通过；最终包 SwiftUI 前台复验另行记录。此前四场景 SwiftUI 通过仅适用于其记录的包摘要。

## 纯音频输出

设置 `SGTranscodeConfiguration.includeVideo = NO`，保留 `includeAudio = YES`，通过同一转码器输出 MP4/M4A、Matroska 或 MPEG-TS 中的双声道 48 kHz AAC。不创建视频编码器或合成器，忽略视频参数；同时关闭两种输出、缺少音轨，或纯音频请求附带视觉效果时，在替换目标前拒绝。沿用有限片段、增益、取消、超时和原子发布约定。这是有损 AAC 提取/再编码，保持现有双声道转换策略。

三个 demo 增加“音频导出”：iPhone 列表入口、Mac 应用菜单和 tvOS Menu 循环的第四种模式；`--sgplayer-audio-export` 可直接打开。导出与播放为两步操作，报告包含 `includeVideo`、零视频帧和音频样本数。实际解码/PCM 断言与双内核 UI 回放分别记录；播放时钟通过不能代替主观扬声器听音验收。

音频导出最终检查点：20 项 Xcode 构建、10 项 demo 链接核对、包内三项测试、实体 Mac SwiftUI 四场景均通过。三平台分别通过音频/视频导出两项专项，每项覆盖双内核导出与结果回放。Mac 进度专项 2/2、iPhone 修订后的实际位置断言专项 1/1 通过。这些是增量专项，未冒充新增功能后重新合并执行的完整套件。总体扩展仍未完成，iPhone 真机验收仍按约定延期。
