# 验收记录 · 2026-11-19

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
