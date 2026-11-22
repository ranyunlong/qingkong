# 补开发交付与分端验收 · 2026-11-22

本轮补齐前次审计确认的三项代码缺口。83 个等权检查点现为 **77 完整覆盖、6 部分完成（92.8%）**；这是实现覆盖率，不是用户签收率。用户此前确认的 A01 保持通过，其他用户验收项不代为签收。

## 本次交付

| 缺口 | 交付行为 | 依据 |
|---|---|---|
| 文章图片离线 | 已读／收藏文章的正文和封面图片完整验证后写盘，重启离线可读；修订、撤回、切服务清理旧文件，迟到请求不复活旧图。下载失败明确显示不可用，不承诺未成功缓存的图片离线可用 | `ArticleImageCache.swift`、`ContentLibrary.swift`、`KnowledgeView.swift` |
| 更多表情和风景 | 眯眼微笑／晨光草地由首次心情解锁，眼里有光／月下湖畔由首次完成陪伴解锁；可在两端收藏查看、手机明信片选用；保留五档心情和四套主题。复用原来两个本机布尔标记，没有新增个人数据记录、好心情条件或连续打卡要求 | `Companion.swift`、`CompanionCollectionView.swift`、`MoodPostcardView.swift`、`WatchDumplingView.swift` |
| 健康来源和时间 | HRV 卡显示当日有效记录数、最近采样时间和全部实际来源；心率／血氧的数值、日期、来源取自同一条有效最新记录，无数据不造值 | `TodayView.swift` |

## 共享验证

| 检查 | 实际结果 | 日志 |
|---|---|---|
| 核心逻辑 | 116 项 Swift Testing＋2 项 XCTest，共118项通过 | `artifacts/test-core-completion-20261122.log` |
| 原内容缓存 | 15项通过，真实磁盘＋受控响应 | `artifacts/check-content-completion-20261122.log` |
| 正文／封面图片缓存 | 11项通过，覆盖重启离线、收藏、修订撤回、取消、切服务、晚到响应、损坏文件和容量／像素限制、匿名请求 | `artifacts/check-images-completion-20261122.log` |
| 解锁磁盘存储 | 4项通过，删除／重启保留、旧记录迁移、仅两个标记 | `artifacts/check-milestones-completion-20261122.log` |
| iPhone／Watch 真机目标 | Debug 无签名构建通过，包含既有随包组件的编译 | `artifacts/build-device-completion-20261122.log` |
| 独立静态复核 | 未发现可确定的缺陷；复核不是运行验收 | 本轮代理只读复核记录 |

## 手机端

环境为本轮专用 iPhone 17／iOS 26.5 模拟器，测试使用独立测试存储。健康来源检查使用明确标记的演示数据，没有向 HealthKit 写入数据。

| 检查 | 实际结果 | 证据 |
|---|---|---|
| 原生编译 | 本机 x86_64 验收包构建通过 | `artifacts/build-phone-testing-completion-native-20261122.log` |
| 首次心情与收藏 | 保存疲惫心情后，眯眼微笑可选择；晨光草地可选；明信片预览成功，可返回编辑 | `artifacts/test-phone-completion-native-20261122.log`、`artifacts/phone-completion-native-20261122.xcresult` |
| 首次完成陪伴与收藏 | 实际等待一分钟练习完成，跳过感受反馈；眼里有光与月下湖畔可选择，生成预览成功 | 同上；预览图见 `artifacts/phone-completion-attachments/manifest.json` |
| 健康来源和时间 | 关闭安心首页后，日均依据、最近采样和来源显示检查通过，截图已逐张查看 | `artifacts/test-health-ui-final-20261122.log`、`artifacts/phone-health-final-20261122.xcresult`、`artifacts/phone-health-final-attachments/manifest.json` |
| 手机小组件 | **跳过运行验收，交由用户在 TestFlight 验收**，本轮没有添加或操作模拟器小组件 | 当前修改版尚未上传新 TestFlight；历史版本不包含本轮修改 |

以上三项交互是分别通过，不是原始三项整组一次全绿。首次健康卡检查因测试点到开关所在行中部、没有关闭安心首页而失败；记录实际控件树后改点开关本身，先断言关闭，再单独重跑通过。没有为此修改产品的健康或开关逻辑。第一次验收包架构与 Intel Mac 不匹配，也不计作功能通过；失败记录均保留。收藏列表曾触发耗时类型检查，拆出独立行视图后手机和 Watch 构建通过。

仍待手机真机验收：真实健康／睡眠权限及历史、真实断网后的完整图文显示、锁屏／后台／耳机／来电／蜂窝／低空间、系统分享取消、照片保存、辅助功能与手机小组件。两台 iPhone 当前均 `unavailable`，未安装或操作真机，见 `artifacts/completion-physical-devices.json`。

## 手表端

手机验收环境关闭后，单独创建 Apple Watch Series 11 46mm／watchOS 26.5 模拟器，没有与测试手机配对，也没有使用健康演示值。

| 检查 | 实际结果 | 证据 |
|---|---|---|
| 独立编译／启动 | Watch scheme 构建、安装和启动成功 | `artifacts/build-watch-completion-20261122.log`、`artifacts/launch-watch-completion-20261122.log` |
| 页面入口 | 实际点开「心情团子 → 团子动作 → 表情与风景收藏」 | 本轮 Simulator 原生界面操作记录 |
| 两组收藏 | 实际滚动查看两款新表情与两处风景的灰色锁定预览，未解锁说明可读，第二组提示不要求记录感受 | `artifacts/watch-completion-collection-first.png`、`artifacts/watch-completion-collection-second.png` |
| 无数据状态 | 团子页显示心情待记录及健康空值，没有虚构健康记录 | `artifacts/watch-completion-home.png`、本轮界面观察 |

未将返回动作列表标为通过：最后一次返回操作期间工具报告界面被用户改变，随后观察到「陪伴回顾」，不能据此证明原定返回路径。未在 Watch 模拟器完成首次心情／完整练习解锁，规则和持久化使用共享验证证据，不替代 Watch 实际操作。

配对真机的同步、删除防复活、遥控回执、独立下载／断网播放、触感、通知和表盘仍待验收。只读查询显示 Watch 为 paired／available，但 `ddiServicesAvailable=false`、开发者模式状态 `unknown`；不能据此安装验收，也不推断用户没有开启开发者模式，见 `artifacts/completion-watch-details.json`。

## Web端

| 检查 | 实际结果 | 证据 |
|---|---|---|
| 后台回归 | macOS运行73项，72通过，1项Linux专用测试跳过；覆盖登录／CSRF、文章和专辑分区、发布修订撤回、来源列表、音乐识别、富文图片上传保存 | `artifacts/test-backend-completion-final-20261122.log` |
| 正式 HTTPS | 登录页与公共快照可访问；revision46，6篇测试文章、3专辑、30首歌曲 | `artifacts/completion-admin-login.html`、`artifacts/completion-public-snapshot.json` |
| 浏览器登录样式 | 实际 Safari 打开正式登录页，管理员、密码、登录按钮及隐私边界文字正常展示 | 本轮 Safari 界面观察 |
| 正式后台分区与歌曲表单 | 用户自行登录后，实际从文章切到专辑与音乐，按专辑显示曲目；新建歌曲依次为选择专辑、音乐文件链接、读取信息、可修改歌曲及文件／版权字段 | 本轮 Safari 原生界面操作；没有重复下载音乐或新增歌曲 |
| 正式图文编辑器 | 实际插入 HTTPS 森林图片、上传本地测试 PNG、设置部分正文粗体并填写一条标题＋URL 来源；保存后从列表重开，两张图片、粗体、来源和预览均保留 | 测试草稿 `b64bf23b-e73c-49e6-9c5e-d5d1bc154c94`；本轮 Safari 界面观察，详见 `artifacts/web-completion-observations-20261122.md` |
| 官网隐私同步 | 已备份旧文件并发布当前政策，实际 HTTPS SHA256 与本地一致 | `artifacts/deploy-privacy-completion-20261122.log`、`artifacts/check-privacy-live-completion-20261122.log` |

本轮没有修改服务端代码或重新部署容器。新增「[测试] 图文编辑验收 2026-11-22」作为未发布草稿并保留供检查，没有发布／撤回线上文章和专辑；公开目录仍为6篇文章／3张专辑／30首歌曲。浏览器实际显示后台全部为8篇文章（6发布、1历史撤回、1本轮草稿），4张专辑／31首歌曲包含历史撤回测试内容，不与公开目录混算。没有读取或输出真实管理员凭据。初次后台测试误用了缺少依赖的系统Python，改用已有依赖环境后73项正常运行，初次失败日志保留。

## 资源与交付边界

- 本次创建的手机 `47634032-3838-4624-858D-22A295317A01` 和手表 `D003871E-9D37-4F21-B25F-A66B7D3A2158` 均已关闭并删除。原来运行的 iPhone 17 已正常关闭，其数据保留；其余原有设备没有删除。清理后没有 Booted 设备，见 `artifacts/completion-devices-after.json`。
- 旧本地预览服务 `/private/tmp/qingkong-admin-preview.py` 已停止，正式远程服务保持运行。
- Web 验收结束后已点击退出登录，确认回到登录页，再关闭当前后台验收页面；工具观察到另一 Safari 起始页窗口，后台窗口已关闭。未操作用户的 Chrome，也没有继续关闭其他 Safari 页面。
- 本轮未提交代码、上传 TestFlight 或提交商店审核。保留全部已有未提交工作。
- 仍有6个部分交付检查点：18篇专业内容的正式审核与发布（影响3项）、正式音源／版权（1项）、云平台／OSS日志规则资料（1项）、商店隐私材料最终提交（1项）。这些不能用生成测试资料替代。详见 [审计](FeatureAudit-2026-11-22.md)。
