# 晴空 · Qingkong

按已认可的 **01「晴空」** 设计实现的 iPhone + Apple Watch 原生开发版。免费、免注册、无广告、无服务器。

## 打开项目

在 Xcode 打开 `Qingkong.xcodeproj`，选择 `Qingkong` 或 `QingkongWatch` scheme。最低 iOS 18 / watchOS 11，建议使用 Xcode 26 或更新版本体验系统悬浮导航。

工程包含 iOS App、独立 Watch App、WidgetKit 表盘组件扩展、原生服务测试、界面测试，以及本地 Swift Package `QingkongCore`。工程文件已生成，不依赖 XcodeGen 或第三方 Ruby 库。

若本机没有 watchOS 运行环境，可生成 **只用于 iPhone 预览** 的工程；源码与主工程相同，预览工程不内嵌 Watch：

```sh
python3 scripts/generate_project.py --phone-only
open QingkongPhonePreview.xcodeproj
```

主工程保留完整配对结构，不能用预览工程发布 Watch 版本。

## 已实现功能

- 原生「今日／趋势／心情／助眠」导航；iOS 26 系统悬浮标签栏和玻璃按钮，播放时出现迷你播放条，强调色跟随场景。
- 四套场景主题、原创五款心情表情；主动压力记录与应用内换景联动。
- SwiftData 心情日记、历史、删除；持久化待同步记录与删除墓碑。
- HealthKit 只读心率、血氧、SDNN HRV、心电图及波形。趋势不补零，基线不足明确展示。
- 默认开启、可关闭的本地放松提醒：HRV 明显下降后温和建议休息，限制频率并遵循系统专注规则；Watch 接手检测后，连接时交给 iPhone 通知并由系统选择显示位置，断连或探测超时由 Watch 本地通知。规则见 [放松提醒](docs/RelaxationReminders.md)。
- 两端离线循环音频、切歌、播放音量、停止定时、音频中断与输出设备变化处理。
- Watch 自动选择 iPhone 遥控或手表独立播放，无手动位置入口；断连后下次点播放才在可用设备开始，遥控等待回执并设超时。
- WatchConnectivity 队列补传；记录保存后回执、版本核对、重复合并与删除同步。
- 圆形／矩形表盘组件、iPhone 默认配置、系统添加指引及已有 `.watchface` 文件导入。
- Watch 趋势使用整行时间范围入口和全屏日／周／月列表，避免小滚轮难以点选。
- 壁纸预览、添加到照片、系统分享和隐私说明。

## 健康数据与预览

正常启动时不自动填入演示健康数据。无可读取记录时显示空状态，不推断用户拒绝读取权限。

仅 Debug 构建支持启动参数 `--demo-health`，显式开启带标识的健康演示。`--ui-testing` 使用独立的测试日记数据库；`--ui-reset` 只重置该测试库与测试偏好，不清空正常记录。

HRV 为 SDNN（毫秒）。个人基线为此前 7 个日历日内有效日均值的平均，至少需 3 个有效日；当天数据不进入基线。所有日期分组使用当前时区的日历边界。

## 运行检查

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
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO build
```

在 Xcode 选择一个 iPhone 模拟器，执行 Product → Test 运行 `QingkongUITests`。缺少 watchOS 运行环境时，使用上面的 PhonePreview 工程测试。Debug 已启用 `ONLY_ACTIVE_ARCH`，Xcode 按选定设备选择架构；不要在共享工程里固定 Intel 模拟器的 `x86_64` 架构。

即使缺少 watchOS 模拟器，也可以用已安装的 watchOS SDK 检查两种设备架构下的手表和组件源码：

```sh
sh scripts/check_watch_sources.sh
```

这项检查验证源码与 SDK 的兼容性，不替代资源打包、真机安装或运行验收。

## 真机签名

按用户确认，iPhone、Watch、表盘组件分别使用 `cn.geckoai.qingkong`、`cn.geckoai.qingkong.watchapp`、`cn.geckoai.qingkong.watchapp.widgets`，共享组为 `group.cn.geckoai.qingkong.shared`。表盘扩展按 Xcode 要求使用 Watch App 前缀；生成器已统一使用公司开发者 Team `9S743LF4C7`。更改目标配置后重新生成主工程：

```sh
python3 scripts/generate_project.py
```

启用 HealthKit 与后台交付权限；Watch App 与组件扩展使用同一个 App Group。用户已授权配置开发签名、登记 iPhone 17 并进行真机安装；尚未授权上传或发布。账号中曾由 Xcode 自动创建的 `local.qingkong` 系列临时标识保留，当前工程已停止使用。

## 交付与发布状态

这是可继续开发和验收的原生版本，尚未上架。真实健康数据、Watch 配对同步、后台音频与表盘添加需要配对真机验收；音频当前为开发样本。详细状态见 [验收记录](docs/Verification.md)，后续顺序见 [开发计划](docs/Development.md)。

现有浏览器样稿 `../health-sleep-prototype` 保留原样。
