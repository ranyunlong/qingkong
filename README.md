# 小晴空 · Qingkong

小晴空是一款按已认可的 **01「晴空」** 设计实现的 iPhone + Apple Watch 原生开发版，并提供 Mac 伴侣端。免费、免注册、无广告。公共内容服务仅提供文章与音频目录；健康、心情和日记留在设备上，不进入内容后台。

## 打开项目

在 Xcode 打开 `Qingkong.xcodeproj`，选择 `Qingkong`、`QingkongWatch` 或 `QingkongMac` scheme。最低 iOS 18 / watchOS 11 / macOS 14，建议使用 Xcode 26 或更新版本体验系统悬浮导航。

工程包含 iOS App、独立 Watch App、WidgetKit 表盘组件扩展、原生服务测试、界面测试，以及本地 Swift Package `QingkongCore`。工程文件已生成，不依赖 XcodeGen 或第三方 Ruby 库。

若本机没有 watchOS 运行环境，可生成 **只用于 iPhone 预览** 的工程；源码与主工程相同，预览工程不内嵌 Watch：

```sh
python3 scripts/generate_project.py --phone-only
open QingkongPhonePreview.xcodeproj
```

主工程保留完整配对结构，不能用预览工程发布 Watch 版本。

## 已实现功能

2026-11-21 新增四轮开发初版：安心首页、两端 1／3／5 分钟陪伴、可删除本地时间线与练习、知识库搜索收藏缓存、公共内容后台、线上专辑播放与校验下载、睡前方案、生活标签、本地周回顾和单独授权睡眠概览。心情明信片先预览，再由用户主动分享。

后续体验已增加招呼／点头／摇摆动作及本机温和解锁、Watch 独立目录下载与完整校验后的离线播放。手表下载需保持曲库页面在前台，离页或退后台会中断，可返回重试；手机缓存不会变成手表下载。

这些功能仍需正式内容审核、音频授权，以及配对真机验收；本地测试已有生成文章和用户提供的三份歌单。分期状态见 [实施跟踪](docs/plans/2026-11-21-feature-stages.md)。内容后台启动和接口见 [ContentService](ContentService/README.md)；App 默认连接 `https://xqk.geckoai.cn`，无需填写服务地址；个性化底部提供 GitHub 开源仓库和 Issues 反馈入口。[18 篇完整待审稿](ContentService/EDITORIAL.md)已准备，全部未经专业审核，未导入或发布。

Docker Compose 位于根目录 `compose.yaml`，部署和更新步骤见 [Docker 部署说明](ContentService/DEPLOYMENT.md)。2026-11-22 已按用户授权部署到服务器 `/opt/qingkong-content`，通过 `xqk.geckoai.cn` 的现有 HTTPS 入口访问；镜像来自用户指定的阿里云仓库。后端只开放宿主机回环端口，SQLite 独立持久化；公共接口、管理登录／退出及原首页保持不变均已实测。当前内容库为空。

- 原生「今日／趋势／心情／助眠」导航；iOS 26 系统悬浮标签栏和玻璃按钮，播放时出现迷你播放条，强调色跟随场景。
- 长按 iPhone 桌面图标，提供「陪我缓一缓／当前趋势／记录此刻／听听音乐」四个快捷入口；分别打开练习准备、趋势、心情记录与助眠播放器，不自动开始练习或播放。
- iPhone 锁屏「手表电量」仅显示电量环，充电时在环上显示闪电；读数来自手表小晴空，超过 30 分钟显示淡色空环，不承诺实时后台更新。
- Mac 日／周／月健康、睡眠、心情与陪伴汇总，本机缓存可清除。相同 Apple ID 和 Wi-Fi 自动连接，iCloud 仅同步随机连接凭据；报表默认关闭自动同步；手机在「个性化 → 连接 Mac」中逐台授权后，前台自动检查并同步最近 38 天汇总，也可手动发送。Mac 默认独立播放；手机通过原生 AirPlay 入口选择 Mac 后，由 iPhone 持续播放并输出音频，Mac 小晴空只同步封面、队列和进度，操作等待手机回执。手机／手表可控制歌曲、循环和绝对停止定时，使用系统原生音量控件调节当前输出，手机可拖动进度；局域网界面连接断开只冻结 Mac 遥控，不暂停 AirPlay。Mac 界面的播放器应用增益独立于系统输出音量。CloudKit 最小信任结构已配置，真实 AirPlay、锁屏卡片及三端行为仍待验收。[本轮播放方案](docs/plans/2026-11-25-airplay-playback.md)替代旧 Mac 解码接力；[后续功能计划](docs/plans/2026-11-24-mac-companion.md)保留本机心情和统一时间线，Mac 不提供陪伴或呼吸练习。
- Mac 原生侧栏包含音乐、知识库、报表和设备；底部常驻播放控制、封面、进度与音量，可展开播放队列。音乐支持专辑网格、详情、单曲／整张下载和空间管理；内置三首声音归入「随身自然」。知识库支持分类、全文搜索、收藏、已读与正文／图片离线缓存，使用原生可选择文本阅读。报表使用趋势图、环图和陪伴统计，设备页提供图形连接引导。macOS 26 及更新版本使用系统玻璃效果，保留 macOS 14 兼容。
- 更新后的 iPhone 连接支持目录同步的 Mac 后，自动同步公开专辑和音轨目录；不发送下载文件、文章、收藏或已读记录。Mac 自行下载音频与封面，文章独立刷新，各设备保留自己的阅读和下载状态。旧 Mac 提示更新；目录同步超时或取消不关闭音乐连接。真实双机同步仍待验收，手机需要重新打包更新才能使用本轮新增目录同步。
- 2026-11-25 Mac 界面整改：歌曲下载状态不再增加文字行，使用细环；专辑提供原生筛选和搜索。「随身自然」只在网络已确认不可用且没有有效离线在线专辑时显示。知识库主页仅列表，文章在右侧全宽阅读，返回保留筛选与滚动位置；底部播放器常驻，移除独立播放说明及内容区装饰分割线。文章缩略图按显示尺寸异步解码，并使用有界内存缓存。
- Mac 播放器空队列时从第一张可播专辑第一首开始，已打开专辑优先；循环与定时分别位于上一曲前、下一曲后。音量点击后从按钮原位向左悬浮展开，以加深底色、细边框和强调色滑块区分，不挤压进度条；缓冲指示在左侧时间前紧凑固定占位。队列单击切歌，当前选中曲目的状态图标随窗口活跃状态调整颜色。macOS 26 的全部／已下载筛选采用系统玻璃胶囊按钮。
- 四套场景主题、原创五款心情表情；主动压力记录与应用内换景联动。
- SwiftData 心情日记、历史、删除；持久化待同步记录与删除墓碑。
- HealthKit 只读心率、血氧、SDNN HRV、心电图及波形。趋势不补零，基线不足明确展示。
- 默认开启、可关闭的本地放松提醒：HRV 明显下降后温和建议休息，限制频率并遵循系统专注规则；Watch 接手检测后，连接时交给 iPhone 通知并由系统选择显示位置，断连或探测超时由 Watch 本地通知。规则见 [放松提醒](docs/RelaxationReminders.md)。
- 两端离线循环音频、切歌、播放音量、停止定时、音频中断与输出设备变化处理。
- Watch 自动选择 iPhone 遥控或手表独立播放；手表曲库可明确选择本机内置或已下载声音，保持本机来源，直到用户选择恢复自动。遥控等待回执并设超时，连接变化不会让另一端自动开播。
- WatchConnectivity 队列补传；记录保存后回执、版本核对、重复合并与删除同步。
- 圆形／矩形表盘组件、iPhone 默认配置、系统添加指引及已有 `.watchface` 文件导入。
- Watch 趋势使用整行时间范围入口和全屏日／周／月列表，避免小滚轮难以点选。
- 壁纸预览、添加到照片、系统分享和隐私说明。

## 健康数据与预览

正常启动时不自动填入演示健康数据。无可读取记录时显示空状态，不推断用户拒绝读取权限。

仅 Debug 构建支持启动参数 `--demo-health`，显式开启带标识的健康演示。`--ui-testing` 使用独立的测试日记数据库；`--ui-reset` 只重置该测试库与测试偏好，不清空正常记录。

HRV 为 SDNN（毫秒）。个人基线为此前 7 个日历日内有效日均值的平均，至少需 3 个有效日；当天数据不进入基线。所有日期分组使用当前时区的日历边界。

## 运行检查

Mac 本地构建并打开应用（也已接入 Codex 的 Run 按钮）：

```sh
./script/build_and_run.sh --verify
```

账号凭据传输的真实 TLS 回环检查，只监听本机、不访问手机：

```sh
sh scripts/check_local_peer_connection.sh
```

Mac 播放器静默检查（使用真实解码器，不播放声音）：

```sh
sh scripts/check_mac_music_player.sh
```

公开音乐目录的真实 TLS 本机回环检查与封面离线缓存检查：

```sh
sh scripts/check_catalog_connection.sh
sh scripts/check_mac_artwork.sh
```

回环检查使用生产手机通信类和测试服务端，不替代真实 iPhone 与 Mac 的 Wi-Fi 验收。

文章缩略图的显示尺寸、内存上限、重复请求、修订与取消检查（复用已构建的共享包）：

```sh
sh scripts/check_article_thumbnails.sh
```

共享逻辑可在 Mac 直接测试：

```sh
CLANG_MODULE_CACHE_PATH="$PWD/build/clang-cache" \
SWIFTPM_MODULECACHE_OVERRIDE="$PWD/build/swift-cache" \
swift test --disable-sandbox --package-path Packages/QingkongCore \
  --scratch-path build/core-tests --cache-path build/package-cache
```

在具备 iOS 与 watchOS 运行环境的机器上：

```sh
xcodebuild -project Qingkong.xcodeproj -scheme Qingkong \
  -destination 'generic/platform=iOS' \
  -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO build
```

当前按项目验收约定使用 iPhone 17 与配对手表，不继续模拟器运行验收，也不在模拟器添加或操作小组件。上述通用设备命令只编译，不安装或运行；界面、HealthKit、后台音频和同步需在配对真机逐项确认。Debug 已启用 `ONLY_ACTIVE_ARCH`，Xcode 按选定设备选择架构。

即使缺少 watchOS 模拟器，也可以用已安装的 watchOS SDK 检查两种设备架构下的手表和组件源码：

```sh
sh scripts/check_watch_sources.sh
```

这项检查验证源码与 SDK 的兼容性，不替代资源打包、真机安装或运行验收。

本机音轨存储、损坏文件、取消／重试及撤回竞态检查：

```sh
sh scripts/check_audio_downloads.sh
```

使用真实 WAV 文件及隔离临时目录，不连接网络、不播放音频、不使用模拟器或设备。过期或已撤回的残留文件仍可在「已存文件」删除；完整自动缓存可通过「保留下载」改为主动下载。

团子解锁的实际本地保存、删除与重启检查：

```sh
sh scripts/check_companion_milestones.sh
```

使用隔离的本地心情数据库与练习文件，无需打开动作页面或运行模拟器。

知识库另有 [6 篇功能测试文章与三份测试歌单](Tests/Fixtures/PublicContent/README.md)，可检查实际客户端的离线缓存、修订与撤回：

```sh
sh scripts/check_content_library.sh
```

文章与审核字段明确为测试占位，测试响应在进程内拦截，不访问外网、不使用模拟器或真机；不会自动加入正式 App 或发布到内容后台。

三张测试专辑「晴天随行」「星光慢行」「微风来信」各 10 首，已核对全部真实 MP3 的大小和源 MD5，并生成客户端使用的 SHA256。使用本地媒体检查实际完整下载校验、离线重读与撤回清理：

```sh
sh scripts/check_test_playlists.sh [本地媒体目录]
```

默认目录为 `build/TestPlaylistMedia`，文件名为 `<track UUID>.mp3`；缺失时报错，不自动下载。检查不播放音频或操作设备，测试音源不代表正式发布授权。

可选的真实 HTTPS 下载检查需显式启用网络：

```sh
sh scripts/check_live_audio_download.sh --network
```

只选测试快照中最小的一首音轨，检查部分传输取消、重试、版本替换和重启校验。当前两次完整下载合计约 12.7 MB，另有一次中途取消的部分传输。文件保存在临时目录，网络偏好只在检查进程内覆盖；不播放声音，也不替代配对真机的断网、后台或路由验收。

## 真机签名

按用户确认，iPhone、Watch、表盘组件分别使用 `cn.geckoai.qingkong`、`cn.geckoai.qingkong.watchapp`、`cn.geckoai.qingkong.watchapp.widgets`，共享组为 `group.cn.geckoai.qingkong.shared`。表盘扩展按 Xcode 要求使用 Watch App 前缀；生成器已统一使用公司开发者 Team `9S743LF4C7`。新增源码时使用以下命令增量更新主工程，默认保留现有版本、签名和 scheme。目标配置变更仍需同步工程与生成器：

```sh
python3 scripts/generate_project.py
```

启用 HealthKit 与后台交付权限；Watch App 与组件扩展使用同一个 App Group。用户已授权配置开发签名、登记 iPhone 17 并进行真机安装；尚未授权上传或发布。账号中曾由 Xcode 自动创建的 `local.qingkong` 系列临时标识保留，当前工程已停止使用。

## 交付与发布状态

这是可继续开发和验收的原生版本，尚未上架。真实健康数据、Watch 配对同步、后台音频与表盘添加需要配对真机验收；音频当前为开发样本。详细状态见 [验收记录](docs/Verification.md)，后续顺序见 [开发计划](docs/Development.md)。

现有浏览器样稿 `../health-sleep-prototype` 保留原样。

## 介绍与隐私网站

对外名称统一为“小晴空”，内部工程名与持久化标识沿用 `Qingkong`。静态介绍页和隐私政策见 [website/README.md](website/README.md)，可直接托管 `website/` 目录。
