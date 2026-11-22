# 验收记录 · 2026-11-19

最新全量审计为 [FeatureAudit-2026-11-22.md](FeatureAudit-2026-11-22.md)：83 点中完整覆盖 77、部分 6；实现完整性与正式内容、版权、用户及配对真机验收分开统计。最新三端结果及环境清理见 [补开发交付与分端验收](PlatformAcceptance-2026-11-22.md)。本文按日期保留历史结果，开头旧测试数量和旧状态不代表最新版本。

## 当前结论

已创建原生开发工程，在 iOS 模拟器完成过主要交互验收，Watch 模拟器已安装、启动并检查趋势时间范围入口。按用户要求停止后续模拟器回归，2026-11-19 将最新完整开发版安装并启动在用户的 iPhone 17 上。真机安装和启动成功不代表健康、后台音频、配对 Watch、医疗有效性或商店发布验收全部通过。

环境：Xcode 26.6，Swift 6.3.3，iOS 26.5 模拟器（iPhone 17 Pro），watchOS 26.5 SDK 与运行环境 23T570（Apple Watch Series 11 46mm）。机器为 Intel。

## 已实际执行

| 检查 | 结果与证据 |
|---|---|
| 共享规则测试 | 15 项通过；玻璃按钮／自动播放调整后的记录为 `artifacts/test-core-glass-automatic-playback.log` |
| iOS 原生服务与界面测试 | 4 项服务测试、8 项界面测试通过；`artifacts/Followup-Acceptance.xcresult`、`test-followup.log`；后续键盘修改单独通过日记保存／删除测试，尚未再次完整回归 |
| iOS Debug 编译与运行 | PhonePreview 工程构建、安装、运行成功；最终验收不需手动固定架构 |
| iOS Release 设备编译 | 成功，未签名、未安装真机、未上传；`artifacts/build-release.log` |
| Watch 应用与表盘组件源码 | arm64_32 与 arm64 均通过 SDK 类型检查；`artifacts/check-watch-sources.log` |
| 主工程完整构建 | Release 未签名构建成功，包含 Watch App 与 Widget 资源；`artifacts/build-full-release.log`；此构建早于最新时间范围界面修复 |
| Watch 模拟器构建与安装 | 时间范围修复后构建成功并覆盖安装；`artifacts/build-watch-range-fix.log`；实际打开 HRV 详情及全屏时间范围列表，`artifacts/watch-range-before.png`、`watch-range-options.png` |
| 工程与配置 | Xcode 可解析五个目标，包含服务测试；工程生成结果可复现，工程／Info.plist／entitlements／隐私清单语法检查通过 |
| 最新完整真机 Debug 构建 | 成功，包含 iPhone、Watch 和表盘组件；`artifacts/build-iphone17-final.log`；`codesign --verify --deep --strict` 在可读取系统信任链的环境中通过 |
| iPhone 17 安装与启动 | `cn.geckoai.qingkong` 真机覆盖安装成功并前台启动，PID 880；`artifacts/iphone17-install-final.json`、`iphone17-launch-final.json`。未使用健康演示或测试启动参数 |
| 素材 | 共享 Assets 的图片引用有效；五款表情 PNG 与样稿原件校验一致；三段 WAV 均为 16 秒 PCM；图标无 Alpha 通道 |
| 既有样稿 | 28 个受保护文件完整性检查通过，未改动浏览器样稿 |

共享规则覆盖日均加权方式、排除当天与过期数据、至少三个有效日、缺失日期断线、时区／夏令时边界、未来／无效样本、当天最新压力、手动恢复、删除合并、无效输入、停止截止时间、传输编解码及旧回执不能确认较新删除。

原生界面测试覆盖：

1. 四个导航入口和无健康记录状态。
2. 心情和日记保存，重启保留，删除后再次重启仍为空。
3. 开启联动、记录 4/5 压力后切换林间，手动选择星夜后关闭联动。
4. 手动选择主题，真实 AVAudioPlayer 播放状态、切到下一首、暂停。
5. 显式开启健康演示时展示演示标记并保存首页截图。
6. 四页的动态字号、文字裁切、语义标签检查，以及最大辅助字号下的心情保存和播放交互。
7. 停止定时选中态跟随真实截止时间，切换页面与音轨后保留。服务测试还实际播放并等待一分钟截止，确认暂停和清除定时。

Watch 时间范围修复：默认滚轮在 ScrollView 中被压缩为窄条，已改为 `.navigationLink` 原生选择器，入口至少 48 pt。模拟器实际点开入口后显示全屏三行选项，周选项有原生勾选。随后自动化输入工具返回 `noWindowsAvailable`，未完成日／月逐项点选回归，不能将该交互视为全部验证通过。iPhone 的时间范围控件未改动。

## 保留的问题与未执行项

- 旧日记测试出现的 `Invalid frame dimension (negative or non-finite).` 警告定位到键盘工具栏。将完成按钮改为原生导航栏入口后，单项日记保存／删除测试通过且报告未记录该警告；`artifacts/Contrast-Light-Keyboard.xcresult`。仍需完整回归和真机复核。
- 主题说明文字和数值单位已提高对比度，并提供深色主题色；完整对比度审计未通过。最新 `artifacts/Contrast-Light-Visible.xcresult` 因审计时元素消失而失败，实际深色系统模式尚未验证。
- 未验证真实 HealthKit 权限组合、心电图／波形、配对同步、后台传送回执、双端删除与断连恢复。
- 未验证真机长时间锁屏播放、蓝牙路由／中断、系统表盘刷新／隐私遮罩／链接及 `.watchface` 系统导入。模拟器的一分钟停止定时通过不替代真机后台验收。
- 未实际执行照片权限保存、人工 VoiceOver、降低透明度、减少动态效果、最低系统运行、性能或耗电验收。
- 音频仍为开发样本。经用户明确授权，已使用公司 Team `9S743LF4C7` 配置开发签名并安装 iPhone 17。标识按用户确认改为 `cn.geckoai.qingkong`、`cn.geckoai.qingkong.watchapp`、`cn.geckoai.qingkong.watchapp.widgets`；App Group 为 `group.cn.geckoai.qingkong.shared`。Xcode 之前创建的 `local.qingkong` 系列及中间的 `cn.geckoai.qingkong.widgets` 标识未删除，当前工程不再使用。正式素材、支持与隐私页面、TestFlight、提审与发布尚未完成。

## iPhone 播放器反馈修正（2026-11-19）

- 上一首、下一首改为 56 pt 标签区域和 title2 图标的圆形玻璃按钮，不再仅在按钮外增加占位。
- 助眠页原自定义音量条绑定应用增益，无法反映系统音量；替换为原生 `MPVolumeView`，由系统处理输出音量的显示和调整，不访问内部子视图。Watch 现有应用音量控制没有修改。
- 迷你播放条移除内部展开按钮的玻璃样式，整个内容显式 `.buttonStyle(.plain)`，保留系统底部附件或旧系统 `.bar` 的单层背景。
- 停止定时下方改为“将在 HH:mm:ss 停止播放”；`TimelineView` 每秒按实际截止时间计算剩余时长，不改变既有停止逻辑。
- 完整真机 Debug 构建成功：`artifacts/build-iphone17-player-controls.log`；共享规则 15 项通过：`artifacts/test-core-player-controls.log`；已覆盖安装并启动 iPhone 17：`artifacts/iphone17-install-player-controls.json`、`iphone17-launch-player-controls.json`。
- 本轮没有使用模拟器；未自动操作手机音量键、控制中心及播放器界面，系统音量联动、按钮触达、玻璃外观与每秒倒计时的实际效果仍需真机交互确认。SDK 对关闭旧路由按钮的 `showsRouteButton` API 发出弃用警告，未使用私有 API。

后续按真机反馈继续调整：切歌按钮标签缩为 44 pt、图标 20 pt，中间播放按钮仍为 64 pt；使用 `MPVolumeView.volumeSliderRect(forBounds:)` 公开覆写点将滑杆在 44 pt 容器中垂直居中，与两侧图标中心对齐；底部四个入口统一为单色线性 SF Symbols，显式禁用自动填充变体。最终完整构建成功（`artifacts/build-iphone17-player-tabs.log`）、共享规则 15 项通过（`artifacts/test-core-player-tabs.log`），已覆盖安装 iPhone 17（`artifacts/iphone17-install-player-tabs.json`）；自动启动因手机锁屏被拒绝（`iphone17-launch-player-tabs.json`），需解锁后手动打开。本轮仍未取得自动化真机界面截图或音量键操作证据，实际视觉与系统音量交互待用户在手机查看。

## Watch 真机安装排障（2026-11-19）

- 已重新读取实际设备状态：Apple Watch Series 11，watchOS 27.2.1，开发者模式 enabled；Xcode 26.6（17F113）仍将其列为未知架构的不可用目标。设备连接后实际加载 watchOS DDI 仍报 CoreDeviceError 12040／0xe8000076，`ddiServicesAvailable` 为 false。证据：`artifacts/watch-details-recheck.json`、`watch-destinations-recheck.log`、`watch-apps-registered.log`，并在 Xcode Devices 界面看到同一错误。该问题不能归因于用户尚未开启开发者模式。
- 按用户既有授权，在公司 Team `9S743LF4C7` 的 Apple Developer 页面完成这块手表的设备登记；创建并下载 `Qingkong Watch Development` 与 `Qingkong Widgets Development` 两份开发描述文件。仅选择这块手表和本机已有开发证书，未创建证书、未上传发布、未删除旧配置。
- Xcode 自动签名的通用设备构建成功，但实际检查两份嵌入描述文件仍不包含手表。因此在独立输出目录 `build/WatchDeviceRecovery/Qingkong.app` 采用新描述文件，从组件到 Watch 再到 iPhone 重新签名；原构建目录及工程自动签名配置保持不变。两份新描述文件均包含目标手表，证书与既有签名一致，HealthKit／App Group 与原授权相符；`codesign --verify --deep --strict` 通过。证据：`artifacts/watch-new-profiles-check.json`、`watch-recovery-sign.log`。
- 上述完整配套安装包已成功覆盖安装到 iPhone 17（`artifacts/iphone17-install-watch-recovery.json`）。用户随后在 iPhone 的「Watch → 我的手表 → 可用 App → 晴空 → 安装」操作后，明确回复“已安装到手表”；手表配套安装结果已由用户确认。
- 本机 iPhone 镜像首次打开处于欢迎设置页，未继续启用手机访问或通知转发；未通过镜像操作手机。安装成功不代表 Xcode 的 DDI 错误已解决；手表直接调试、应用运行、后台音频与表盘仍未通过真机验收。

## 玻璃按钮与自动设备选择

iPhone 按钮统一使用系统玻璃样式，旧系统使用原生兼容样式。Watch 不再提供手动播放位置入口；iPhone 可达且状态回执成功时使用 iPhone，否则使用手表，断连不自动开播。停止定时保留原截止时间。相关源码已包含在上述完整真机构建中。

真机反馈右上角设置按钮出现双重玻璃后，定位到应用级 `.glass` 被顶部工具栏继承。设置及四处顶部完成按钮已显式恢复 `.automatic`，保留工具栏自身的系统背景。完整真机构建成功（`artifacts/build-iphone17-toolbar-glass.log`），共享规则 15 项通过（`test-core-toolbar-glass.log`），已覆盖安装并启动 iPhone 17（`iphone17-install-toolbar-glass.json`、`iphone17-launch-toolbar-glass.json`）。本次未运行模拟器，也未取得真机修复后的界面截图，外观最终效果待手机侧确认。

心情日记增加输入区外点按取消 `FocusState`：用输入区在页面中的实际范围排除内部编辑点按，同时识别页面点按，保留其他控件手势。完整真机构建成功（`artifacts/build-iphone17-note-focus.log`），共享规则 15 项通过（`test-core-note-focus.log`）；已覆盖安装并启动 iPhone 17（`iphone17-install-note-focus.json`、`iphone17-launch-note-focus.json`）。尚未自动操作真机键盘，实际取消焦点及输入区内编辑仍待交互确认。

共享逻辑测试 15 项通过：`artifacts/test-core-iphone17.log`。新增的音轨／音量／原定时准备、过期定时不重启及无连接不能确认遥控的服务测试，在中止前的模拟器日志中通过；该次完整回归被用户要求转真机而中止，不能记作全部服务与界面测试通过。玻璃外观、Watch 真机自动选择、远端回执及断连后点击播放仍需实际交互验收。

## Watch 音乐页精简（2026-11-19）

- 页面只保留封面、音轨名称和上一首／播放暂停／下一首三个操作；移除设备说明、音量、停止定时、曲目列表和底部说明。播放设备仍按原规则自动选择，操作失败时显示原生弹窗。
- 共享规则 15 项通过（`artifacts/test-core-watch-simple-player.log`）；包含 iPhone、Watch 和组件的完整真机 Debug 构建成功（`artifacts/build-watch-simple-player.log`）。本轮未使用模拟器。
- 在独立输出 `build/WatchSimplePlayer/Qingkong.app` 替换包含已登记手表的两份描述文件，逐层重新签名，`codesign --verify --deep --strict` 通过；描述文件检查记录为 `artifacts/watch-simple-player-profiles-check.json`。
- 完整配套包已覆盖安装到 iPhone 17（`artifacts/iphone17-install-watch-simple-player.json`）。本轮尚未取得手表新版页面的实际运行或更新确认；既有 DDI 问题未解决，不能将手机配套包安装成功视为手表新版已安装。

## Watch 手机优先播放修复（2026-11-19）

- 用户反馈 iPhone 在附近仍从手表播放。源码确认旧路径在缓存 `reachable == false` 时跳过手机请求，直接选择本地；连接激活和首次可达状态存在等待窗口，旧路径没有等待机制。此项是已确认的代码缺陷，具体真机连接失败原因尚无设备日志证据。
- 播放前新增最长 8 秒的手机确认窗口。等待连接激活并尝试无播放副作用的状态请求，每次失败后在截止前重试；只有收到有效回执才选择手机，整个窗口未确认才允许手表开播。不再以缓存可达状态作为跳过确认窗口的条件。
- 确认等待期间禁用重复操作；后台刷新不随可达状态变化而反复取消任务。手机原本已经播放时，页面上基于旧状态点击“播放”不会将其反向暂停。手表当前播放仍保持，暂停后再次播放会重新确认手机；实际远端播放命令未获回执时保留错误提示，不盲目在另一端重复开播。
- 新增 5 项共享确认逻辑测试，覆盖首次不可用后恢复、立即确认、超时回退、迟到回执及取消等待；共享规则共 20 项通过（`artifacts/test-core-phone-priority.log`）。未运行模拟器或配对真机自动化测试。
- 完整真机 Debug 构建通过（`artifacts/build-watch-phone-priority.log`）。将所有目标构建号由 1 递增为 2，并同步工程生成器，检查生成结果仅有构建号变化；最终构建亦通过（`artifacts/build-watch-phone-priority-v2.log`）。
- 在独立输出 `build/WatchPhonePriority/Qingkong.app` 使用包含手表设备的既有描述文件重新签名；三个嵌套包构建号均为 2，`codesign --verify --deep --strict` 通过（`artifacts/watch-phone-priority-sign.log`、`watch-phone-priority-profiles-check.json`）。
- 完整配套包已覆盖安装并启动 iPhone 17（`artifacts/iphone17-install-watch-phone-priority.json`、`iphone17-launch-watch-phone-priority.json`）。手表是否完成新版更新、手机附近／远离／锁屏／首次连接的真实联动仍待手表侧验证；不将手机安装成功视为此项真机体验已通过。

## Watch 音量与压力选择（2026-11-19）

- 用户反馈音乐页无法调节音量，确认此前精简页面移除了音量入口，也没有接入表冠控制。已在封面旁加入 44×44 pt 的原生 `WKInterfaceVolumeControl`；按实际播放设备选择手表 `.local` 或手机 `.companion`，系统负责音量，不使用自定义应用增益 Slider。通过 `focus()` 接收表冠输入，播放设备切换时重建控件，后台／操作忙碌／错误提示时释放焦点。
- 用户明确指出“保存此刻”上方的 1/5 难懂、难选；原实现为 ScrollView 中的默认压力 Picker。已改为“此刻的压力”和五档文字，原生 `.navigationLink` 入口至少 52 pt，进入全屏选择；内部 1～5 数据及保存逻辑不变。
- 共享规则 20 项通过（`artifacts/test-core-watch-volume-stress.log`）；完整真机 Debug 构建成功（`artifacts/build-watch-volume-stress.log`）。工程生成器和全部目标构建号递增为 3，重新生成后仅构建号变化。
- 独立输出 `build/WatchVolumeStress/Qingkong.app` 采用既有手表描述文件重新签名；三层包构建号检查和 `codesign --verify --deep --strict` 均通过（`artifacts/watch-volume-stress-sign.log`、`watch-volume-stress-profiles-check.json`）。完整包已覆盖安装 iPhone 17（`artifacts/iphone17-install-watch-volume-stress.json`）。
- 本轮未使用模拟器。手表新版是否完成同步、原生音量控件的实际布局与表冠焦点、两端系统音量变化，以及压力全屏选项的实际点选仍待配对真机确认；不能将编译通过或手机安装成功记作这些交互验收通过。

## 复现最终 iOS 验收

先生成 PhonePreview 工程，再运行以下命令（模拟器 ID 需替换为本机设备；本次 ID 为记录中的 iPhone 17 Pro）：

```sh
python3 scripts/generate_project.py --phone-only
xcodebuild -project QingkongPhonePreview.xcodeproj -scheme Qingkong \
  -destination 'platform=iOS Simulator,id=84379BC4-5C87-4C9D-A607-EC31D02D4E7A' \
  -derivedDataPath build/PhoneDerivedData CODE_SIGNING_ALLOWED=NO \
  -parallel-testing-enabled NO test
```

测试使用独立数据库，不读取真实健康样本。若修改测试后模拟器复用了旧测试运行器，可仅卸载当前 Bundle ID 对应的 `cn.geckoai.qingkong.uitests.xctrunner` 再测试；不要卸载或清空用户应用来解决测试缓存问题。用户要求转为 iPhone 17 后，停止了仍在进行的玻璃按钮／自动播放模拟器回归，该次不能记作完整通过。

`artifacts/ios-today.png` 为当前原生首页截图，带显式健康演示标记；这不是读取真实健康数据的证明。构建日志、截图和测试结果仅保留本地，不纳入源码版本控制。

## HRV 明显变化的放松提醒（2026-11-19）

- 按用户最终要求，应用内默认开启且可关闭；首次前台打开请求系统通知授权，拒绝后提供系统设置入口。不开启专注状态读取或额外过滤条件，使用普通 `.active` 本地通知，声音和展示遵循系统专注及通知配置。
- 同一 HealthKit 来源此前七个日历日至少三个有效日，按日均值计算个人基线；最近一小时连续两条自动 HRV 读数均低于基线至少 30%，间隔至少十分钟，且最新读数不超过十五分钟时才考虑提醒。阈值是产品启发式，未作临床心理压力验证。手动输入的健康记录仍在原趋势中显示，但不用于自动提醒。
- 每个本地日最多两次、间隔至少四小时；开关、启用时间、去重时间、通知提交账本和当天暂停状态独立保存在本机。关闭后不自动重新开启，不积压旧提醒。演示／UI 测试不会发健康通知。通知内容不包含具体健康值或日记。
- iPhone 通知点击进入放松建议，支持进入助眠页及「今天不再提醒」，不自动播放；由系统决定手机／手表镜像，不在 Watch 再独立发送一条。手表镜像通知的真实展示与操作尚待真机确认。
- HealthKit 成功刷新会等待提醒评估完成；并发刷新共用一个任务，所有观察回调都等待后再 completion。HRV 请求 immediate 后台交付，失败时提供提示，不承诺系统实时唤醒。
- 共享逻辑共 34 项通过（原有 20 项及新增提醒规则 14 项），日志：`artifacts/test-core-relaxation-reminders.log`。覆盖默认／关闭持久化、大幅／轻微变化、单条／短间隔／恢复、来源隔离、手动样本、旧格式兼容、重复 UUID、新鲜度、启用边界、当天暂停、跨日／时区、冷却与每日上限。
- iPhone、Watch、组件完整真机 Debug 构建成功：`artifacts/build-relaxation-reminders.log`。构建号统一为 4；工程生成器已同步。沿用既有公司签名及包含手表的描述文件，最终产物 `build/RelaxationRemindersFinal/Qingkong.app` 逐层重新签名且严格验证通过，证据：`artifacts/relaxation-reminders-sign.log`、`relaxation-reminders-profiles-check.json`。
- 最终完整包已成功覆盖安装到 iPhone 17：`artifacts/iphone17-install-relaxation-reminders.json`。自动启动因手机锁屏而失败：`artifacts/iphone17-launch-relaxation-reminders.json`；需解锁后手动打开并选择系统通知授权。未代替用户批准通知。
- 本轮未使用模拟器。尚未实测真实后台健康更新触发、系统授权弹窗、通知点击／静音／专注及 Watch 镜像，也未确认手表新版同步完成；不把测试、构建或手机安装成功视为这些体验已通过。

## 上传校验缺少健康用途说明（2026-11-19）

- 用户提供的上传日志报 90683：iPhone 和 Watch 两个 App 均缺少 `NSHealthUpdateUsageDescription`。检查实际源配置确认仅有 `NSHealthShareUsageDescription`；健康授权代码仍为 `toShare: []`，不申请健康写入权限。
- 在 `Config/iOS-Info.plist` 和 `Config/Watch-Info.plist` 补齐缺失用途说明，明确当前版本只读、不写入或修改 Apple 健康。未改动健康读写代码、权限或既有本地 Xcode 名称／分类设置。工程已引用这些源 plist，无需修改目标配置或重新生成工程。
- 完整 Release Archive 成功：`artifacts/archive-health-privacy-fix.log`；新归档为 `build/HealthPrivacyFix/Qingkong.xcarchive`。实际读取归档内 iPhone 与 Watch 的 Info.plist，确认两个包均有非空读取与写入用途说明；整包严格签名验证通过，检查记录 `artifacts/archive-health-privacy-fix-check.json`。
- 本轮仅改用途配置并检查实际归档，未重新运行业务逻辑测试，未使用模拟器，也未上传应用或声称 App Store 校验已通过。用户需选择新归档重新上传；旧归档不会随源配置修改更新。截图中的 SDK 要求为自 2027 年 4 月起生效的警告，未作为本次缺键错误处理。

## Watch 临时音量行与 iPhone 图表拖动（2026-11-19）

- Watch 音乐页默认只显示封面、曲名和三个播放按钮；旋转表冠唤出原生系统音量控件，在同一个固定高度区域隐藏播放按钮。约三秒没有音量变化或触摸后恢复播放按钮；手指持续按住时保持音量显示。后台、忙碌或错误提示期间释放焦点。
- 三个按钮采用 plain 样式，不绘制背景，标签保留整格矩形触摸区域和至少 44 pt 高度。手表独立／遥控 iPhone 的选择、回执和播放行为沿用原实现；音量仍由 `WKInterfaceVolumeControl` 的 local／companion 控制系统输出。手机通过即时消息仅转发音量变化活动，帮助遥控期间延长音量显示，不传送或持久化音量值。
- iPhone 共享健康图表加入拖动选择：今日 HRV 迷你图、趋势页三项指标的日／周／月图，以及表盘设置中的预览均显示横纵参考线、选中点、时间、数值及对应单位。按全部时间段查找，包括空缺段，空缺显示「暂无记录」且没有伪造的数值或选中点；切换指标／数据后清除旧选择。
- 心电图保留横向浏览；按住约 0.2 秒后拖动显示秒数及 mV 读数和对应参考线，松手清除选择，并提供手势文字说明。Watch 与真实组件不加入 iPhone 的图表拖动手势。
- 共享逻辑 34 项通过：`artifacts/test-core-watch-volume-chart-selection.log`；最终 iPhone、Watch、表盘组件完整 Debug 构建通过：`artifacts/build-watch-volume-chart-selection.log`。本轮未使用模拟器；未修改现有 Xcode 名称、分类、Scheme 等用户本地设置，未重新生成工程。
- 完整包 `build/WatchVolumeChartSelection/Qingkong.app` 沿用已授权证书及包含手表的描述文件，逐层签名并严格验证通过：`artifacts/watch-volume-chart-selection-sign.log`、`watch-volume-chart-selection-profiles-check.json`。已覆盖安装至 iPhone 17：`artifacts/iphone17-install-watch-volume-chart-selection.json`；手机安装结果不代表手表新版已同步。
- 真机视觉、拖动与页面滚动的协调、表冠焦点切换、两端系统音量变化、连续调节和超时恢复均尚未实际操作验收，不能用构建或安装结果代替。没有上传 App Store，也未验证新上传包。

## 健康提醒、首次连接与模拟器复核（2026-11-19）

- 按用户后续要求，首页 HRV 迷你图移除拖动选择，手指从图表区域纵向滑动会滚动页面。趋势页三指标及 iPhone 表盘预览保留选择；Watch／真实组件不增加选择手势。
- 已复现旧 HRV 规则的密集采样漏提醒：连续偏低超过十分钟，但最新两条相隔不足十分钟时旧代码返回 nil。红色回归证据 `artifacts/test-hrv-cluster-red.log`；修复为连续偏低窗口内存在跨度十分钟的记录，恢复值打断窗口。不能据此断定用户当天漏通知的实际原因，未读取其真实样本或运行日志。
- 新增默认开启、独立开关和阈值的高／低静息心率及低血氧提醒；只处理同源自动新记录，排除运动、未知静息状态、单次血氧低值、重复、未来及过期数据。每类独立限频和当天暂停；详见 RelaxationReminders.md。系统通知设置与最近判断原因可在「通知检查与测试」查看，提供中性测试通知。
- 核心逻辑最终 46 项测试通过：`artifacts/test-core-health-notifications-final.log`。新增覆盖密集 HRV、恢复打断、三类指标、静息元数据、单次／短间隔、来源和手动输入、过期／启用边界、阈值及非法值、独立开关／静音／限频、跨日、旧模型解码及配置持久化。
- 完整 iPhone＋Watch＋组件 Debug 构建成功：`artifacts/build-health-notifications-final.log`。未重新生成或覆盖主工程用户的名称、分类、Scheme 配置；只生成用于模拟器的临时工程。
- iPhone 17／iOS 26.5 模拟器：首次引导「稍后」后重启不重复、个性化仍能连接、三类提醒设置与检查入口、首页 HRV 区域纵向滚动测试通过。日志 `artifacts/test-simulator-health-notifications.log` 中前三项通过，第四项因测试控件定位失败；修正定位后的三指标拖动测试通过，日志 `artifacts/test-simulator-chart-selection.log`、`test-simulator-chart-selection-capture.log`。实际拖动截图 `artifacts/iphone-chart-drag-2.png` 显示日期、ms 数值、选中点及横纵虚线；松手清除选择。
- Watch Series 11 46mm／watchOS 26.5 模拟器：实际打开音乐页，默认封面、名称和三个无背景按钮；左右按钮触摸框至少 44 pt；表冠旋转时显示原生音量并隐藏按钮，随后恢复。最终 UI 测试通过：`artifacts/test-watch-simulator-volume-capture.log`，默认截图见 `artifacts/watch-volume-ui-attachments/`，表冠过程截图 `artifacts/watch-volume-crown-1.png`。首次断言因 XCTest 等待界面静止后音量已按三秒规则隐藏而失败，之后用操作过程截图验证临时状态，未为测试延长产品超时。
- 普通模拟器启动首次说明可打开系统健康授权页。初始未签名测试包因缺少 HealthKit entitlement 无法授权；切换本地签名模拟器构建后系统授权弹窗正常。选择不开放健康数据并完成流程后，首页显示「暂时没有可读取的健康记录」，随后才请求系统通知，未推断用户拒绝状态。首次引导／测试所用健康标记独立于正式存储。
- 用户已关闭两端开发者模式，遵照后续要求仅做模拟器运行。本轮早期手机启动失败的记录 `artifacts/iphone17-launch-watch-volume-chart-selection.log` 明确为 Developer Mode disabled，不能把覆盖安装当作运行通过。
- 真实 HealthKit 后台唤醒、新数据触发通知、Watch 镜像、真实系统音量／音频路由、心电图真数据拖动及锁屏／专注行为仍需配对真机验收。模拟器界面、逻辑测试和构建结果不代替这些验证；未上传 App Store。

- 普通签名模拟器版本中，点击「发送测试通知」后，XCTest 在 SpringBoard 查询到测试通知，测试通过：`artifacts/test-simulator-notification-delivery.log`、`test-simulator-notification-delivery-capture.log`。附加截图为通知检查页（`artifacts/notification-delivery-ui-attachments/`）；连续截图未取得横幅画面，因此只认定系统中可查询到通知，不声称横幅视觉验收通过，也不代表真实健康异常已触发或真机后台已通过。

## 图表滚动、心电图纯浏览与 Watch 表冠（2026-11-20）

- 按用户最终澄清，只有心电图取消选值交互；趋势页心率、HRV、血氧均保留横向选值。首页 HRV 迷你图沿用此前要求，不接收选择手势。支持选值的健康图表在识别前拒绝纵向拖动，让页面正常上下滚动，横向拖动才显示读数。
- 心电图已复现透明选取层遮挡原生横向浏览的问题。按用户进一步确认，最终移除心电图选值层、读数浮层、选中点和参考线，保留系统原生横向滚动；显式时间轴覆盖整条波形，下面显示当前可见秒数与总秒数。发现 `LinePlot` 原生滚动后的波形已移动，但绑定的滚动值未更新；范围标签改从实际可见绘图区计算，读取层明确禁用触摸，不再影响浏览手势。
- 全采样测试暴露逐点 Chart 内容重算的卡顿，波形改用 `LinePlot` 批量绘图，保留全部原始点和线性连接，不抽样或平滑健康数据。中间尝试过将浏览与选值合并的时间窗方案，已按用户取消选值的要求移除。
- Watch 音乐页常驻原生音量控件并在页面可见、前台且操作可用时取得表冠焦点，移除先接收表冠再交接焦点的路径。默认播放按钮覆盖音量控件，音量变化时显示音量；超时恢复按钮仍保留表冠焦点。离开页面、进入后台或操作不可用时释放焦点。
- ECG 独立测试入口位于 `Tests/InteractionFixtures/`，使用明确标注的 30 秒、512 Hz 合成波形，直接调用正式 `ECGWaveformChart`。不会初始化健康服务或向健康库写入演示记录，正式 App 不包含此入口。使用 `python3 scripts/generate_project.py --ecg-interaction` 仅生成忽略提交的 `QingkongECGPreview.xcodeproj`，不会覆盖主工程或既有 PhonePreview 工程。

复现心电图交互测试（模拟器 ID 按本机设备替换）：

```sh
python3 scripts/generate_project.py --ecg-interaction
xcodebuild -project QingkongECGPreview.xcodeproj -scheme Qingkong \
  -destination 'platform=iOS Simulator,id=608D8E95-8DD9-402A-BE47-D4F40EAEC557' \
  -derivedDataPath build/ECGPreviewDerivedData -parallel-testing-enabled NO \
  -only-testing:QingkongUITests/ECGScrollingUITests test
```

- 最终心电图模拟器测试通过：`artifacts/test-ecg-native-viewport-label.log`，覆盖从开头到 25–30 秒末尾、向回浏览、横拖不滚页面、纵拖滚页面及无选值浮层。实际截图见 `artifacts/ecg-browse-final-attachments/`，测试使用完整 512 Hz 合成波形。较早的失败中，波形已经移动而范围标签未更新，不能据此认定波形没有滚动；上述最终测试已覆盖标签修复。
- 最新三项 iPhone UI 测试通过：`artifacts/test-three-metrics-final.log`。分别覆盖首页 HRV 区域滚页、趋势页图表区域纵向滚页、心率／HRV／血氧横向选值并松手清除。已实际查看 `artifacts/chart-final-{hrv,heart,oxygen}-1.png`，均可看到对应日期、数值和单位、选中点与参考线。
- 最终 Watch UI 测试通过（1 项、0 失败）：`artifacts/test-watch-final-focus.log`。覆盖默认播放按钮、至少 44 pt 触摸区域、不先点击音量图标直接双向旋转表冠、切曲、离页再进入后旋转表冠。模拟器操作和页面状态不证明真实输出音量变化。
- 共享逻辑 46 项测试通过：`artifacts/test-core-ecg-scroll.log`。最终完整 iPhone＋Watch＋表盘组件 Debug 构建通过：`artifacts/build-final-chart-and-crown.log`。电脑重启前被中断的执行不作为通过证据；恢复后串行构建与模拟器验收，一次只运行一台本轮模拟器。
- 本轮未安装或运行真机。真实心电图数据、手表输出音量及音频路由仍未验收；保留用户已关闭开发者模式的状态，未上传 App Store。

## 心电图横向浏览性能（2026-11-20）

- 原实现把连续滚动位置保存在整张波形视图的 `@State` 中，底部时间范围的变化会使包含全部采样点的图表重新计算。改为独立的可观察范围状态，仅由文字子视图读取；按显示精度更新至 0.1 秒，不再由文字刷新触发整张波形视图更新。波形仍使用全部原始采样点、线性连接与原生滚动，无抽样、平滑或选值浮层。
- 新增 `testWaveformScrollingPerformance`，使用相同 iPhone 17／iOS 26.5 模拟器、Debug 配置和 30 秒／512 Hz 合成波形，每轮执行相同的左右拖动，采集三轮 CPU 与系统滚动指标。优化前日志 `artifacts/test-ecg-scroll-performance-before.log`，优化后日志 `artifacts/test-ecg-scroll-performance-after.log`。
- 每轮平均 CPU 用时由 10.450 秒降为 1.546 秒（约减少 85%）；平均 CPU 指令数由 41,192,191.829 kI 降为 2,929,035.686 kI（约减少 93%）。这是本机模拟器同一操作的测量，不是帧率或真机性能保证；系统滚动区间用时也不当作丢帧指标。
- 优化后两项 UI 测试均通过：性能采集，以及完整波形前后浏览、到达 25–30 秒末尾、横拖不移动页面、纵拖正常滚页、无选值浮层。没有修改心率／HRV／血氧图表。未操作真机或改变开发者模式。
- 完整 iPhone＋Watch＋表盘组件 Debug 构建通过：`artifacts/build-ecg-scroll-performance.log`；共享逻辑 46 项测试通过：`artifacts/test-core-ecg-scroll-performance.log`。使用独立临时工程进行模拟器测试，未覆盖主工程配置或其他本地改动。

## 表盘组件发现与添加（2026-11-20）

- 用户确认手表 App 可打开，但未提供当前表盘名称或实际安装包版本。本轮仅操作专用 Series 11 46mm／watchOS 26.5 模拟器 `F6D2A7BF-6563-4DA1-BCF9-4BF62FF45823`，未安装或运行真机，也未变更开发者模式。
- 全新 Watch Debug 模拟器构建成功，扩展包含 `Metadata.appintents`，系统能读取 `MetricIntent`、默认配置及圆形／矩形支持信息。证据：`artifacts/build-complication-discovery-before.log`、`watch-complication-registration-before.log`。此前另一 Debug 产物缺少元数据，但 Release 归档包含元数据，不能据此认定为用户真机找不到组件的原因。
- 初始无签名模拟器包可以出现在列表，但配置预览为空、时间线加载失败；系统日志显示配置服务因权限不足拒绝连接。使用本地签名重新构建、覆盖安装并打开 App 刷新后，配置选项及时间线正常加载。签名构建：`artifacts/build-complication-discovery-signed.log`；前后日志：`watch-appintents-system-errors.log`、`watch-complication-registration-signed.log`。这是模拟器测试包的验证条件，未增加产品权限或修改签名配置。
- 实际界面验证：「健身记录数字」→ 编辑 → 左上圆形复杂功能 → 所有 App → 小晴空，可选择「跟随 iPhone 配置」「HRV」「心率」等推荐项；选择 HRV 后返回真实系统表盘，显示空数据占位，系统无障碍描述为「1个复杂功能，HRV」，点击进入 App 的 HRV 详情。签名版本圆形时间线日志明确为 `reload: succeeded with 1 entries`。
- 实际界面验证：智能叠放 → 编辑 → 添加 → 小晴空，可配置指标与迷你趋势；添加后矩形卡片显示 HRV、`— ms` 及连接健康提示，点击进入 HRV 详情。模拟器未使用演示健康值。尚未实际完成系统表盘上大矩形槽位的添加，不以智能叠放验证替代该项。
- 补充 iPhone 添加引导，明确「所有 App」入口、圆形／大矩形位置及可用于排查的「健身记录数字」表盘；解释图库中没有独立小晴空表盘。组件功能代码未改变。用户真机未复测，安装版本、表盘位置是否兼容及实际找不到的原因仍未确认。
- 引导修改后的 iPhone 模拟器构建通过：`artifacts/build-complication-guide.log`（`QingkongPhonePreview`、Debug、通用 iOS 模拟器目标）；本轮未更改健康与同步逻辑，未重复运行业务逻辑测试，也未操作其他任务的模拟器。

## TestFlight 表盘复核与 HRV 通知（2026-11-20）

- 用户进一步确认 TestFlight 版本为 0.1.0（8）、手表系统为 watchOS 27。本机仅有 watchOS 26.5 模拟器，不声称已复现或验证 watchOS 27。读取本地 2026-11-20 11.22 的 8 号归档：Watch App 内含 WidgetKit 扩展、正确的标识前缀、App Group 和完整 `Metadata.appintents/extract.actionsdata`；三层严格签名验证通过。上传前归档不等同于 Apple 处理后实际安装的包，缺元数据或签名失败均未被证实为用户问题的根因。
- Release Watch 模拟器构建通过：`artifacts/build-complication-release-simulator.log`。安装后现有圆形组件可显示并点击进入 HRV 详情；此前已验证的添加列表见上一节。新增在 Watch 激活时刷新组件推荐列表，并提供「连接与设置 → 刷新表盘组件」恢复入口；这只请求系统刷新，不保证能解决用户 TestFlight 安装后的列表缺失。未上传新版本，也未改变真机开发者模式。
- 回归测试复现旧 HRV 规则排除单条明显下降及延迟约四十分钟送达的记录：`artifacts/test-hrv-sparse-red.log`。改为最新一条自动读数低于同来源七日个人基线至少 30%、最新不超过一小时即可进入提醒判断，仍需至少三个有效基线日，保留启用时间、去重、每天两次及四小时间隔。高低心率和低血氧的重复确认规则未改变。
- 共享逻辑最终 49 项测试通过：`artifacts/test-core-hrv-background-final.log`，包括单条下降、延迟送达、一小时边界、重新启用、来源隔离、基线、去重和限频。没有读取用户当天实际健康样本，因此不能把旧规则认作其从未收到通知的唯一原因。
- 后台投递注册与观察查询创建分开，启动／激活时可重试注册失败；记录最近健康更新回调及错误。通知检查原因、最近后台判断和最近成功提交时间本地保存，避免前台刷新掩盖此前后台判断；权限未允许或提交失败时明确记为未发送。没有健康值或日记内容进入诊断存储。
- 完整 iPhone＋Watch＋表盘组件 Debug 模拟器构建成功：`artifacts/build-hrv-background-final.log`。iPhone 模拟器服务测试已验证：用独立存储完成空数据检查，重新创建提醒服务后恢复检查时间与原因，不发送健康通知、不写入健康库。
- iPhone 17／iOS 26.5 模拟器两项相关测试分别通过：服务保存／恢复见 `artifacts/test-hrv-background-diagnostics-simulator.log` 中的单元测试结果；通知设置及后台检查页面见 `artifacts/test-hrv-background-diagnostics-ui-final.log`（1 项、0 失败）。初次 UI 断言未滚动到最后一条状态，补足滚动后通过；实际查看最终截图 `artifacts/hrv-diagnostics-final-attachments/`，三条空状态、检查说明和后台说明均正常显示。初次日志整体含一次 UI 失败，不能当作整轮测试成功。
- 真实 HealthKit 后台唤醒、锁屏数据交付、变化触发系统通知及 Watch 镜像尚未真机验证；本轮只验证规则、存储、构建和模拟器页面。Watch 新增刷新按钮仅完成构建验证，watchOS 27／TestFlight 缺失组件仍待实际安装包复测。当前安装的 8 号包不会自动获得本轮源码修改，需要制作并安装包含修改的新 TestFlight 构建；本轮未上传。

## 水母表盘单行复杂功能（2026-11-20）

- 用户明确复现为 TestFlight 0.1.0（8）在「动态 → 水母」表盘的「所有 App」列表中找不到小晴空。专用 Series 11 46mm／watchOS 26.5 模拟器复现：顶部、底部使用单行文字组件，旧扩展只声明圆形和矩形，未支持 `accessoryInline`。Apple 官方《Migrating ClockKit complications to WidgetKit》将 `utilitarianSmallFlat`／`utilitarianLarge` 对应到 `accessoryInline`，本机系统日志也实际使用该 family 渲染这些位置。
- 新增 `accessoryInline` 支持及独立 `Label` 布局，只显示指标图标、数值和单位；窄的顶部位置不再因重复指标名截断单位。圆形、矩形布局与趋势行为保持原实现，采样时间等完整信息保留在无障碍描述中。无数据使用「—」，不填入演示值。iPhone 添加引导同步说明单行位置与日期位置的区别。
- 已实际在模拟器的「动态 → 水母」编辑器中，经「所有 App → 小晴空」为顶部选 HRV、底部选心率，并确认保存后的真实系统表盘同时显示两个组件。点按顶部进入 HRV 详情，点按底部进入心率详情。最终表盘截图：`artifacts/watch-motion-inline-final.png`；组件时间线与渲染证据：`artifacts/watch-motion-inline-after.log`，含 `accessoryInline`、`reload: succeeded with 1 entries`、`util-large-narrow family` 的成功快照。旧版缺失列表复现截图：`artifacts/watch-motion-inline-before.png`。
- 中间明确标为「正中（日期）」的位置已实际检查：只有系统日期的两种样式与关闭选项，不提供「所有 App」。这是该表盘的系统限制，补充单行组件不能让健康组件占用日期位置。
- 最终 Watch＋组件本地签名 Debug 模拟器构建通过：`artifacts/build-motion-inline-watch-final.log`；iPhone 添加说明构建通过：`artifacts/build-motion-inline-phone-guide.log`。本轮未重新生成或覆盖主工程配置，未操作真机或其他任务的模拟器。
- 共享逻辑回归 49 项测试通过：`artifacts/test-core-motion-inline.log`；差异空白检查通过。本轮没有更改健康、提醒或同步逻辑。
- 本机没有 watchOS 27 模拟器；上述证据来自 watchOS 26.5，不代表用户 watchOS 27／TestFlight 实际安装已复测。当前 8 号包不会自动获得源码修改，需要新构建后更新 Watch App；本轮未上传 TestFlight。

## 原生团子与两端组件（2026-11-20）

- Watch 新增五种原生分层团子，亮屏活跃播放约三秒后停止，点按可重播；减少动态效果、低亮度、离页与后台停止动作。页面保留系统右上角时间，放大团子，下方显示 HRV／心率／血氧。模拟器已查看页面和点按效果，截图为 `artifacts/watch-dumpling-native.png`；未用真机验证抬腕、常亮或耗电。
- Watch 新增圆形、矩形静态团子组件，点按进入 App 动画页；iPhone 新增小号、中号主屏幕及锁屏组件。共享摘要只增加最近有效心情档位与记录时间，不包含日记或压力评分。新增、同步、删除记录时刷新摘要，无健康数据不填零、不写入演示数据。
- 共享逻辑 53 项测试通过，包含旧摘要兼容、心情删除、未来记录、隐私字段及动画截止，日志 `artifacts/test-dumpling-core.log`；服务测试验证本地、配对端及删除触发刷新、重复同步不重复通知，日志 `artifacts/test-dumpling-services.log`。Watch 与完整 iPhone／Watch／两组件 Debug 构建通过，日志 `artifacts/build-dumpling-watch.log`、`artifacts/build-dumpling-phone.log`。
- iPhone 模拟器图库能找到并渲染团子预览，但添加组件时系统桌面 SpringBoard 崩溃；仅含一行文字的诊断组件及 Apple 自带组件同样复现。崩溃记录的共同栈为 `-[SBHRippleSimulation clear]` 与 `createRippleAtGridCoordinate:strength:`。减少动态效果未解决，已恢复原设置；最小诊断入口已恢复正式组件并重新构建成功。未将这些结果计为组件添加通过。
- 新建 `Qingkong Widget Check` 模拟器保留原设备数据，启动后用户要求停止测试，因此未进行新设备添加对照。2026-11-20 用户反馈自行发送到 TestFlight 测试后没有问题；对应构建号、逐项覆盖范围未提供。此为用户实测反馈，不代表开发侧真机验收。本轮未上传 TestFlight、未操作真机或修改开发者模式。
- 工程生成器支持 `--update-existing` 增量更新，保留现有版本、签名和 scheme。新增 iPhone 组件扩展、共享资源与 App Group。锁屏组件添加、Watch 新团子复杂功能添加与真机唤醒动作未由开发侧逐项验证。

## 前台心情同步刷新（2026-11-20）

- 代码确认团子页面用 `app.today`（最近激活时刻）筛选心情，之后在手机新建并同步的记录会因晚于该时刻被排除，重新激活页面才显示。改为随记录变化按当前时间计算最近心情，不依赖退出后台更新页面时钟。
- 原记录仅走系统后台队列；新增两端可连接时的即时消息通道，与后台队列共用持久化、合并及删除规则。只在本地保存完成后回执，按记录 ID 与更新时间核对确认；即时发送失败保留后台队列补传。正在传送的同一修订不重复发送，延迟的队列完成回调不会覆盖已确认的同步状态。音频遥控协议保持原实现。
- 增加三项服务回归用例，覆盖前台观察更新与保存后回执、删除后迟到旧消息不复活记录、未知版本拒绝确认。按用户要求不再运行模拟器界面验收；这些新增服务用例仅完成编译，未执行，不把它们记录为测试通过。完整 iPhone／Watch／两端组件及测试包编译通过，构建日志为 `artifacts/build-mood-live-sync.log`。Mac 本地共享逻辑回归 53 项通过，日志 `artifacts/test-core-mood-live-sync.log`。
- 尚未使用配对真机确认即时传输时延。需重新编译并同时更新 iPhone 与 Watch App；旧版本不支持新增的即时心情消息。系统复杂功能仍由 WidgetKit 调度刷新，不能把 App 页面即时更新承诺为表盘固定秒级刷新。

## iPhone 播放状态同步到 Watch（2026-11-21）

- 代码确认旧实现仅在手表发送遥控命令后返回状态；iPhone 直接播放、暂停、切歌或定时结束没有主动同步，Watch 页面依赖十秒查询，尚未进入遥控状态时也不显示收到的手机状态。
- 播放器状态变化时，通过当前可连接的 WatchConnectivity 会话主动推送完整状态；会话激活及重新连接时发送最新状态。即时状态不加入后台持久队列，避免恢复连接后重放旧的播放／暂停状态。原遥控命令仍等待操作回执，音量系统控件保持原实现。
- 播放回执新增可选更新时间，与主动推送使用同一合并入口，防止迟到旧回执覆盖新状态；可解码没有该字段的旧包。Watch 页面收到状态即更新曲目和播放按钮，连接恢复时主动查询；本地正在播放或激活时保持本地音频，接收手机状态不启动手表音频。
- Mac 本地回归先复现旧消息缺少更新时间：`artifacts/test-audio-state-sync-red.log`；修复后共享逻辑 55 项通过：`artifacts/test-audio-state-sync-core.log`，新增覆盖新消息时间戳及旧协议兼容。
- 完整 iPhone／Watch／两端组件及测试包编译通过：`artifacts/build-audio-state-sync.log`。新增三项服务用例覆盖主动状态消息更新、迟到回执不回退、曲目／定时／音量变化通知，仅完成编译，未运行。遵循用户此前要求未做模拟器界面测试，未使用配对真机验证实际传输时延、锁屏遥控或独立音频路由；需同时更新 iPhone 与 Watch App 后复测。

## 个性化设置与团子页面比例（2026-11-21）

- 将原本混在团子预览下的指标、趋势选项移至独立的「健康指标组件」分区，明确默认指标只影响「跟随 iPhone 配置」的健康组件；趋势仅用于同时启用自身趋势选项的矩形健康组件。保留既有偏好与同步行为，团子页面继续同时显示三项健康数值。
- iPhone 手表预览屏幕改为固定 184 × 224 pt，团子保持正方形等比显示，调整内边距与底部读数布局。按用户补充要求保留预览心情文字，并在真实 Watch 团子页面增加相同心情文字；团子分别上移 6／8 pt，为文字留出间距，Watch 布局为新增文字预留高度。
- Mac 共享逻辑 55 项测试通过：`artifacts/test-core-watch-preview.log`。最终完整 iPhone／Watch／两端组件 Debug 编译通过：`artifacts/build-watch-preview.log`。差异空白检查通过。遵循用户此前要求，未启动模拟器做界面验收，未操作真机或上传 TestFlight；比例及文字视觉效果仍需安装新版本后确认。

## Watch 健康卡片留白与趋势分页（2026-11-21）

- 首页 HRV、心率、血氧卡片增加内容水平与垂直内边距，迷你折线图再增加四周留白，减少线条贴近卡片边缘的情况。未改变图表数据或缺失值处理。
- 三项健康详情共用原生 `TabView` 横向分页，顺序为日、周、月，默认周；移除原来需要点开二级页面的时间范围选择器。各页独立纵向滚动，保留最近采样、来源、图表、HRV 基线、空值说明与刷新，并为图表增加留白。
- Mac 共享逻辑 55 项测试通过：`artifacts/test-core-watch-trend-pages.log`；完整 iPhone／Watch／两端组件 Debug 编译通过：`artifacts/build-watch-trend-pages.log`；差异空白检查通过。
- 按用户本轮允许打开模拟器确认的要求，在 Series 11 46mm／watchOS 26.5 模拟器安装并打开新版，使用 `--demo-health` 明确标注的开发演示数据，实际查看首页 HRV 卡片留白、HRV 周趋势及纵向滚动。模拟器保留在详情页供用户确认；本轮未取得横向拖动切换页面的可靠交互证据，未认定三项详情的手势逐项验收通过。未运行真机或上传 TestFlight。

## Watch 仅图表切换时间范围（2026-11-21）

- 按用户进一步要求，将最近数值、采样时间、来源、HRV 基线及说明、刷新按钮移出横向分页。详情页只保留一层纵向滚动，固定高度的分页区域仅包含日／周／月标签与对应折线图；上方信息不随横向切换滑走，默认仍为周趋势。
- Mac 共享逻辑 55 项测试通过：`artifacts/test-core-watch-chart-only.log`；完整 iPhone／Watch／两端组件 Debug 编译通过：`artifacts/build-watch-chart-only.log`。差异空白检查通过。
- 已更新正在使用的 Series 11 46mm／watchOS 26.5 模拟器，打开 HRV 详情并查看顶部最近数值、时间、来源及下方周趋势布局，沿用明确标注的开发演示数据。未取得横向滑动过程中顶部稳定性的自动化验收证据，手势体验留待用户确认；未操作真机或上传 TestFlight。

## iPhone 正方形组件三列居中（2026-11-21）

- 正方形心情团子组件底部由「指标名／数值与单位」两行改为「指标名／数值／单位」三行，HRV、心率、血氧三列等宽居中、顶部对齐；数值独占一行并适当放大，保留单行缩放及无数据占位。中号组件与 Watch 组件布局不变。
- Mac 共享逻辑 55 项测试通过：`artifacts/test-core-square-widget-columns.log`；完整 iPhone／Watch／两端组件 Debug 编译通过：`artifacts/build-square-widget-columns.log`。差异空白检查通过。
- 遵循用户本轮要求，不添加、操作或调试模拟器小组件。仅启动 iPhone 17／iOS 26.5 模拟器并更新安装包，显示效果由用户手动确认；未进行组件显示验收，未操作真机或上传 TestFlight。


## Watch 健康变化检测与通知归属（2026-11-21）

- 原实现仅 iPhone 判断提醒，且等待完整趋势及 ECG 查询。现增加 Watch 主要检测端；手表完成健康连接、通知授权和带安装标识的持久交接后，手机停止独立判断，避免双端各发一次。交接前保留原手机逻辑。
- 健康观察回调走独立小窗口查询，HRV 保留七日基线，心率／血氧保留三十分钟确认窗口；通知规则、静息保护及过期时限保持。指标读取失败独立处理，不用旧缓存判异常。前台全量刷新也先评估提醒，再查询 ECG。
- Watch 对每次决策先探测 iPhone，连接确认后固定委托手机；不可达／超时才固定在手表本地通知。手机锁屏时的镜像由系统处理。手机明确拒绝过期配置／权限不被当成离线；旧回复不会结束下一次探测。委托手机后不因丢回执在 Watch 重发，延迟超过时限不补发。
- 提醒配置与既有偏好共同放在应用上下文，不覆盖心情／音频通道；决策走即时消息加持久队列，入箱去重。配置更新保留手表的处理时间和预留次数，避免一次手表检测与一次手机提交被重复计数。手机通知检查与手表连接设置新增检测状态及最近检查。
- Mac 共享逻辑 **66 项测试通过**（新增 11 项）：`artifacts/test-core-watch-monitoring.log`。覆盖手机尚无健康样本的转交判断、旧配置／开关／暂停、跨端冷却与日限、过期与未来时间、重复处理、静息规则、稀疏 HRV、重启、配置更新保留进度与避免双计数、发送归属不可反复切换，以及消息不包含具体健康值。
- iPhone 17／iOS 26.5 模拟器 **4 项服务回归通过**：`artifacts/test-services-watch-monitoring.log`（交接持久化并停止手机独立评估、设置变更拒绝旧结果、原诊断保留、提醒上下文与偏好兼容）。测试未制造或发出健康异常通知，未添加、操作或调试小组件。
- 完整 iPhone／Watch／两端组件 Debug 编译通过；最终服务测试构建包含 Watch 及共享模块的最新修改，架构为 x86_64 模拟器。工程采用现有生成器增量加入 Watch 服务引用，保留本机签名和版本设置；未签名安装真机，未归档或上传 TestFlight。
- **未验收**：Series 11／watchOS 27 的真实后台投递与耗时、手机解锁／锁屏镜像、断连本地通知、用户实际样本能否满足规则、Watch 系统通知授权与重启恢复。模拟器不能证明以上行为。Apple 当前 HealthKit 文档仍对 watchOS 大多数类型施加小时级后台频率上限，不能承诺迁移后实时或一定更快。
- 两端升级后需各打开一次；手表完成健康连接并允许通知，手机「通知检查 → 检测设备」显示 Apple Watch 后才算交接完成。之后离线仍由 Watch 检测，手机不根据临时可达状态抢回检测权。

## Watch 组件系统自适应背景（2026-11-21）

- 健康指标组件与心情团子组件原先在 Watch 分支固定使用黑色容器背景。改用 WidgetKit 的 `AccessoryWidgetBackground` 绘制系统自适应背景，并将容器底色设为透明，避免黑色遮挡系统背景效果；单行组件由系统决定背景显示。iPhone 团子组件的场景底色及两端数据、布局保持不变。
- 实现依据为 Apple 官方 `AccessoryWidgetBackground` 与《Displaying the right widget background》文档：前者按组件环境提供标准背景；后者说明 Watch Smart Stack 的系统材质背景及容器背景移除规则。不添加自定义模糊或额外玻璃图层。
- Mac 共享逻辑 **66 项测试通过**：`artifacts/test-core-watch-widget-background.log`；完整 iPhone／Watch／两端组件 Debug 编译通过：`artifacts/build-watch-widget-background.log`。已确认两端组件均编译到修改后的共享视图；差异空白检查通过。
- 遵循用户要求，未在模拟器添加、操作或调试小组件，未操作真机或上传 TestFlight。watchOS 27 的玻璃视觉效果尚未实测，需重新构建并更新 Watch App 及其组件扩展后由用户确认。

## Watch 心情记录到 iPhone 桌面团子组件（2026-11-21）

- 用户明确本次未及时更新的是 iPhone 桌面团子小组件。检查确认已有即时消息、持久队列、保存后回执及记录变化回调；旧代码在两端均以 `isReachable` 阻挡即时发送。新增的服务回归以不可达状态复现：手表分支即时发送次数为零。本结果是发送策略回归，不是用户配对真机症状的完整复现。
- 手表分支改为尝试通过即时消息唤醒后台 iPhone App；iPhone 发往 Watch 的分支仍检查可达状态。失败保留持久队列与本地待同步记录，仍只在收到匹配修订的保存回执后确认，不因尝试即时发送丢弃记录。测试使用窄的消息传输接口隔离真实设备，不启动另一端音频或发送健康提醒。
- 心情新增、收到及删除使用独立摘要更新：保留本地组件文件中的既有健康数值与趋势，替换最近心情与偏好，并定向请求刷新 `QingkongDumpling`。避免后台进程尚未加载健康数据时把组件的健康摘要写空。
- 摘要按真实内容去重，只有生成时间变化或重复投递时不重复写入和请求刷新；健康数值、心情或偏好改变仍刷新。重新激活 App 与用户明确刷新手表组件保留主动刷新请求，避免内容去重阻挡用户主动重试。摘要仍为原有 Codable 格式，仅新增 Equatable 比较能力。
- 修复前服务回归按预期失败：`artifacts/test-watch-widget-sync-red.log`。修复后 iPhone 17／iOS 26.5 模拟器 **23 项服务测试通过**，含六项新增用例：`artifacts/test-services-watch-widget-sync.log`。覆盖后台手机唤醒尝试、反向不可达保护、在途去重与匹配回执持久化、后台队列接收后摘要落盘、心情更新／删除保留健康摘要、相同内容抑制重复刷新，并回归原同步和提醒服务。未运行实际播放 65 秒的音频截止用例。
- 本轮 Mac 共享逻辑 **66 项测试通过**：`artifacts/test-core-watch-widget-sync.log`；最终完整 iPhone／Watch／两端组件 Debug 编译通过：`artifacts/build-watch-widget-sync-final.log`；差异空白检查通过。
- 遵循用户要求，未在模拟器添加、操作或调试小组件，未操作真机或上传 TestFlight。真实唤醒成功率、跨设备传输耗时、iPhone 桌面渲染及 watchOS 27 行为尚未验收；WidgetKit 最终刷新由系统调度，不能把发出刷新请求表述为已即时显示。需重新构建并更新 iPhone、Watch 及随包组件后由用户真机确认。

## 功能总表四轮开发初版（2026-11-21）

本轮依据 [功能总表](FeatureOverview.md) 实施，逐阶段状态见 [实施跟踪](plans/2026-11-21-feature-stages.md)。以下是本轮实际证据，不能将其等同于全部完成标准或配对真机验收。

### 已实现范围

- 第一轮：可选安心首页；iPhone／Watch 的 1／3／5 分钟舒缓呼吸或安静陪伴，暂停／恢复／退出、可选语音与 Watch 触感、减少动态效果适配；完成反馈、本机练习历史、健康摘要／实际提醒提交／心情／练习时间线及删除。提醒事件只表示系统接受提交通知，不代表用户收到。
- 第二轮：独立 Python 标准库 HTTP＋SQLite 内容服务，管理员登录／CSRF／限流、文章草稿／审核／发布／修订／撤回／历史恢复与公共快照。iPhone 分类、搜索、文章详情、来源和审核信息、收藏、已读离线缓存与修订撤回同步。18 篇初始选题仅为未审核提纲，未公开，不能计作专业文章交付。
- 第三轮：专辑／音轨管理、稳定标识及版本、HTTPS 媒体与版权信息；iPhone 在线播放和真实缓冲状态、超时错误、曲目队列、锁屏控制、下载进度／取消／重试／删除；完整字节数、SHA256 与可播放性检查。主动下载与 300MB 自动缓存分离，默认 Wi-Fi，蜂窝在线播放确认；重启重新校验，保护播放中的缓存。Watch 可遥控线上曲目，独立播放仍使用内置声音。
- 第四轮：可跳过心情记录的睡前流程、本地声音／场景／停止时间、可复用方案、可选生活标签、本地每周回顾，以及单独申请 HealthKit 睡眠只读权限的概览与按周汇总。睡眠按真实区间裁剪、重叠去重，缺失不补值，平均只计有数据夜数。心情旧数据兼容，删除时清空标签与日记。
- 后续体验部分：沿用五款团子的温和里程碑与减少动态效果适配；心情明信片由用户手动选择团子、场景和短句，预览固定图片后主动系统分享。未读取健康值、日记或压力评分加入明信片。更多团子动作与线上音轨下载到 Watch 尚未完成。

### 实际验证

1. **共享核心 95 项通过**：93 项 Swift Testing、2 项 XCTest，失败为 0。日志 `artifacts/test-feature-core.log`。覆盖放松计时／暂停／恢复／退出／反馈、实际记录汇总、删除墓碑、文章与媒体快照、文件版本及完整性、旧播放状态兼容、生活标签兼容、睡眠区间／重叠／DST／实际夜数均值，以及原健康、同步、提醒规则。

   ```sh
   CLANG_MODULE_CACHE_PATH="$PWD/build/clang-cache" \
   SWIFTPM_MODULECACHE_OVERRIDE="$PWD/build/swift-cache" \
   swift test --disable-sandbox --package-path Packages/QingkongCore \
     --scratch-path build/core-main-tests --cache-path build/package-cache
   ```

2. **后台 14 项实际本机 HTTP／SQLite 测试通过**：`python3 -m unittest discover -s ContentService/tests -v`，日志 `artifacts/test-content-service.log`。涵盖匿名只读、草稿隔离、审核发布前置、CSRF／Origin／限流、修订撤回／墓碑／历史恢复、专辑连带下架、版权到期、版本与链接校验及拒收个人数据。仅临时本机端口和数据库，无外网请求或真实发布。
3. **新增 iPhone 服务测试 4 项执行通过**：练习持久化／去重／删除、损坏文件不覆盖、删除摘要不复活、重启保持原停止截止且不自动播放。证据 `artifacts/test-feature-services.log` 与 `artifacts/FeatureStageServices.xcresult`。这些测试本轮早期实际运行于 iPhone 17／iOS 26.5 模拟器；随后读到既有真机验收约定时，测试已经结束，之后未继续模拟器运行验收。未添加、操作或调试小组件。本轮不能表述为“未使用模拟器”，也未把服务测试当作 HealthKit、后台或配对验收。
4. **最终完整无签名设备构建通过**：iPhone、Watch 与两端组件，日志 `artifacts/build-feature-stages-final.log`，包含最终睡眠按周授权加载、Watch 被动状态失败保留遥控上下文及睡前重试稳定 ID 修复。

   ```sh
   CLANG_MODULE_CACHE_PATH="$PWD/build/clang-cache" \
   SWIFTPM_MODULECACHE_OVERRIDE="$PWD/build/swift-cache" \
   xcodebuild -project Qingkong.xcodeproj -scheme Qingkong \
     -destination 'generic/platform=iOS' \
     -derivedDataPath build/FeatureStages CODE_SIGNING_ALLOWED=NO build
   ```

   受限环境第一次因无法写入系统 SwiftPM 缓存失败；允许 Xcode 使用其系统编译缓存后成功。Python 字节码检查第一次同样遇到缓存写入限制，改用项目内 `PYTHONPYCACHEPREFIX` 后通过。以上不是源码通过证据的替代，只说明重试原因。最终构建仍有原 `MPVolumeView.showsRouteButton` 弃用警告，未改动该音量功能。
5. **Watch 两种设备架构源码检查通过**：`sh scripts/check_watch_sources.sh`，`arm64_32` 与 `arm64`，日志 `artifacts/check-watch-feature-stages-final.log`。首次受限环境无法运行 Observation 编译插件；允许使用 Xcode 编译插件后通过。这不代表资源安装、配对或后台运行通过。
6. **限定范围独立静态复核完成**：修复播放中的版权到期与元数据更新、历史周空态及按周读取、首次历史周授权加载、阅读后的放松入口、Watch 被动状态探测失败转本地旁路。睡前播放失败后重试沿用同一心情／方案 ID，并阻止并发重复开始。复核未发现这些指定修复的剩余遗漏，未运行真机，不能称行为验收通过。
7. `git diff --check`、相关 Info.plist 与工程 `plutil -lint`、后台与生成器 Python 编译检查通过。生成器增量执行前后工程及两个 scheme 的 SHA256 完全一致；四产品 Debug／Release 共 8 份配置均保留构建号 **13**、显示名称“小晴空”及 iPhone 分类。证据 `artifacts/project-feature-stages-final.json`。

### 工程配置恢复与待复核

本轮首次运行生成器时误用全量生成，覆盖了已有工程设置与 scheme。依据开发前 22:24:16 的 Xcode PIF 缓存，恢复了四产品构建号 13、显示名和 iPhone 分类；原 Team、签名、部署版本及架构没有差异。恢复比对证据为 `artifacts/project-settings-recovery.json`。生成器现默认保留现有工程与 scheme，只增量加入新增文件；完整重建需显式指定 `--recreate-project`。

Watch scheme 已恢复仓库原格式。**原 iPhone scheme 当时存在未提交的手动修改，尚未找到精确备份；当前为仓库版本，不能声称已完整恢复其原手动配置。** 本轮未再次改动它，需用户或后续工作根据原意复核。工作区原有功能修改、营销材料及其他文件保留，未执行提交、推送、部署、安装真机、归档或上传 TestFlight。

### 尚未达到的完成标准

- 第二轮：需提供真实撰写并经过专业审核的 15～20 篇文章、真实来源及审核信息。后台记录审核声明，不能替代专业审核。需确定公共服务 HTTPS 域名与部署环境；客户端默认无正式地址。
- 第三轮：需提供版权明确、含授权期限／来源的真实音轨及 OSS 长期 HTTPS 地址、版本、大小与 SHA256；检查播放稳定及循环接缝。需用真实网络和配对真机验证断网／重试、蜂窝确认、空间不足、锁屏／后台、路由／中断、停止定时、版本更换和 Watch 回执，当前纯规则测试不能证明这些系统行为。
- 第一、四轮：仍需配对真机验证无需健康权限的练习、暂停／退出、语音／触感、减少动态效果、大字号／VoiceOver、记录查看删除、睡前失败重试、单独睡眠授权、不同权限／空数据／历史周结果，以及重启后定时。
- 隐私上线材料：已更新应用内说明、官网政策初稿及商店草稿，明确个人数据留在设备和公共网络访问的边界。实际服务提供商、托管／OSS 日志及保留期限仍需按部署补齐，未进行正式法律或平台申报审核。
- 后续阶段：更多团子动作、Watch 线上音轨下载与手表自身离线校验仍待实施；明信片实际预览、系统分享及可访问性待真机确认。手机缓存不能标为手表已下载。

因此本轮交付为前四轮的可构建开发初版及部分后续体验，全部外部完成标准仍未达成。

## 后续体验补充与最终复核（2026-11-21）

本节更新上节的当前状态；上节记录保留为开发过程证据。前四轮及后续体验已有开发初版，尚未达到全部外部验收标准。

### 实现与边界

- 五款团子沿用既有素材，新增招呼／点头／摇摆。招呼始终可用，首次主动心情和首次完成练习分别解锁点头、摇摆；点按重播、单次归静，减少动态效果时静态。仅保存两个本机布尔标记，不保留对应记录内容、不跨端同步，删除记录或漏记不收回。
- Watch 独立获取公共目录、主动下载音轨、校验字节数／SHA256／可解码后本机播放，已下载队列按顺序切歌。手机只同步公共服务地址，两端下载与缓存分别保存；手机离线可用不代表手表已下载。
- Watch **仅支持前台主动下载**：离开曲库页面或应用退后台中断，可返回手动重试。默认请求避开蜂窝、昂贵与低数据网络；watchOS 自行选择连接，可能经手机代理，不通过低层网络探测承诺识别代理背后的物理 Wi-Fi。等待连接及错误依据真实 URLSession 回调。
- 校验使用独立 UUID 作废取消、重试、删除或目录撤回后的旧结果，防止迟到校验覆盖成功重试。手表明确选择内置或下载声音后保持本机来源；等待手机回执后重新检查来源，离页或来源切换使旧播放操作失效。播放设置使用 watchOS 支持的原生列表。
- `ContentService/editorial-drafts.json` 已有 18 篇完整中文待审稿，对应全部种子选题，正文各 396～439 个非空白字符，附 28 个不同的机构来源链接。独立结构检查覆盖选题、章节、字数和状态，证据 `artifacts/check-editorial-drafts.json`。来源浏览核验由编辑代理完成；结构检查不代表专业审核。全部 `draft`／`not_reviewed`／`review=null`，未启动服务、导入或发布。人工审核流程见 `../ContentService/EDITORIAL.md`。
- README、应用内隐私说明、官网政策、产品文档与商店草稿已同步公共地址配对同步、Watch 独立网络访问／本机缓存及两个动作标记。实际服务商和日志期限仍须按部署填写。

### 实际验证

1. **共享核心 101 项通过**：99 项 Swift Testing、2 项 XCTest，失败为 0。`build/companion-actions-core-tests.log`，包含新增动作可用性、温和解锁与减少动态效果规则。此后未改共享核心，无重复扩大测试。
2. **9 项真实文件存储检查通过**：`sh scripts/check_audio_downloads.sh`，`artifacts/test-portable-audio-downloads-final.log`。在 Mac 使用真实 WAV 和隔离目录，检查两端离线状态分开、重启重新校验、播放文件保护与删除、损坏文件拒绝、版本失效、版权到期／撤回，以及可控延迟下的取消、成功重试不被旧结果覆盖、撤回不被旧校验复活。不请求网络、不播放音频、不使用模拟器或设备。
3. **最终完整无签名设备构建通过**：iPhone、Watch 及两端组件，`artifacts/build-watch-downloads-final.log`。

   ```sh
   CLANG_MODULE_CACHE_PATH="$PWD/build/clang-cache" \
   SWIFTPM_MODULECACHE_OVERRIDE="$PWD/build/swift-cache" \
   xcodebuild -project Qingkong.xcodeproj -scheme Qingkong \
     -destination 'generic/platform=iOS' \
     -derivedDataPath build/FeatureStages CODE_SIGNING_ALLOWED=NO build
   ```

   首次最终构建发现新增 `Menu` 在 watchOS 不可用；改为原生列表后重新构建通过。仍有原 `MPVolumeView.showsRouteButton` 弃用警告。只编译，没有安装或运行；此前动作代理的通用 Simulator 目标也仅编译，未安装运行。
4. **Watch App 与组件双设备架构源码检查通过**：`sh scripts/check_watch_sources.sh`，`arm64_32` 与 `arm64`，`artifacts/check-watch-downloads-final.log`。不替代真机运行验收。
5. **限定独立静态复核完成**：校验 UUID 和显式本机来源保护；发现并修复等待手机回执后的来源竞争及旧页面操作窗口，复核未发现指定窗口剩余问题。未运行 UI 或设备，不能称实际行为验收通过。
6. 差异空白、Info.plist／工程语法、后台与生成器 Python 编译检查通过。新增和迁移源码后再次执行增量生成器，工程与两个 scheme SHA256 不变，四产品 Debug／Release 共 8 份配置仍为 build **13**、显示名“小晴空”、原 Team 与 iPhone 分类。证据 `artifacts/project-watch-downloads-final.json`。此前 iPhone scheme 未提交手动差异无法精确恢复的限制仍保留。
7. 只读设备查询 `artifacts/devices-feature-acceptance.log`：iPhone 17、iPhone 13 mini 和 Watch Series 11 均为 **unavailable**，因此未进行本轮配对真机安装或运行。没有继续模拟器运行验收或操作小组件，没有提交、部署、归档或上传。

### 剩余完成条件

仍需真实专业审核这 18 篇文章，提供版权明确且可访问的正式音轨／OSS 地址和版本校验资料，确定服务部署信息及日志保留期限，并在可用配对真机验证 HealthKit、动作／分享／可访问性、网络中断与空间不足、锁屏／后台／路由／定时、Watch 独立离线与遥控及通知。当前代码、自动检查和构建不能替代这些验收；公共服务未部署、未配置正式地址。

## 完成标准逐项复核与遗漏修复（2026-11-21）

本节为最新实现与自动验证状态，保留上文历史证据及其限制。重新对照功能总表后补齐以下四项：

- **解锁持久化**：心情与完成练习成功保存后立即写入对应解锁标记，加载时迁移旧记录；不依赖打开动作页面，删除记录及重新加载不收回解锁。仍只保存两个本机布尔值。真实隔离存储检查先复现保存后未打开页面即删除会丢失解锁，再修复通过；证据 `artifacts/test-companion-milestones-before.log`、`artifacts/test-companion-milestones-final.log`。
- **当前曲目封面**：播放器、迷你条和 Watch 按当前线上曲目／专辑封面显示；无有效 HTTPS 封面时用中性占位，避免借用上一首内置声音图片。播放状态兼容旧协议并携带封面地址；锁屏异步图片任务取消旧请求，核对曲目标识与地址，限制响应大小，失败不影响播放。新增封面传输回归先失败后通过，证据 `artifacts/test-artwork-state-before.log`、`artifacts/test-feature-core-completion-audit.log`。远端图片与锁屏实际显示仍待真机确认。
- **残留文件管理**：iPhone／Watch 的“已存文件”依据实际索引展示过期、撤回及旧版本文件，管理能力与播放资格分开；删除失败保留索引，播放中的文件受保护。旧目录引用不能再次播放或下载；目录撤回后迟到的恢复校验仍对外显示不可用，但保留可清理记录。最后一项回归通过真实目录权限制造删除失败并验证恢复任务的迟到结果，先失败后通过；证据 `artifacts/test-download-management-state-before.log`、`artifacts/test-download-management.log`。
- **自动缓存保留**：iPhone 完整自动缓存可选择“保留下载”，复用已校验字节升级为主动下载，自动空间清理与重新加载均不删除该文件。文件检查同时覆盖此路径。

### 最新实际验证

1. 共享核心 **104 项通过**，含 102 项 Swift Testing 和 2 项 XCTest，失败为 0：`artifacts/test-feature-core-completion-audit.log`。覆盖新增封面兼容、无封面／不安全地址及切回内置声音规则。
2. **14 项真实文件检查通过**：`sh scripts/check_audio_downloads.sh`，`artifacts/test-download-management.log`；**4 项真实存储解锁检查通过**：`sh scripts/check_companion_milestones.sh`，`artifacts/test-companion-milestones-final.log`。两者在 Mac 隔离目录执行，不请求网络、不播放音频、不使用 UI、模拟器或设备。后台本轮未修改，沿用此前 14 项本机 HTTP／SQLite 通过证据，未重复运行。
3. 最新完整无签名设备目标编译成功，覆盖 iPhone、Watch 与两端组件：`artifacts/build-feature-completion-audit.log`。命令仍为 `xcodebuild -project Qingkong.xcodeproj -scheme Qingkong -destination 'generic/platform=iOS' -derivedDataPath build/FeatureStages CODE_SIGNING_ALLOWED=NO build`，使用项目内模块缓存并允许 Xcode 编译插件访问其系统缓存。保留原 `MPVolumeView.showsRouteButton` 弃用警告；没有安装或运行。
4. `sh scripts/check_watch_sources.sh` 退出 0，Watch App 与组件的 `arm64_32`、`arm64` 均检查通过：`artifacts/check-watch-completion-audit.log`。这不能证明资源安装、设备运行或配对行为。
5. `git diff --check`、工程与三个 Info.plist 的 `plutil -lint`、使用项目内字节码缓存的后台及生成器 Python 编译检查通过。增量生成器幂等，四产品共八份配置保持 build **13**、显示名、Team 与 iPhone 分类：`artifacts/project-completion-audit-final.json`。此前 iPhone scheme 未提交手动差异无法精确恢复的限制仍然保留。
6. 限定静态复核未发现解锁与封面修复的确定剩余问题。只读设备查询仍为上节所记 unavailable；本次继续未运行模拟器、操作小组件、安装真机、提交、部署、归档或上传。

前四轮及后续体验的开发初版与上述自动验证已完成；专业审核、正式音源／OSS／部署资料和配对真机验收仍待补齐，**全部完成标准尚未达到**。具体阶段状态见 [实施跟踪](plans/2026-11-21-feature-stages.md)。

### 外部验收条件复查

继续推进目标时重新读取功能总表，以及当前知识库、离线缓存、时间线和本地回顾实现，未以既有测试通过代替外部验收。最新 `xcrun xctrace list devices` 正常结束，iPhone、iPhone 13 mini 与 Apple Watch 均列于 `Devices Offline`：`artifacts/devices-feature-acceptance-latest.log`。没有启动模拟器或操作设备。18 篇稿件仍未专业审核，正式音源和服务部署资料仍未提供；当前无法继续执行相应完成标准，目标保持未完成。

## 用户授权测试文章与客户端缓存联调（2026-11-22）

用户允许生成测试文章，新增 `Tests/Fixtures/PublicContent/snapshot.json`（原文章样本合并歌单后统一使用此名）：6 篇中文非医学功能文案、3 个分类，覆盖短文、长标题／长文、正文搜索、收藏、修订和撤回。所有文章标题、摘要、正文、来源与审核字段均说明测试用途；快照中的审核和发布时间是模拟输入，不是专业审核或正式发布。测试包不属于 App 资源，不自动加载或导入正式后台。阅读预览为 `artifacts/test-articles-preview.md`，使用说明见 `../Tests/Fixtures/PublicContent/README.md`。

- `sh scripts/check_content_library.sh` **10 项通过**：`artifacts/test-content-library-fixtures-final.log`。测试直接运行生产 `ContentLibrary`，以隔离 UserDefaults、真实临时磁盘与进程内 URLProtocol 响应检查加载、只缓存已读／收藏、重新构造后的离线重读、失败保留历史检查时间、修订覆盖磁盘正文、撤回清理收藏／已读／正文、旧版本不复活、损坏响应保留可用内容、切换服务清理缓存，以及固定公共地址的匿名 GET 请求。全部响应被拦截，没有真实网络或个人数据上传，也没有运行 UI、模拟器或设备。
- `ContentLibrary` 仅增加可选缓存目录与 URLSession 注入，用于隔离上述检查；未传入时仍用原缓存目录和共享会话。没有新增正式服务地址或演示内容自动加载逻辑。
- 将测试文章的允许编辑字段写入临时 SQLite，6 篇均保存为 `draft`、`review=null`、无已发布副本，公共文章列表为空：`artifacts/check-test-articles.json`。没有给真实后台写入内容、绕过发布审核或启动服务。
- 修改后共享核心 **104 项通过**（102 Swift Testing＋2 XCTest）：`artifacts/test-core-test-articles-final.log`。iPhone、Watch 与两端组件的通用设备目标无签名构建成功：`artifacts/build-test-articles-final.log`；Watch App 与组件 `arm64_32`／`arm64` 检查通过：`artifacts/check-watch-test-articles-final.log`。保留原音量控件弃用警告，未安装或运行。
- 本机客户端检查首次因执行环境限制无法启动 Observation 编译插件，日志 `artifacts/test-content-library-fixtures.log`；允许编译插件后原样运行并通过。首次失败不是源码回归的红灯证据。最终差异空白检查通过；工程配置和 scheme 本次未修改。

本轮已用生成文章补齐本地内容联调证据。测试文案不能计作首批经过专业审核的正式文章；真实网络／部署、版权音源与配对真机验收仍待完成，目标保持未完成。

## 用户三份测试歌单与真实文件检查（2026-11-22）

用户随后提供三份测试歌单并允许命名，已按原顺序整理为「晴天随行」「星光慢行」「微风来信」，各 10 首，合并至 `Tests/Fixtures/PublicContent/snapshot.json`，与 6 篇测试文章共同组成测试公共快照。保留完整曲名、歌手和 Explicit 标记；公司、创建人、部门等后台字段未带入。预览为 `artifacts/test-playlists-preview.md`。

- **真实下载与源摘要**：30/30 个 HTTPS MP3 完整下载成功，总计 256,735,401 字节，实际大小均与附件一致。按用户说明将 `digest` 解析为 `MD5:` 冒号后的 32 位值，流式计算本地完整文件 MD5，30/30 匹配；另外生成 30 份 SHA256，继续使用客户端既有完整性和缓存版本规则。文件位于 `build/TestPlaylistMedia/<track UUID>.mp3`，不加入 App 资源。证据 `artifacts/test-playlist-downloads.log`、`artifacts/test-playlist-assets.json`、`artifacts/check-test-playlist-digests.json`。
- **媒体格式检查**：AVFoundation 对 30/30 文件确认 `isPlayable`、读取实际时长并解码初始 PCM 帧；使用实际时长生成测试快照，与附件整数时长最大差约 0.963 秒。29 张曲目封面通过 HTTPS 响应与图片格式检查；“Sorry - Justin Bieber” 未提供封面，使用专辑封面后备。证据 `artifacts/test-playlist-audio-probe.log` 和上述资产报告。这些检查没有实际播放声音，也不是设备运行验收。
- **实际下载管理 6 项通过**：`sh scripts/check_test_playlists.sh`，证据 `artifacts/test-user-playlists-final.log`。使用全部 30 首真实 MP3 与实际 `AudioDownloads`，覆盖三专辑原顺序、完整校验后离线可用、独立设备目录不继承手机文件、重构后重新校验、撤回时保护正在使用的文件并在释放后清理、剩余文件删除及空间计数归零。只在临时目录复制本地文件，无网络、声音播放、模拟器或真机操作；脚本不会自动下载缺失媒体。
- **合并快照后客户端 10 项仍通过**：`sh scripts/check_content_library.sh`，证据 `artifacts/test-content-library-playlists-final.log`；覆盖前节所列实际文章缓存、修订与撤回路径。两项脚本共 16 项本机检查通过。
- **后台格式与草稿隔离**：在临时 SQLite 仅保存允许编辑的字段，6 篇文章、3 张专辑与 30 首曲目共 39 条均为草稿、无已发布副本，文章 `review=null`，三个公共列表均为空。证据 `artifacts/check-test-library.json`。未启动或写入真实服务。

本轮已取得真实测试音源与文件校验证据；正式版权、有效期和服务部署资料仍未提供，配对真机上的锁屏／后台／路由／中断、空间不足、Watch 独立播放与遥控验收仍未完成。测试版权文本、审核和有效期均为明确标注的占位，不视为正式授权或发布。文章专业审核与其他真机完成标准仍未达到，目标保持未完成。本次歌单与文档工作未修改工程或 scheme。

## 后台撤回契约与实际客户端缓存修复（2026-11-22）

继续对照功能总表核对客户端和后台边界时，发现 `ContentService` 和 `API.md` 使用 `articles`／`albums`／`tracks` 撤回类型，Swift 的 `PublicContentSnapshot.validated` 却只检查单数 `article`／`album`／`track`，已有回归也使用单数。结果是同一响应同时带有可见内容和其后台格式撤回记录时，冲突不会被拒绝，实际客户端会覆盖上一份有效缓存。

- **先复现再修复**：新增核心三类参数化用例，三类均因“预期抛错却未抛错”失败：`artifacts/test-tombstone-contract-before.log`。实际 `ContentLibrary` 检查也在“冲突撤回不得覆盖有效缓存”断言失败：`artifacts/test-client-tombstone-contract-before.log`。这两项是源码行为缺陷的复现。
- **修复**：快照校验识别后台的复数类型，并将早期单数类型归一后检查，以保持旧缓存兼容。实际客户端测试使用后台复数格式。合法完整撤回继续替换目录；冲突响应整体失败，原内存、收藏状态和磁盘缓存保持可用。
- **共享核心 105 项通过**：103 Swift Testing（新增用例含三类参数化场景）＋2 XCTest，`artifacts/test-tombstone-contract-final.log`。实际客户端缓存 **11 项通过**：`sh scripts/check_content_library.sh`，`artifacts/test-client-tombstone-contract-final.log`，包含冲突响应不能覆盖内存或磁盘缓存。
- **后台实际 JSON 联调**：独立临时 SQLite 保存 6 篇非医学测试文章、3 张专辑与 30 首用户测试音轨，通过回环 HTTP 读取生产服务的实际响应。4 项后台检查确认 39 条草稿不外露、明确模拟发布后数量与顺序正确、未发布修订保持旧公共版本、明确重发后稳定 ID 和文件版本更新、文章及专辑连带撤回生成 12 条三类复数墓碑。随后使用生产 Swift 解码与校验读取这些原始 JSON，4 项跨语言检查通过，包含真实三类墓碑的矛盾响应拒绝。证据 `artifacts/test-backend-playlist-contract.log`、`artifacts/check-backend-playlist-contract.json`、`artifacts/test-swift-backend-playlist-contract.log`。模拟审核信息明确标注非真实专业审核；临时服务已关闭、数据库已移除，未向正式服务发布、未下载新媒体或操作设备。此项验证 JSON 契约，Swift 客户端未直接连接该 HTTP 地址，也没有放宽生产 HTTPS 要求。
- **通用设备无签名构建成功**：`xcodebuild -project Qingkong.xcodeproj -scheme Qingkong -destination 'generic/platform=iOS' -derivedDataPath build/FeatureStages CODE_SIGNING_ALLOWED=NO build`，覆盖 iPhone、Watch 及两端组件：`artifacts/build-tombstone-contract-final.log`。首次受限构建因系统编译缓存不可写而未进入源码编译，保留 `artifacts/build-tombstone-contract-restricted.log`；允许访问编译缓存后原样通过，不将首次环境错误计作源码回归。

本轮修复了一个实际契约遗漏，未修改工程或 scheme，未运行模拟器或操作真机。功能总表的正式专业审核、版权／部署资料及配对设备行为验收仍缺证据，全部完成标准尚未达到。

## 实际 HTTPS 下载回调与暂存格式修复（2026-11-22）

此前 30 首真实 MP3 的本地检查直接向完整文件校验入口传入带 `.mp3` 后缀的文件，没有经过实际 `AudioDownloads.download()` 和 URLSession 下载回调。补充真实网络检查后发现，部分传输取消通过，但完整下载在大小和 SHA256 匹配后仍报告音频无法播放：`artifacts/test-live-audio-download-before.log`。

- **根因对照**：下载 delegate 将 URLSession 临时文件移至纯 UUID 文件名，丢失音频格式提示。同一份 6,367,017 字节 MP3 在本机 AVFoundation 中，无后缀时 `isPlayable=false`，带 `.mp3` 时 `isPlayable=true`：`artifacts/test-audio-staging-probe.log`。这项对照和真实下载失败属于生产路径缺陷证据。新检查第一次编译另有抛错表达式用于非抛错 autoclosure 的写法错误，已修正检查代码；`artifacts/test-live-audio-download-compile.log` 仅是检查代码编译错误，不计作生产回归。
- **修复**：`Sources/Shared/AudioDownloads.swift` 保留原请求 URL 的受支持音频后缀；URL 无有效后缀时，以响应 MIME 和系统 `UniformTypeIdentifiers` 推导。完整验证后的缓存文件也保留已推导后缀，避免保存时再次丢失格式提示。只使用系统模块，大小、SHA256、版权、版本身份和下载网络规则保持原行为。
- **4 项实际 HTTPS 检查通过**：`sh scripts/check_live_audio_download.sh --network`，证据 `artifacts/test-live-audio-download-final.log`。通过生产下载方法和 delegate 检查真实部分字节不可离线及取消、重试完成后完整性与媒体校验、版本替换时清理旧文件并独立重新下载、重新构造管理器后重新校验及删除空间归零。
- **实际外网范围**：只使用测试快照中最小的一首 “Only The Young (Featured in Miss Americana) - Taylor Swift”，大小 6,367,017 字节；两次完整下载共 12,734,034 字节，另有一次中途取消的部分传输。脚本限制单个文件不超过 20 MB，并要求显式传入 `--network`。文件使用隔离临时目录，结束时移除；通过 UserDefaults 的 volatile argument domain 只在本进程覆盖网络偏好，结束时恢复，不修改 App 持久偏好。实际使用 Mac 的当前网络及 URLSession，不证明物理断网、iPhone Wi-Fi／蜂窝切换、后台传输或 Watch 网络行为，也未播放音频。
- **修复后回归**：共享核心 **105 项通过**（103 Swift Testing＋2 XCTest），`artifacts/test-core-staging-final.log`；下载文件 **14 项通过**，`artifacts/test-download-staging-final.log`；全部 30 首真实 MP3 的 **6 项本地下载管理检查通过**，`artifacts/test-playlists-staging-final.log`。后两项不请求网络、不播放声音。
- **构建与架构**：iPhone、Watch 和两端组件通用设备目标无签名构建成功：`artifacts/build-download-staging-final.log`；Watch App 和组件的 `arm64_32`／`arm64` 源码检查通过：`artifacts/check-watch-staging-final.log`。保留原 `MPVolumeView.showsRouteButton` 弃用警告；仅编译，未安装或运行。

本轮未修改工程或 scheme，未运行模拟器、操作真机、部署或发布。内容后台仍只有本机临时验证，尚无手机可访问的 HTTPS 服务；正式专业审核、音频授权资料和配对真机行为验收仍未完成，目标保持未完成。

## 用户自行部署的 Docker 交付（2026-11-22）

用户已有服务器和 `https://xqk.geckoai.cn`，允许将 `/api` 反代至服务，要求生成 Docker Compose 后自行部署。已新增根目录 `compose.yaml`、后端镜像、交互凭据生成工具、Nginx 片段与 `ContentService/DEPLOYMENT.md`。仅运行一个 Python 标准库后端，SQLite 保存在命名数据卷；宿主机默认只开放 `127.0.0.1:8787`，通过已有 HTTPS 入口转发 `/api/`、`/admin` 及 `/admin/`，保留原路径和外部 Host。

- **18 项后台测试通过**：原有 14 项及新增 4 项部署用例，证据 `artifacts/test-docker-deployment-final.log`。新增用例覆盖实际 CLI 容器监听、Secure 管理 Cookie、私密配置文件、禁止覆盖已有文件及无效凭据不落盘；新增测试先失败的证据为 `artifacts/test-docker-deployment-before.log`。
- **本地 Docker 镜像构建成功**：`artifacts/build-content-docker.log`。镜像仅含运行源码，不包含真实凭据、数据库、文章包、测试歌单或音频；容器使用 UID/GID `10001:10001`、只读根文件系统、健康检查和日志轮转。`docker compose config --quiet` 通过。
- **5 项隔离 Compose 实测通过**：`artifacts/test-content-compose-runtime.log`。确认容器实际收到的密码散列完整、健康状态与回环绑定正确、真实管理员登录与草稿隔离正常、显式模拟发布可读取；强制重建后 SQLite 内容和 revision 保留、旧会话失效；文档中的停机备份命令生成包含数据库的压缩包。此前脚本误把 Compose 导出时的 `$$` 转义视为运行值变化，现以容器环境和登录结果核验。没有因此改动生产凭据逻辑。
- **2 项部署命令检查通过**：`artifacts/test-content-package-commands.log`。在镜像内实际执行交互配置工具（隔离测试输入），生成权限 `600` 的 `.env` 并核对密码散列；提供的 Nginx 两个 location 在无网络、无发布端口的本地 Nginx 容器中执行 `nginx -t` 成功。
- 测试只使用本机 `desktop-linux` Docker context、唯一命名的项目、临时凭据和数据。测试项目及数据卷已删除，不连接用户服务器或域名、不导入真实内容。未修改 App 源码、运行模拟器或操作设备。

交付包为 `artifacts/qingkong-content-deploy.tar.gz`，仅包含部署所需代码、示例配置与说明，不包含真实 `.env`、数据库或媒体。首次启动内容为空，测试资料不自动公开。SQLite 容器重建和停机备份已测，备份恢复尚未实测。用户远端部署、HTTPS／管理访问与客户端联调、实际代理及 OSS 日志保留、专业审核、正式音频授权和配对真机验收仍未完成；此次交付不代表全部完成标准达成。

## SSH 授权部署与阿里云镜像发布（2026-11-22）

用户随后授权免密 SSH `root@xqk.geckoai.cn` 部署，并允许将镜像推送到 `registry.cn-hangzhou.aliyuncs.com/geckoai/`。本节为最新服务状态：公共后端已实际部署，前节的远端部署待办已完成；专业内容及配对设备验收仍未完成。

- **镜像发布成功**：`registry.cn-hangzhou.aliyuncs.com/geckoai/qingkong-content:20261122-096642645c03`，架构 `linux/amd64`，镜像 ID 为 `sha256:096642645c03c1ffbf3e3d4cbc6cbe5740e60b130383213b06d74baa695fc0e2`，仓库 manifest 摘要为 `sha256:5ea2835138e15e0c4337b6dcf811d884d55a54e33149f9a2deb4e99a9399dccd`。证据 `artifacts/build-content-server-amd64.log`、`artifacts/push-content-aliyun.log`。服务器直连 Docker Hub 拉取受限，已仅停止本次部署构建，改从用户指定的阿里云仓库拉取；没有修改服务器 Docker 镜像源或网络配置。
- **远端容器健康**：部署目录 `/opt/qingkong-content`，容器 `qingkong-content-content-1`，Compose 支持通过 `QINGKONG_CONTENT_IMAGE` 选取版本。实际镜像摘要匹配上述发布结果，监听 `127.0.0.1:8787`，UID/GID `10001:10001`、只读根文件系统、256 MiB 内存限制、`unless-stopped` 重启策略生效。命名卷 `qingkong-content_content-data` 挂载到 `/data`，目录权限 `700`；实际 SQLite `PRAGMA quick_check` 返回 `ok`。证据 `artifacts/deploy-xqk-start.log`、`artifacts/check-xqk-server.log`。
- **Nginx 已备份并平滑重载**：仅在域名的 HTTPS server 块加入片段 include，`/api/` 使用 `^~` 防止原静态资源正则抢占；管理入口正则在原静态匹配之前。原配置备份 `/opt/qingkong-content/backups/nginx/xqk-20261122T025839Z.conf`，实际片段 `/etc/nginx/qingkong-content.locations.conf`，`nginx -t` 通过后执行平滑重载。证据 `artifacts/deploy-xqk-nginx.log`。
- **真实 HTTPS 验证通过**：证书正常校验，快照、分类、文章、专辑、曲目共 5 个接口成功；匿名管理会话返回 401，实际管理员登录、读取管理目录及退出成功，Cookie 的 Secure／HttpOnly／SameSite 正常。原首页部署前后字节完全一致，SHA256 为 `9d45159c1f4cf6c0f7790c8c998d0472cc04801d1c3435d1de9a6f985d994fe9`。证据 `artifacts/check-xqk-live-https.json`、`artifacts/deploy-xqk-https.log`。验证没有创建、编辑或发布内容；当前 revision 为 0，内容库为空。
- 管理员随机强密码未进入命令参数或输出，服务器仅保存密码散列和会话秘密，`.env` 权限为 `600`；用户登录资料保存在本地被 Git 忽略的私密文件，权限为 `600`。部署包不包含这些文件。没有改动 App 源码、官网内容或其他容器，没有运行模拟器或操作设备。

本次只修改部署配置与说明，未修改后端运行逻辑，沿用已通过的 18 项后台用例；新增镜像选择已通过 Compose 解析和远端实际拉取／运行验证。后续仍需远端发布与实际客户端修订／撤回同步、专业审核、正式音频授权、代理／OSS 日志资料，以及配对真机行为验收。远端数据库备份恢复、主机重启后的自动启动尚未实测，不把配置存在称为这两项行为已经通过。

## 网页登录 CSRF 误拒绝修复（2026-11-22）

用户报告网页登录返回 `CSRF 校验失败，请刷新管理页面`。先前 HTTPS 验证通过的是主动设置正确 Origin 的 JSON 请求，未覆盖 HTML 原生表单受页面策略影响的来源值。线上响应实际为 `Referrer-Policy: no-referrer`；按 [Fetch Standard 的请求 Origin 算法](https://fetch.spec.whatwg.org/#append-a-request-origin-header)，此策略会把非 CORS 表单 POST 的 Origin 序列化为 `null`，因此与现有严格来源检查冲突。标准原文摘录保存在 `artifacts/fetch-origin-policy-reference.txt`。

- 新增真实本机 HTTP 表单回归，依据页面响应策略构造请求，修复前稳定返回 403 和相同错误，证据 `artifacts/test-browser-form-csrf-before.log`。对修复前线上 HTTPS 按同样规则提交表单也返回 403，证据 `artifacts/deploy-xqk-html-form-before.log`。
- 仅将公共响应中的 `Referrer-Policy` 改为 `same-origin`；保留 CSRF token、Origin 严格匹配及 Secure／HttpOnly／SameSite Cookie，不接受 `null` 或其他站点来源。补充 `null` 来源拒绝回归。完整后台 **19 项测试通过**，证据 `artifacts/test-browser-form-csrf-final.log`。
- 新版本 `registry.cn-hangzhou.aliyuncs.com/geckoai/qingkong-content:20261122-2c006d421037` 已构建、推送并部署，manifest 摘要 `sha256:ae25e7902608afc6bb2e088110a631754fb0d3ca28ec42479e4db3751595070d`，远端镜像 ID `sha256:2c006d42103725f960a7869ae3a81d4962c3449722f373deed5dab061d3ebacf` 匹配。证据 `artifacts/build-content-csrf-fix.log`、`artifacts/push-content-csrf-fix.log`、`artifacts/deploy-xqk-csrf-fix.log`。更新前备份配置，更新后比较管理员散列、会话秘密及公共内容，均未变化。
- **修复后实际 HTTPS 表单登录与退出通过**：使用 HTML 表单编码与正文 CSRF 字段，按 Fetch 规则确定 Origin，不再用手工设置的 JSON 登录请求充当网页表单验证。匿名管理仍返回 401，5 个公共接口及原首页一致性检查仍通过。证据 `artifacts/deploy-xqk-html-form-final.log`、`artifacts/check-xqk-live-https.json`。远端健康、摘要、数据卷及 SQLite 完整性复核通过，证据 `artifacts/check-xqk-server-csrf.log`。
- 当前会话的浏览器工具返回不可用，未进行真实浏览器点击或 UI 验证；上述表单检查是按标准构造的真实 HTTP／HTTPS 请求，不能称浏览器实测。服务更新使旧会话及旧表单失效，用户需要重新打开登录页。没有修改密码、公开内容、Nginx 或 App 源码。

## 测试内容上线与用户模拟器验收准备（2026-11-22，最新）

用户明确要求「启动模拟器，给待验收项目」及「后台添加几篇文章和几张专辑」。此前测试资料不公开的边界由本次明确授权更新，仅发布用户指定的功能测试内容；18 篇专业待审稿保持未审核、未导入。

- **测试发布与兼容**：增加受保护的 `publish_test` 操作，仅接受带指定标题／正文测试标记且有来源的文章；公开快照带 `testOnly:true`，记录真实测试发布时间与操作，不写虚假的专业审核。普通文章继续走专业审核流程，移除标记后的修订不能使用测试发布。后台预览和客户端详情明确显示「未专业审核」。Swift 可选字段兼容旧快照并随离线缓存保留。
- **先失败后通过**：后台新用例最初返回 400（未支持操作），证据 `artifacts/test-content-test-publication-before.log`；客户端模型最初在往返编码后丢失 `testOnly`，证据 `artifacts/test-core-test-publication-before.log`。修复后后台 **20 项通过**（`artifacts/test-content-test-publication-final.log`），共享核心 **106 项通过**，其中 104 Swift Testing＋2 XCTest（`artifacts/test-core-test-publication-final.log`），真实客户端缓存 **11 项通过**（`artifacts/test-client-test-publication-final.log`）。
- **构建与部署**：iPhone、Watch 和两端组件通用设备无签名构建成功（`artifacts/build-test-publication-device-final.log`）；iPhone 17／iOS 26.5 模拟器构建成功（`artifacts/build-simulator-acceptance.log`）。镜像 `registry.cn-hangzhou.aliyuncs.com/geckoai/qingkong-content:20261122-test-99dd5fa03639` 已推送并部署，manifest 摘要 `sha256:c34a09dca1b484d31938f096a342f7bca1c1cd903c4e65d7745a57d8dd381f30`。更新前备份 `.env`，更新后确认凭据与原公共内容未变化，再按用户授权导入测试内容。证据 `artifacts/build-content-test-publication.log`、`artifacts/push-content-test-publication.log`、`artifacts/deploy-test-content.log`。
- **实际 HTTPS 导入**：使用已有管理员凭据、Cookie 和 CSRF 经管理接口创建并发布 39 条内容：6 篇非医学测试文章、3 张测试专辑、30 首用户音轨；最终 revision **39**。专辑为「[测试] 晴天随行」「[测试] 星光慢行」「[测试] 微风来信」，各 10 首，原曲名和顺序保留。音频 URL、真实字节数、SHA256 与文件版本逐条核对未变；版权字段如实注明用户提供测试素材、正式资料待补充。未上传媒体、未删除既有内容。证据 `artifacts/import-xqk-test-content.log`、`artifacts/publish-xqk-test-content.json`。
- **上线后复核**：真实 HTTPS HTML 表单登录／退出、5 个公共接口、匿名管理 401、Secure Cookie、原首页字节一致通过；远端容器 healthy，镜像摘要匹配、SQLite `quick_check=ok`、内容总数 39。证据 `artifacts/check-xqk-test-content-https.log`、`artifacts/check-xqk-live-https-with-test-content.json`、`artifacts/check-xqk-test-content-server.log`。真实生产 `ContentLibrary.refresh()` 使用默认 URLSession 直接连接线上 HTTPS，取得 6／3／30 条内容并在临时目录重新读取缓存，测试标记保留；无自定义传输或证书放行。证据 `artifacts/check-xqk-live-client-test-content.json`。
- **实际模拟器准备**：安装当前构建并正常启动，没有使用 `--ui-testing`、`--demo-health` 或清空已有数据。通过 Simulator 原生界面保存服务地址并刷新；实际观察到文章列表、测试正文、已读标记及「功能测试 · 未专业审核」详情。保留 App 在知识库供用户接手；未自动播放音频、操作系统权限或添加／操作小组件。该观察只证明启动、连接和文章展示准备完成，不将用户尚未操作的功能标为验收通过。清单 `docs/AcceptanceChecklist.md` 含 A01～A14、B01～B05，全部待用户确认。
- **部署隐私核对**：只读检查主机 DMI 标识为 Alibaba Cloud ECS；公共接口与管理入口继承共享 Nginx 访问／错误日志。配置每日轮转、最多 52 份历史归档、空日志不轮转、无固定天数上限；容器运行日志每份 5 MB、最多 3 份。没有读取任何请求日志、没有修改共享策略，也未核验调度或实际删除时间。证据 `artifacts/check-xqk-logging.json`。App、官网政策源码、隐私说明和商店核对资料已按事实更新；官网政策未发布，云平台和媒体桶自身的日志规则仍待确认。
- **当前真机限制**：重新只读查询时 iPhone 17、iPhone 13 mini 仍 unavailable；Watch 可发现且配对，但明确返回 Developer Mode disabled、DDI services unavailable，随后连接断开。没有启用开发者模式或安装到真机，未把设备可发现当成可验收。此前受限环境查询的 CoreDevice 初始化超时属于环境限制；允许只读查询后取得上述实际状态。

目标全部完成标准仍未达到：正式文章专业审核、正式音频授权，以及真实健康／后台音频／通知／Watch 配对行为仍需相应证据。本次交付为可操作的用户测试环境；后续验收结果按实际反馈记录。

## 线上文章发布、修订与撤回同步（2026-11-22）

使用一篇独立、明确标记的临时非医学测试文章，通过已有 HTTPS 管理接口操作；没有编辑留给用户的 6 篇文章、3 张专辑和 30 首曲目。实际生产 `ContentLibrary.refresh()` 使用默认 URLSession 读取同一线上服务，以独立临时目录和 UserDefaults 保存状态，没有自定义网络响应或证书放行，没有操作模拟器。

5 个阶段均通过：新草稿不公开（revision 39）；测试发布后正文和测试标记可读取、已读／收藏及磁盘重读正常（40）；编辑未发布时仍读取旧正文（40）；重新测试发布后更新正文并保留已读／收藏及磁盘缓存（41）；撤回后列表、收藏、已读和重读缓存均不含该正文，复数 `articles` 撤回记录保留（42）。后台历史按顺序为 `save_draft`、`publish_test`、`save_draft`、`publish_test`、`withdraw`。

临时文章已撤回，保留审计历史和撤回记录。结束时公共目录仍为 6 篇文章、3 张专辑、30 首曲目；用户手动验收清单保持待确认。证据为 `artifacts/check-xqk-live-revisions.json` 和 `artifacts/check-xqk-live-revisions.log`。本次未修改 App 或后端源码，因此未重复运行全量测试与 Xcode 构建。独立检查程序首次编译受 Xcode 宏插件运行限制，允许编译插件后成功；这不是功能失败或通过证据的替代。正式专业审核、音频授权和配对真机验收仍待完成。

## 线上音轨版本、专辑撤回与官网说明（2026-11-22，最新）

- **6 阶段实际曲库联调通过**：通过受保护 HTTPS 管理接口创建独立临时专辑与音轨，实际生产 `ContentLibrary.refresh()` 获取目录，并由 `AudioDownloads.download()` 使用真实 URLSession 下载。验证专辑／音轨草稿隔离（revision 42）、发布专辑不泄漏音轨草稿（43）、发布音轨并下载校验（44）、未发布的文件替换不影响旧公开版本（44）、同一音轨 ID 发布不同 URL／SHA256／大小／版本的新文件后旧缓存失效并清理，新文件完整校验后才离线可用（45），以及专辑撤回连带移除音轨、复数撤回记录及已下载文件（46）。实际下载两个用户提供的测试 MP3，共 **12,964,369 字节**；没有播放声音。
- **隔离与收尾**：使用独立临时目录、独立内容偏好和仅进程有效的网络偏好覆盖，下载走 Mac 当前网络，没有更改真实 App 偏好、操作模拟器或编辑既有验收内容。临时专辑及音轨已撤回，保留真实操作历史；公开目录仍为 **6 篇文章、3 张专辑、30 首曲目**。证据 `artifacts/check-xqk-live-albums.json`、`artifacts/check-xqk-live-albums.log`；检查程序编译退出 0，日志 `artifacts/build-live-album-check.log`。这不证明 iPhone／Watch 的物理网络、锁屏、后台、路由或真实空间不足行为。
- **官网隐私页已发布**：实际公网旧页仍声明“App 没有自有后端服务器”。按功能总表“上线公共内容服务时同步更新官网政策”及已有服务器部署授权，只发布 `website/privacy.html`，更新日期为 2026-11-22，保留 1.1 开发版说明。已覆盖公共服务与阿里云 ECS、已核对的 Nginx 轮转设置、测试 OSS 及其日志未知项、睡眠只读授权、手表独立请求／缓存、管理员会话 Cookie 与明信片主动分享；未宣称未知日志规则已经确认。发布前备份至 `/opt/qingkong-content/backups/website/privacy-before-content-20261122T034624Z.html`，仅原子替换该文件，不重载 Nginx。
- **公网复核通过**：HTTPS 政策字节与本地核对稿完全一致，SHA256 `8bf07df4a547a5aa80edc9cd002d989a3443ffbe507d5d1bcaf8ef539b97961d`；首页 SHA256 仍为 `9d45159c1f4cf6c0f7790c8c998d0472cc04801d1c3435d1de9a6f985d994fe9`，公共快照正常，匿名管理仍返回 401。本地检查了 21 个页面锚点及 14 个本地资源引用，没有进行本轮浏览器视觉验收。证据 `artifacts/check-xqk-website-before-policy.json`、`artifacts/check-privacy-policy-local.json`、`artifacts/deploy-xqk-privacy-policy.json`、`artifacts/check-xqk-privacy-policy-live.json`。
- **真机状态重查**：两台 iPhone 仍 unavailable；Watch 为 available／paired，详细查询明确 `developerModeStatus: disabled`、`ddiServicesAvailable: false`，连接不代表可调试。没有更改设备设置或安装 App。证据 `artifacts/check-device-readiness-current.log`、`artifacts/check-watch-readiness-current.log`。

本轮没有修改 App 或后端运行源码，不重复全量构建。用户手动验收结果仍未收到；专业审核、正式版权／期限、云平台与媒体桶日志资料、配对真机系统行为仍缺证据，全部完成标准尚未达成。

## A02 首页与 A03 陪伴页调整（2026-11-22）

- 用户已确认 A01 验收通过；清单已记录，A02、A03 保持待复验。按最新反馈，「安心首页」默认开启，开关放在个性化；首页右侧团子放大并按标题末行文字基线对齐，删除原下方节奏提示。已有手动选择保留。隔离偏好检查确认首次默认开启、关闭／开启后重读保留、已有睡前方案不变：`artifacts/check-calm-home-a02.log`。
- 陪伴页引导声音默认开启，可主动关闭；开始、暂停／继续、退出及完成反馈统一使用正常尺寸原生按钮，iPhone 的动作、时长与方式改用原生分段选择。呼吸复用已认可的分层团子路径：胸腹局部起伏，手臂与面部独立轻动，双脚与影子固定。实际渲染的静止、吸气与呼气姿态为 `artifacts/breathing-rest.png`、`breathing-inhale.png`、`breathing-exhale.png`，检查日志 `artifacts/check-breathing-render.log`。
- 最终共享核心测试 **106 项通过**（104 Swift Testing＋2 XCTest），日志 `artifacts/test-core-a03-breathing.log`；iPhone 17 模拟器构建及 iPhone／Watch／组件通用设备构建均成功，日志 `artifacts/build-simulator-a03-breathing.log`、`artifacts/build-device-a03-breathing.log`。工程生成器已同步新增共享视图与 iPhone 分层素材引用；生成前后核对既有构建设置和 Scheme 未变。`git diff --check` 通过。
- 已覆盖安装并正常启动现有 iPhone 17／iOS 26.5 模拟器，未清空数据、未加入测试或演示启动参数。实际查看首页团子位置、个性化开关关闭后显示健康空状态、恢复开启后回到团子首页；查看陪伴页声音开关默认开启和完整按钮，操作开始、暂停、继续与退出，暂停后倒计时保持 00:50，继续后递减且吸气／呼气文字切换，退出回到首页。最终保留首页及安心首页开启供用户接手。本轮未运行 XCTest UI 测试，未完成整段练习或操作反馈按钮，未切换系统减少动态效果或核验真实语音听感；这些不记作用户验收通过。整体阶段目标仍保持暂停。

## A03 两种陪伴方式与专属动画（2026-11-22）

- 按用户反馈移除陪伴准备页、练习和完成页中的额外动作选择与重播提示，仅保留「舒缓呼吸」「安静陪伴」两种方式。准备页随选择预览对应动画；舒缓呼吸延续胸腹、手臂和面部独立起伏、双脚落地的拟人呼吸，安静陪伴使用已认可团子素材，加入短暂眨眼、轻轻歪头和偶尔挥手。其他页面使用的动作组件保留。
- 两种练习动画均由实际累计练习时间驱动，暂停时冻结、继续时恢复；减少动态效果时保持静态。保留 1／3／5 分钟、默认开启的引导声音及正常尺寸原生按钮。功能总表与 A03 清单已同步，A03 保持待用户复验。
- 共享核心 **106 项通过**（104 Swift Testing＋2 XCTest）：`artifacts/test-core-two-companion-modes.log`。iPhone 17 模拟器构建、iPhone／Watch／组件通用设备无签名构建均成功：`artifacts/build-simulator-two-companion-modes.log`、`artifacts/build-device-two-companion-modes.log`。实际分层姿态渲染检查通过，覆盖呼吸与安静陪伴的静止、眨眼、歪头、挥手：`artifacts/check-two-companion-poses.log`、`artifacts/build-two-companion-poses.log`；对应图片位于 `artifacts/breathing-*.png` 与 `artifacts/quiet-*.png`。本轮未新增源文件或目标引用。
- 已覆盖安装并正常启动当前 iPhone 17／iOS 26.5 模拟器，保留数据且无测试或演示启动参数。实际查看准备页没有「团子动作」，声音默认开启；切换为安静陪伴后预览更换，开始后倒计时递减，暂停后两次观察均保持 **00:48** 且团子姿态保持，继续后倒计时恢复递减。再次进入默认舒缓呼吸，观察吸气／呼气提示与团子局部姿态变化；两次短练习均提前退出，未生成完成记录。最终停在陪伴准备页，默认舒缓呼吸、1 分钟、声音开启，供用户接手。
- 未运行 XCTest UI 测试、未完成整段练习、未操作完成反馈、未切换系统减少动态效果或核验真实语音听感；编译和姿态渲染不替代真机或用户验收。整体阶段目标保持暂停，仅处理本轮反馈。

## A03 平静等待、固定身形与呼气气流（2026-11-22）

- 按最新反馈，准备页统一使用轻轻眨眼的平静等待动画，不随陪伴方式选择预先做呼吸。点击开始后才按所选方式播放练习动画。呼吸团子移除树叶，身体轮廓、双脚及影子保持固定，以肩臂抬落、面部轻动和收拢嘴型表现呼吸；呼气阶段增加向外移动、淡出的气流，气流时间与实际练习时间一致。原静态素材及其他页面团子不变，安静陪伴仍保留其可爱动作。
- 最终共享核心 **106 项通过**（104 Swift Testing＋2 XCTest），日志 `artifacts/test-core-calm-waiting.log`；iPhone 17 模拟器和 iPhone／Watch／组件通用设备无签名构建均成功，日志 `artifacts/build-simulator-calm-waiting.log`、`artifacts/build-device-calm-waiting.log`。按实际练习尺寸渲染呼吸三个姿态及准备页静止／眨眼姿态，日志 `artifacts/build-calm-waiting-poses.log`、`artifacts/check-calm-waiting-poses.log`，图片 `artifacts/breathing-airflow-comparison.png`、`artifacts/companion-waiting-*.png`。
- 已覆盖安装、正常启动当前 iPhone 17／iOS 26.5 模拟器，保留全部数据且未使用测试／演示启动参数。实际查看默认舒缓呼吸选中时准备页仍为平静等待；开始后切换为没有树叶的呼吸团子，连续观察 18 帧、约 11 秒，确认吸气与呼气阶段肩臂／嘴型变化、身形固定及呼气气流。暂停后两次观察均保持 **00:29** 和相同姿态，继续后倒计时递减；本次检查提前退出，未完成练习或添加反馈。最终停在准备页，保持 1 分钟、舒缓呼吸和引导声音开启，供用户接手。
- 本轮没有新增目标引用，`git diff --check` 通过。未运行 XCTest UI 测试、未切换系统减少动态效果或验证真实语音听感，不将渲染或构建视为用户验收；A03 仍待复验，整体阶段目标保持暂停。

## 心情明信片预览返回按钮（2026-11-22）

- 实际查看用户停留的「分享前预览」：无障碍标题为正确的「返回编辑」，但四字文本在圆形工具栏按钮中被挤压，视觉上类似乱码。将该按钮改为原生 `chevron.backward` 图标，保留「返回编辑」的无障碍名称及原有关闭预览行为。
- 共享核心 **106 项通过**（104 Swift Testing＋2 XCTest），日志 `artifacts/test-core-postcard-back.log`；模拟器及通用设备构建成功，日志 `artifacts/build-simulator-postcard-back.log`、`artifacts/build-device-postcard-back.log`。已覆盖安装、正常启动并保留既有数据，实际确认左上角箭头清晰、点按返回编辑后仍为晴空场景／开心团子及原短句，再次打开预览显示正常；最终停在修复后的预览页供用户接手。未打开系统分享面板或执行分享，未运行 XCTest UI 测试，手动验收状态不代用户改为通过。`git diff --check` 通过，整体阶段目标保持暂停。


## 首页专辑推荐与全部专辑页（2026-11-22）

- 首页原固定自然声音卡片替换为最新发布且有曲目的真实专辑，显示封面、介绍、歌曲顺序及整张专辑播放按钮；刷新按最新专辑列表轮换，更多进入全部专辑页。共享专辑组件复用既有在线播放、完整文件校验、下载与蜂窝确认入口；当前歌曲及迷你播放条读取同一播放器状态。全部专辑页按用户追加反馈去掉获取成功提示与曲库检查时间，直接显示专辑封面和歌曲。
- 原生内容检查 **12 项通过**，新增检查使用与排序字段不同的发布时间、较新的旧专辑编辑时间、打乱的服务端数组及反转的专辑曲序，确认最新推荐按发布时间排列、原目录排序不变、播放列表遵循专辑明确曲序。证据 `artifacts/check-content-home-albums.log`。最终共享核心 **106 项通过**（104 Swift Testing＋2 XCTest），模拟器及通用设备构建成功：`artifacts/test-core-home-albums.log`、`artifacts/build-simulator-home-albums.log`、`artifacts/build-device-home-albums.log`。
- 已保留数据覆盖安装并正常启动 iPhone 17／iOS 26.5 模拟器，未使用测试或演示参数。实际点击首页刷新后，「晴天随行」切换为「星光慢行」，封面与 10 首歌曲同时更换；实际点击更多进入「专辑与声音」。期间观察到星光慢行首曲 Sparks Fly 的播放状态和迷你播放条对应。去掉顶部信息后的最终版本再次覆盖安装，并实际从首页点击更多，确认顶部信息消失、页面从封面开始，歌曲列表可见；最后留在该页供用户验收。
- 本轮未运行 XCTest UI 测试，未实测自动播完单曲或上一首／下一首、蜂窝切换、真机后台及锁屏；不把播放状态、构建或检查结果当作这些路径通过。手动验收清单 A09 保持待用户验收，整体阶段目标继续暂停。

## 内容入口、播放进度与悬浮条触控（2026-11-22）

- 默认公共服务固定为 `https://xqk.geckoai.cn`，移除客户端内容服务设置；个性化底部提供 GitHub／Issues 与公共内容、个人数据范围说明。首页新增三篇知识图文及更多入口；助眠从封面开始，两个入口移至音量下、停止定时上，下方展示当前／最近专辑，首次使用默认最新专辑。内置「随身自然」包含林间落雨、慢慢听海、星光慢板，并补封面与简介。断网回退代码已实现，本轮未关闭实际网络；三段内置 WAV 均为 16 秒开发循环素材，不计入正式音轨或版权验收。
- 助眠增加真实音频进度、已播放与剩余时间、暂停中拖动定位；音量左侧使用菜单选择单曲、顺序、随机循环并在本机保留。完整验证整张专辑可离线时隐藏整专辑下载图标，单曲管理保留。睡前流程按钮统一正常尺寸。悬浮条改为底部安全区域中的加高容器，封面 48 点、容器最小 76 点，暂停按钮在 label 内提供 48×48 点触控区，胶囊空白接住点击。按用户最终要求，暂停后隐藏悬浮条，助眠主按钮可继续播放。
- 播放器专项实际模拟器测试 **3 项通过**，覆盖本地 seek 与暂停保持、模式持久化及随机排除当前曲、真实声音结尾的三种模式切换。最终证据为 `artifacts/test-playback-progress-summary.json`（Passed，3／0）及 `build/SimulatorAcceptance/Logs/Test/Test-Qingkong-2026.11.22_13-56-39-+0800.xcresult`。`artifacts/test-playback-progress-final.log` 曾被两个进程同时写入，含旧失败和后续成功，不单独作为最终结论。原生内容、下载检查各 **14 项通过**：`artifacts/check-content-playback-controls.log`、`artifacts/check-downloads-playback-controls.log`。
- 悬浮暂停最终逻辑的共享核心 **106 项通过**（104 Swift Testing＋2 XCTest），模拟器、iPhone／Watch／组件通用设备构建均成功：`artifacts/test-core-mini-player-final-authorized.log`、`artifacts/build-simulator-mini-player-final-authorized.log`、`artifacts/build-device-mini-player-final-authorized.log`。普通受限执行最初无法写入系统编译缓存、连接模拟器服务；允许所需本机访问后通过，前一组失败日志保留，不当成功证据。
- 已保留数据覆盖安装并正常启动 iPhone 17／iOS 26.5，无测试或演示参数。直接按屏幕坐标点击悬浮暂停图标中心与 48 点区域边缘两次，均确认主按钮变为开始播放、悬浮条消失、未进入下层页面；两次之间用主按钮恢复播放，时间继续递增。查看循环菜单的三项与单曲勾选，保留原模式；实际进入睡前两步，确认继续／开始／返回及已有方案按钮外观，没有保存新方案或心情。也已观察完整缓存专辑没有整专辑下载图标。未运行 XCTest UI 测试，未测真机后台、锁屏、蜂窝或 Watch 运行，不代替用户验收。官网隐私文案本轮只更新本地，未再次部署。

## 参考来源文字链接与首页文章间距（2026-11-22）

- 文章参考来源保留原生 `Link` 和 HTTPS 校验，显式使用 plain 样式、主题色下划线文字与浏览器打开提示。首页专用文章区域行间距由 16 点收紧至 8 点，移除卡片额外纵向内边距，保留 12 点横向内边距、原封面尺寸与整行点击；知识列表页及共享文章行不变。用户反馈第一版仍宽，最终进一步收紧，手动验收仍待用户确认。
- 最终共享核心 **106 项通过**（104 Swift Testing＋2 XCTest），模拟器和 iPhone／Watch／组件通用设备无签名构建均成功：`artifacts/test-core-compact-articles-final.log`、`artifacts/build-simulator-compact-articles-final.log`、`artifacts/build-device-compact-articles-final.log`。没有新增网络依赖或修改服务端。
- 最终进一步收紧版已保留数据覆盖安装、正常启动并观察首页；前一版已实际从首页打开文章，无障碍来源项带浏览器打开提示。用户同时操作模拟器，本轮未取得最终间距与来源区的完整视觉复验，也未实际打开外部浏览器，不将这两项写为已验收。`git diff --check` 通过。

## 后台管理、富文与正文图片（2026-11-22）

- 后台登录与管理统一为 iOS 风格，文章与专辑／音乐分区；文章支持富文、逐条标题＋HTTPS 来源。歌曲先选专辑，再粘贴长期 HTTPS 链接，服务读取真实文件的名称、摘要、时长、大小、SHA256 和版权标签，识别后可修改；缺少的版权信息保持未知。服务器真实 `Sparks Fly` 文件约 260.933 秒、10584640 字节，SHA256／大小与发布目录匹配，仍缺 owner／source／license。证据 `artifacts/test-media-live-server.log`。
- 正文增加链接插图、本地 JPG／PNG／WebP 上传及粘贴图片路径。上传接口要求登录、同源与 CSRF，先校验权限再读文件；受限处理器校验并去元数据、缩图，持久保存公共配图，不自动创建／发布文章。手机使用原生文字和图片分段显示，有限下载、尺寸检查及下采样，失败显示 alt 占位。文章离线缓存已保存富文与图片元数据，但图片文件未持久离线缓存。
- 图片版 Linux 容器后台 **73 项全通过**，macOS **72 通过、1 项 Linux 专用跳过**；共享核心 **113 Swift Testing＋2 XCTest，共 115 项通过**；原生内容缓存 **15 项通过**。证据分别为 `artifacts/test-backend-article-images-container.log`、`test-backend-article-images-local.log`、`test-core-article-images.log`、`test-content-article-images.log`。图片版模拟器及 iPhone／Watch／组件设备构建成功：`build-simulator-article-images.log`、`build-device-article-images.log`。均位于 `artifacts/`。最初 Docker 构建漏打包 `images.py`，已修正并重建成功，失败日志保留。
- 镜像 `20261122-images-adbccdbf74ce` 已推送用户指定仓库并按既有 SSH 授权部署；容器健康、SQLite `ok`，管理员凭据、网站首页与公共内容保留。revision 46，6 篇测试文章／3 张专辑／30 首曲目。HTTPS 已核验登录样式与图片 CSP、公共 JSON、上传路径允许超过旧 2 MiB 上限且匿名仍返回 401。没有发布图片测试文章，相关部署证据见 `artifacts/deploy-content-article-images.log`、`check-article-images-https.json`；当前部署详情见 `../ContentService/DEPLOYMENT.md`。
- 最新 App 已保留数据覆盖安装并正常启动模拟器，未使用测试／演示参数，证据 `artifacts/install-simulator-article-images.log`。图片版浏览器验证时 Chrome 停在用户资料选择页，未完成真实上传保存重开；也未实际观察手机正文图片的网络加载与视觉效果。前一版富文编辑保存重开等浏览器操作不能替代新增图片路径验收。

## 功能总表逐项审计（2026-11-22）

- 三个只读审计范围覆盖总表客户端 69 点、后台 9 点、数据与服务 5 点，主代理复核确定缺口并合并为 **74 完成／9 部分／0 整项空白**。Watch 独立下载已有实现，旧阶段文案不能当作未开发；图片文件离线、正式文章／授权及最新隐私全渠道同步不能算完成。逐项代码依据、验证边界与计数见 [审计报告](FeatureAudit-2026-11-22.md)。
- 本轮重新执行共享核心 **115 项通过**（113 Swift Testing＋2 XCTest）；后台运行 **73 项，72 通过、1 Linux 专用跳过**；生产 `ContentLibrary` 原生缓存检查 **15 项通过**。日志为 `artifacts/test-core-feature-audit-20261122.log`、`test-backend-feature-audit-20261122-authorized.log`、`check-content-feature-audit-20261122-authorized.log`。后台首次受限执行无法监听本机测试端口，缓存检查首次无法运行 Xcode 宏插件；获得所需本机访问后重跑通过，初始失败日志保留，不计通过。
- 重新读取实际公开 HTTPS 快照，revision 46，文章／专辑／曲目为 6／3／30，六篇均明确 `testOnly=true`，未冒充专业审核；证据 `artifacts/feature-audit-20261122-snapshot.json`。本轮没有重部署、重启服务、写线上内容、操作模拟器／真机或更新手动签收状态。A01 仍是唯一用户明确通过项。
- 重新拉取公开隐私页并计算摘要：当前本地 SHA256 为 `e21a6338f15d7a02c23736f1b20f11008b6781318a524bdb55ec04439bbc6b15`，公网仍为 `8bf07df4a547a5aa80edc9cd002d989a3443ffbe507d5d1bcaf8ef539b97961d`，确认最新本地文案尚未同步。证据 `artifacts/feature-audit-20261122-live-privacy.html`、`feature-audit-20261122-summary.json`。审计未修改官网部署。

## 补开发与分端验收（2026-11-22，首次审计之后）

- 补齐正文／封面图片持久离线缓存、两款团子表情及两处风景收藏、健康卡实际来源与采样时间。逐项实现覆盖现为77／83（92.8%），6项部分交付涉及正式专业内容、版权、云平台日志资料及商店隐私提交；没有把构建或模拟器检查记为用户签收。
- 当前代码共享核心118项、原内容磁盘15项、图片磁盘11项、解锁磁盘4项通过；macOS后台运行73项、72通过及1项Linux专用跳过。iPhone／Watch真机目标无签名构建与两端x86_64模拟器构建通过。日志及具体范围见 [分端记录](PlatformAcceptance-2026-11-22.md)。
- 手机3条交互分别通过：首次心情解锁并预览、实际一分钟陪伴解锁并预览、明确演示数据下的健康来源时间显示。健康开关初次测试点位错误，修正测试后独立重跑通过，失败记录保留；不声称整组三项一次全绿。未添加或操作手机小组件，交用户用包含本轮修改的TestFlight版本验收；本轮没有上传新包。
- Watch独立模拟器实际打开收藏入口并滚动查看两组锁定预览及说明；不把共享规则测试替代Watch实际解锁，也不把最后一次受用户界面变化影响的返回操作记为通过。配对真机路径仍待验收。
- 用户自行登录正式Safari后台后，实际验证文章／音乐分区、歌曲新建表单顺序，以及本地上传图片＋HTTPS图片＋正文粗体＋来源表单保存、列表重开和预览。专用草稿保留未发布，没有改变公开目录；退出登录后关闭本次后台页面。观察记录为 `artifacts/web-completion-observations-20261122.md`。
- 官网最新隐私政策已备份并同步，公网与本地摘要一致，证据 `artifacts/check-privacy-live-completion-20261122.log`。本轮专用手机与Watch模拟器均已关闭删除，原运行设备正常关闭保留数据；清理后没有Booted设备，证据 `artifacts/completion-devices-after.json`。旧本地预览服务已停止，不停止正式服务，不操作用户Chrome。

## 手机播放与布局、Watch 陪伴修复（2026-11-22）

- 手机进度条直接读取最新编辑位置，不再被旧时间覆盖；暂停后拖动保持暂停。仅助眠主页隐藏悬浮播放条，助眠子页和其他标签页继续显示。首页两处更多与刷新同高，封面装饰不再拦截按钮点击；文章收藏和明信片预览返回使用原生工具栏单层外观。生活标签改为独立圆角分组、52 点行高、行间分隔和开关右侧留白。
- Watch 切歌元数据原子更新，封面加载保留上一张并缓存，加载提示预留固定空间，更多使用白底黑色图标；最终音乐封面按可用高度缩放。陪伴页单屏只保留团子与开始／结束，默认 1 分钟、舒缓呼吸、声音和触感开启，首页 more 进入设置，时长与方式用点选列表。增加吸气脉冲和呼气转换触感，暂停、未开始、完成或关闭触感时不发送。
- 共享核心 **119 项通过**（117 Swift Testing＋2 XCTest），见 `artifacts/bugfix-core.log`。手机最终 **2 项服务测试＋2 项 UI 测试全部通过**，覆盖真实本地 AVPlayer 定位、暂停保持、切歌完整元数据、进度条实际拖动、悬浮条根页／子页切换、两个更多导航及标签行间距，见 `artifacts/bugfix-phone-acceptance.log` 与 `build/Bugfix20261122/Logs/Test/Test-Qingkong-2026.11.22_17-55-56-+0800.xcresult`。明信片编辑预览另一次 UI 测试通过，见 `artifacts/bugfix-phone-ui-final.log`。旧切歌逻辑曾在同一回归中产生 8 个断言失败，修复后通过；初期测试点位、标识与一次 UIKit 测试进程启动失败的记录保留，不计通过。
- 手机最终测试构建与 Watch 最终模拟器构建成功，Watch App／组件 arm64_32、arm64 源码检查通过，见 `artifacts/bugfix-phone-build-final.log`、`bugfix-watch-build-final.log`、`bugfix-watch-sources-final.log`。源码检查不替代安装、资源或运行验收。
- 手机无测试参数读取实际公共内容，点击刷新从「[测试] 晴天随行」切换到「[测试] 星光慢行」，更多进入专辑页；文章收藏和取消收藏有效并观察单层工具栏。最终截图确认六个生活标签开关完整显示、没有右侧裁切，证据 `artifacts/bugfix-phone-final-attachments/9C6B1C6C-45ED-4026-A087-C73AAB4792D5.png`、`artifacts/bugfix-phone-article-favorite.png`。明信片返回单层效果另已观察。本轮不发布官网或上传 TestFlight。
- Watch 实际观察首页设置入口、时长与方式的同屏点选、声音／触感开关、准备及运行的单屏布局，并完成一段 1 分钟舒缓呼吸，确认本机保存 1 条完成记录及结束返回首页；音乐更多黑色图标可读。最后自适应音乐布局版本已安装启动并观察陪伴准备页，但模拟器滚动／拖拽未能移到音乐入口，**最终音乐布局未完成运行复验**。观察范围见 `artifacts/bugfix-watch-observations.json`。配对远程连续切歌、实际震感与语音听感仍待真机；手机小组件按用户要求跳过运行验收，留 TestFlight，不将编译视为组件验收。
- 本轮专用 iPhone／Watch 模拟器已关闭删除，清理结果见 `artifacts/bugfix-devices-after.json`。保留用户原设备及官网本地预览，不操作用户现有浏览器页面。


## 智能叠放背景与手机团子音乐组件（2026-11-22）

- 手机新增小号／中号「团子音乐」：最近心情团子、当前歌曲、上一首／播放或暂停／下一首；点团子或歌曲进入助眠。App Intent 复用手机 App 的同一播放器，冷启动恢复本机保存的歌曲，在线歌曲不可用时返回错误而不换播内置歌曲。音乐状态只写本机 App Group，保留原手机／手表同步回调。
- 专项服务测试 **3 项通过**，覆盖快照读写及无意义更新时间去重、显式播放／暂停的幂等性、切歌沿用播放器、暂停保持、恢复错误不回退，以及已有播放错误时暂停仍成功。先增加回归断言复现旧错误误报，修复后重跑三项均通过：`artifacts/test-phone-music-widget-pause-regression.log` 为修复前失败证据，`artifacts/test-phone-music-widget-final.log` 为最终成功证据。共享核心 **119 项通过**（117 Swift Testing＋2 XCTest），见 `artifacts/test-core-music-widget.log`。
- 手机模拟器测试构建成功，见 `artifacts/build-phone-music-widget-final.log`；App 和 Widget 扩展均导出相同 MusicPlaybackIntent 标识和 AudioStarting 协议。按用户要求没有在模拟器添加或运行手机小组件；实际组件触控、系统刷新、App Group 签名访问及后台唤醒留待 TestFlight，服务测试不能替代上述验收。
- Watch 健康指标与团子组件移除 AccessoryWidgetBackground，Watch 容器使用透明背景。增加独立 HRV／心率／血氧静态配置卡片，保留原 QingkongMetric 配置与已有放置兼容；静态入口不依赖系统解析 MetricIntent，读取同一真实健康快照，没有数据时显示「—」与连接提示。最终 Watch 模拟器构建成功，见 `artifacts/build-watch-stack-metrics.log`。
- 用户原 46mm Watch 模拟器同时安装 local.qingkong.watchapp「晴空」与 cn.geckoai.qingkong.watchapp「小晴空」，两者均有历史卡片。已覆盖安装当前小晴空并重启模拟器，保留数据；日志进一步确认新版本配置卡片也发生 VoiceShortcutClient XPC 中断、Unable to get LNAction from intent、No AppIntent in snapshot 和 CHSErrorDomain 1101，因此持续占位不是缺少健康数据。证据 `artifacts/watch-widget-after-reboot.log`。没有移除隐私保护或填入示例健康值。独立卡片添加后已实际显示指标名称与无数据提示，但背景仍为黑色，背景验收未通过。
- 本轮专用手机测试模拟器 E2971DD5-79BB-44C6-B79C-DA3EB3953FBE 已关闭并删除；用户原手表设备保留，待当前手动卡片核对结束后处理。未发布官网、未上传 TestFlight、未部署后端。

- 按用户要求做纯文字对照：三个独立指标卡片临时只渲染「小晴空 · 背景测试」，不创建图表或健康布局，背景声明保持不变。标准模拟器签名构建与安装成功（`artifacts/build-watch-stack-text-test.log`），实际叠放已显示该测试文字，背景仍黑；排除图表作为当前黑底来源。保留测试版供用户对照，尚未恢复健康布局，不能作为最终交付版本。

- 继续验证 Watch 叠放黑底：在同一台 Series 11（46mm，watchOS 26.5）上，`.fill.tertiary` 的纯文字卡片呈深灰；随后 HRV 只保留 `Text` 和尺寸布局，完全不使用 `containerBackground` 或其他背景，叠放中的「HRV · 系统默认」仍呈黑底。对照构建见 `artifacts/build-watch-stack-system-control.log`。Apple 的《Displaying the right widget background》说明矩形叠放卡片默认使用深色材质；本机记录有 `fullColor`、`backgroundViewPolicy: Include`（`artifacts/watch-stack-render-mode.log`）。与系统默认外观一致，但未验证真机的透底程度。模拟器保留纯文字对照，工程已恢复正常指标、趋势、点按和无障碍说明。

- 按用户提供的写法，将健康指标 View 和团子组件的 Watch 分支统一改为 `.containerBackground(for: .widget) {}`，移除显式 `.clear`，保留真实数据、趋势、跳转与隐私标记。共享核心 119 项通过（117 Swift Testing＋2 XCTest），Watch 模拟器签名构建、覆盖安装和启动成功，见 `artifacts/test-core-stack-empty-container.log`、`artifacts/build-watch-stack-empty-container.log`。已实际观察完整血氧卡片恢复，背景仍呈黑色，与上方系统勿扰卡片的材质不同；未宣称玻璃效果修复。当前模拟器不再保留纯文字测试卡片。`showsWidgetContainerBackground` 为环境读值，未新增未使用字段或改变用户辅助功能设置。

- 按用户要求结束透明背景排查，撤销实验性背景改动：健康指标恢复 `AccessoryWidgetBackground` 与原有透明容器，团子恢复原有 Watch 系统辅助背景；移除染色诊断 View 和模式／背景测试文字。独立 HRV／心率／血氧入口、正式隐私标记与跳转、手机团子音乐组件均保留。此前全新编译及重启的诊断版仍显示 `fullColor`、背景保留，截图为 `artifacts/watch-stack-accent-diagnostic.png`；不把该结果认定为已实现玻璃效果。后续安装和提交使用恢复后的正式组件。

- 撤销排查后的提交前复核：共享核心 119 项通过（`artifacts/test-core-before-commit.log`）；手机／嵌入 Watch／组件通用设备构建及 Watch 模拟器构建通过（`artifacts/build-device-before-commit.log`、`artifacts/build-watch-before-commit.log`）。后台使用既有 Python 3.12 环境执行 73 项测试，72 项通过、1 项 Linux 专用测试跳过（`artifacts/test-backend-before-commit-final.log`）；最初系统 Python 缺依赖及受限环境不能监听本地测试端口的失败记录不计通过。官网与后台编辑脚本语法检查通过。已保留数据覆盖安装恢复后的 Watch 正式组件，并正常关闭用户原手表模拟器；未删除用户设备、未上传 TestFlight。提交不包含本地营销素材、索引缓存、构建产物或环境凭据。
