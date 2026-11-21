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
