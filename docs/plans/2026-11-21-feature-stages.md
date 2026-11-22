# 功能分期实施与验收跟踪

依据 `../FeatureOverview.md`，2026-11-21 开始。当前工作区已有的健康、同步、组件和官网修改继续保留，不提交；部署依据用户后续授权执行，不自动操作模拟器小组件。

**最新完整审计（2026-11-22）**：[逐项报告](../FeatureAudit-2026-11-22.md)。83 点中完整覆盖 77、部分 6；补齐健康卡来源／时间、图文离线缓存、两表情两风景收藏。共享核心 118 项通过、macOS 后台 72 通过／1 项 Linux 专用跳过、原生内容 15 项与图片磁盘 11 项、解锁磁盘 4 项通过。分端结果及资源清理见 [本轮交付记录](../PlatformAcceptance-2026-11-22.md)。当前服务 revision 46，6 篇测试文章、3 张专辑、30 首歌曲；地址已固定，无内容服务设置入口。下文保留各轮历史记录，其中旧测试数量、部署前状态及手动填写地址的描述不代表当前版本；用户明确通过的是 A01，其余见 [手动验收清单](../AcceptanceChecklist.md)。

## 实施顺序

1. 第一轮：共享放松会话规则和本地持久化；iPhone／Watch 练习入口；安心首页；时间线及记录删除。验证暂停／恢复／退出／反馈、旧数据兼容、两端编译。
2. 第二轮：标准库 Python + SQLite 公共内容后台；受保护管理、审核发布／修订／撤回；iPhone 分类搜索收藏与离线缓存。验证草稿隔离、管理权限、撤回同步和本地数据边界。
3. 第三轮：后台专辑与外部 HTTPS 音源；iPhone 在线播放、完整下载校验、网络和空间策略；保留原播放器定时、锁屏控制及 Watch 回执遥控。验证版本替换、未完成文件不可离线、失败重试。
4. 第四轮：可复用睡前方案、可选生活标签、本地周回顾、单独授权睡眠读取。验证无数据不补值、记录可删除、截止时间不漂移。
5. 后续体验：温和团子动作和用户主动预览的明信片；Watch 线上音轨下载需独立验证，不把手机缓存当成手表缓存。

## 已知外部验收条件

- 专业文章：首批 15～20 篇只能准备待审稿，不能伪造专业审核后发布。
- 线上媒体：用户已提供三份测试歌单，30 首真实 HTTPS 音源已通过完整文件、源 MD5 和客户端校验；正式版权、有效期及发布资料仍需补齐。
- 部署：用户已授权 SSH，公共后端于 2026-11-22 部署到 `https://xqk.geckoai.cn`，镜像已推送至用户指定阿里云仓库；远端启动、HTTPS、管理登录及实际客户端文章发布／修订／撤回同步通过。服务商与代理配置已核对，云平台及 OSS 自身日志保留仍须确认。
- 真机：HealthKit 权限、Watch 配对、锁屏／音频路由、空间不足、系统组件仍需实测。

## 状态

| 阶段 | 实现 | 自动验证 | 外部验收 |
|---|---|---|---|
| 第一轮 | 开发初版完成：安心首页、两端练习、反馈、可删除时间线 | 共享规则及本地存储用例通过；两端构建通过 | 配对真机、减少动态效果与引导体验待验收 |
| 第二轮 | 后台与知识库初版完成；另备 18 篇专业待审稿；用户授权的 6 篇非医学功能测试文章已明确测试发布 | 20 项本机后台用例、11 项实际客户端缓存检查通过；实际 HTTPS 登录、拉取／缓存及 5 阶段文章发布／修订／撤回同步通过 | 首批 15～20 篇专业审核文章和用户手动验收待完成 |
| 第三轮 | 专辑、在线播放、完整下载、缓存管理与 Watch 遥控兼容初版完成；三张测试专辑共 30 首 | 30 首真实 MP3 校验、本机管理与实际 HTTPS 下载检查通过；另补 6 阶段线上曲库联调，文件替换和专辑连带撤回均使旧缓存失效 | 正式版权／发布资料、真机网络中断、空间不足、锁屏与配对设备待验收 |
| 第四轮 | 睡前方案、生活标签、本地周回顾、单独授权睡眠读取初版完成 | 标签兼容、睡眠裁剪去重／DST、真实夜数平均与定时规则通过 | HealthKit 真实权限与历史周、睡前重试流程待真机验收 |
| 后续体验 | 开发初版完成：五款团子的招呼／点头／摇摆、温和解锁、明信片预览／主动分享；Watch 独立前台下载与离线播放 | 共享核心 105 项、音轨文件检查 14 项、真实存储解锁检查 4 项通过；两端构建通过 | 动作、分享、大字号、手表联网／独立离线／后台播放与配对同步仍待真机验收 |

实际命令结果和未通过事项记录到 `../Verification.md`；此表不把代码存在等同于验收通过。


## 本轮交付边界与证据

- 共享包：103 项 Swift Testing 与 2 项 XCTest 共 105 项通过，最新证据 `../../artifacts/test-core-staging-final.log`；后台：14 项测试通过。音轨真实文件检查 14 项通过，最新证据 `../../artifacts/test-download-staging-final.log`；真实存储解锁检查 4 项通过，证据 `../../artifacts/test-companion-milestones-final.log`。本轮早期还执行了 4 项 iPhone 模拟器服务测试并通过，随后依据项目真机约定停止模拟器运行验收，未添加或操作小组件。这些均不等同于真机行为验收。
- 当前最终设备构建日志为 `../../artifacts/build-download-staging-final.log`，覆盖 iPhone、Watch 及两端组件；完整命令与限制见验收记录。
- 评审修复：版权信息更新和播放中到期、历史周按周读取和授权后加载、文章后放松入口、Watch 被动状态失败保留遥控上下文。睡前重试沿用同一记录与方案 ID，避免重复插入。
- 公共服务已于 2026-11-22 部署，App 仍需在设置中填写实际服务地址；未公开草稿或示例音轨，未提交、归档或上传 TestFlight。
- 工程生成器现默认增量保留配置。此前全量生成覆盖过工程，已依据开发前 PIF 恢复产品构建号 13、显示名及分类；原 iPhone scheme 的未提交手动差异未找到精确备份，当前为仓库版本，需复核。详见验收记录。

## 后续体验补充与当前边界

- 招呼始终可用，首次主动心情解锁点头、首次练习解锁摇摆；可重播并归静，减少动态效果时保持静态。仅在本机保存两个解锁标记，删除或漏记不收回。
- 解锁标记在记录成功保存时立即持久化，旧记录在加载时迁移，不依赖打开动作页面。线上曲目封面按音轨／专辑元数据展示，同步到 Watch；缺失时使用中性占位，锁屏异步加载隔离旧结果。
- 两端“已存文件”入口按实际文件索引管理过期、撤回和旧版本残留，删除失败保留索引；播放中的文件受保护。iPhone 自动缓存可直接“保留下载”，复用已校验文件；撤回后的迟到恢复校验不能改变不可用状态。
- Watch 从配对手机同步公共服务地址后自行获取目录、下载和验证文件；自己的完整文件才可离线。支持进度、取消、重试、删除与空间提示，默认避开蜂窝和昂贵网络。系统可能经手机代理，不能据此承诺识别实际物理 Wi-Fi。
- 本版仅前台主动下载：离开曲库或退后台中断，可手动重试。UUID 校验保护避免取消、重试和下架后的旧结果提交。明确选择本机声音后保持本机来源，可手动恢复自动选择；旧手机回执不能继续旧页面的播放操作。
- 待审包见 `../../ContentService/EDITORIAL.md`。独立结构检查确认 18 题覆盖、正文必要章节、28 个机构来源链接和全量未审核状态；这不是专业审核。
- 只读设备查询显示 iPhone 17、iPhone 13 mini 和 Watch Series 11 均为 unavailable，未安装或运行。当前无法完成配对真机验收。

达到各阶段的全部完成标准仍依赖上表外部验收；实现和自动验证完成不等于阶段全面验收通过。

## 2026-11-22 用户手动验收准备（最新）

用户明确要求启动模拟器并在后台添加测试文章、专辑。已打开 iPhone 17／iOS 26.5 模拟器、安装当前版本并通过 App 界面保存服务地址。后台已按授权发布 6 篇功能测试文章、3 张测试专辑与 30 首曲目，快照 revision 39；未修改正式待审稿。测试发布独立记录 `publish_test` 和 `testOnly:true`，客户端显示「功能测试 · 未专业审核」，不填写虚假的专业审核资料。用户手动验收清单为 `../AcceptanceChecklist.md`，所有结果保留待验收。

最新共享核心 106 项（104 Swift Testing＋2 XCTest）、后台 20 项、实际客户端缓存 11 项通过；iPhone／Watch／组件设备构建与 iPhone 模拟器构建通过。真实客户端直接通过默认 URLSession 获取线上 6／3／30 条内容，临时磁盘缓存保留测试标记。模拟器实际打开文章列表与详情，已观察测试状态；没有自动添加或操作组件。详细证据见 `../Verification.md` 最新章节。

只读核对已补齐阿里云 ECS 与 Nginx 日志配置说明：每日轮转、最多 52 份历史归档、空日志不轮转，无固定天数上限；不读取请求日志，不改共享策略。App、官网政策源码与商店材料已更新，官网政策尚未发布。云平台和测试 OSS 桶日志保留仍待确认。

本次设备查询显示 Watch 已可发现，但开发者模式关闭、调试服务不可用；iPhone 仍 unavailable。模拟器仅用于本次用户交互验收，真实健康、后台音频、通知及配对设备完成标准仍待真机证据。

随后通过独立临时文章完成真实 HTTPS 管理操作与生产 `ContentLibrary.refresh()` 的 5 阶段联调：草稿隔离、首次测试发布、未发布修订隔离、重发保留收藏／已读、撤回清除列表与磁盘正文均通过，撤回记录保留。临时文章已撤回，公共目录为 revision 42，仍有 6 篇文章、3 张专辑和 30 首曲目。未操作用户模拟器或修改现有验收样本；证据 `../../artifacts/check-xqk-live-revisions.json`。

再补独立临时专辑／音轨的 6 阶段真实 HTTPS 联调，由生产 `ContentLibrary` 与 `AudioDownloads` 获取发布目录并下载两个真实 MP3，共 12,964,369 字节。文件替换后的旧缓存停用与清理、新文件完整校验、专辑撤回连带移除音轨及缓存均通过；临时内容已撤回，公共目录 revision 46，仍为 6／3／30，未操作模拟器。证据 `../../artifacts/check-xqk-live-albums.json`。

官网隐私页旧有“无后端”说明已于 2026-11-22 更新发布，公网与核对稿一致，首页及后端保持正常；未把云平台／媒体桶日志未知项写成已确认。证据 `../../artifacts/check-xqk-privacy-policy-live.json`。重新查询真机时 iPhone 仍 unavailable，Watch 虽 available／paired，但开发者模式关闭、DDI 不可用，尚不能验收。

## 2026-11-22 测试文章联调

用户允许生成测试文章，新增 `../../Tests/Fixtures/PublicContent/snapshot.json`：6 篇非医学功能测试文案、3 个分类，覆盖长标题／长文、搜索、收藏、修订和撤回；随后合并三份测试歌单。占位审核信息与来源明确标注测试用途，不进入正式 App 资源或服务。该授权用于联调样本，不视为已完成正式专业审核。

`sh scripts/check_content_library.sh` 的 10 项检查通过，实际运行客户端 `ContentLibrary`，使用临时磁盘缓存与进程内响应，覆盖重启重读、断网、修订、撤回防复活、损坏响应和服务切换。合并歌单后的证据为 `../../artifacts/test-content-library-playlists-final.log`。临时 SQLite 保存验证确认 6 篇文章、3 张专辑和 30 首曲目共 39 条均为草稿，三个公共列表均为空：`../../artifacts/check-test-library.json`。配对设备仍离线；专业审核、正式版权／部署资料和真机验收仍未完成。

测试隔离所需的缓存目录和 URLSession 可注入，默认生产行为保持不变。修改后共享核心 104 项通过，iPhone／Watch／两端组件无签名构建通过，Watch 两种设备架构检查通过：`../../artifacts/test-core-test-articles-final.log`、`../../artifacts/build-test-articles-final.log`、`../../artifacts/check-watch-test-articles-final.log`。

## 2026-11-22 三份测试歌单与源摘要核对

三份用户附件按原顺序整理为「晴天随行」「星光慢行」「微风来信」，各 10 首；曲名和 Explicit 标记保留。快照见 `../../Tests/Fixtures/PublicContent/snapshot.json`，预览见 `../../artifacts/test-playlists-preview.md`。原公司、创建人、部门等管理字段未带入。

已实际完整下载 30 个 MP3，共 256,735,401 字节；30 首大小均与附件相符。按用户说明，`digest` 为 `MD5:<32 hex>`，取冒号后的值逐首核对，30 首全部匹配，并另外生成客户端所需 SHA256。AVFoundation 已读取实际时长、确认可播放并解码初始 PCM 帧；29 张曲目封面通过 HTTPS 和图片格式检查，一首缺失封面使用专辑后备。证据为 `../../artifacts/test-playlist-assets.json`、`../../artifacts/check-test-playlist-digests.json`、`../../artifacts/test-playlist-downloads.log` 和 `../../artifacts/test-playlist-audio-probe.log`。

`sh scripts/check_test_playlists.sh` 的 6 项检查通过，覆盖全部真实 MP3 在实际下载管理中的完整校验、离线可用、独立设备目录隔离、重构后重新校验、撤回保护与清理、删除与空间统计：`../../artifacts/test-user-playlists-final.log`。连同文章缓存检查，本次共 16 项本机检查通过；没有播放声音或操作设备。音轨仅用于本地测试，不自动加载到 App、不发布到公共服务；正式授权、部署和配对真机验收仍未完成。

## 2026-11-22 后台撤回格式联调修复

核对后台实际 JSON 时发现，后台撤回类型为复数 `articles`／`albums`／`tracks`，Swift 快照冲突校验却只识别单数，旧测试也使用单数。已先复现三种冲突仍被接受，以及实际客户端错误覆盖有效缓存的问题，再修复为识别后台格式并兼容早期单数缓存。合法撤回仍正常同步；同时包含同一内容的撤回与可见正文时，整个响应被拒绝，保留上次有效缓存。

新增核心三类参数化回归及实际缓存回归后，共享核心 105 项、客户端缓存 11 项通过。另以临时 SQLite 和回环 HTTP 服务模拟 39 条测试内容的草稿、发布、修订、文章撤回及专辑连带撤回，4 项后台检查和 4 项生产 Swift 模型跨语言检查通过；12 条实际后台撤回记录均匹配契约。模拟审核仅用于非医学功能测试，临时服务已关闭、数据库已移除，未向正式服务发布。证据 `../../artifacts/test-tombstone-contract-before.log`、`../../artifacts/test-client-tombstone-contract-before.log`、`../../artifacts/test-tombstone-contract-final.log`、`../../artifacts/test-client-tombstone-contract-final.log`、`../../artifacts/check-backend-playlist-contract.json`、`../../artifacts/test-swift-backend-playlist-contract.log`。

iPhone、Watch 和两端组件通用设备无签名构建通过：`../../artifacts/build-tombstone-contract-final.log`。未运行模拟器或操作设备；专业审核、正式授权／部署和配对真机验收仍待完成。

## 2026-11-22 实际 HTTPS 下载链路修复

通过生产 `AudioDownloads.download()` 和 URLSession 实际下载用户提供的最小测试音轨，复现完整 MP3 的大小与摘要通过后仍被 AVFoundation 拒绝。原因是下载回调把临时文件移动为无扩展名 UUID，旧本地检查使用 `.mp3` 文件而未覆盖此路径。同一文件对照确认，无后缀时不可播放、保留 `.mp3` 时可播放。现按音源 URL 或响应 MIME 保留安全后缀，正式缓存也保留已推导的格式信息；完整性和版本规则保持不变。

新增可选命令 `sh scripts/check_live_audio_download.sh --network`，只对一首 6,367,017 字节测试音轨进行两次完整下载及一次部分传输取消。4 项实际网络检查通过，覆盖取消、重试、版本替换、重构后重新校验和删除；临时文件与仅进程有效的网络偏好覆盖在结束时清理。证据 `../../artifacts/test-live-audio-download-before.log`、`../../artifacts/test-audio-staging-probe.log`、`../../artifacts/test-live-audio-download-final.log`。

修复后共享核心 105 项、下载文件 14 项和全部 30 首 MP3 的 6 项本地管理检查通过；iPhone／Watch／两端组件无签名设备构建及 Watch 两种设备架构源码检查通过。证据 `../../artifacts/test-core-staging-final.log`、`../../artifacts/test-download-staging-final.log`、`../../artifacts/test-playlists-staging-final.log`、`../../artifacts/build-download-staging-final.log`、`../../artifacts/check-watch-staging-final.log`。实际联网仅使用 Mac 当前网络，不播放声音、不运行模拟器或操作设备；真机断网、蜂窝、后台和路由行为仍未验收。正式服务未部署，专业审核、正式授权及配对设备完成标准仍待达成。

## 2026-11-22 用户自行部署的 Docker 包

已按用户的服务器和 `https://xqk.geckoai.cn` 准备 `../../compose.yaml`、镜像、私密凭据生成、Nginx 片段及 `../../ContentService/DEPLOYMENT.md`。保留 `/api/v1/...` 原路径，管理页面还需代理 `/admin` 与 `/admin/`。后端为 Python 标准库，SQLite 使用持久化命名卷，无需另部署数据库；首次启动为空库，不自动导入或发布测试文章和歌单。

18 项后台用例通过；本地镜像构建、5 项隔离 Compose 运行检查及 2 项配置命令检查通过。已实测管理员登录、草稿隔离、容器重建后的数据／revision 保留、会话失效、停机备份及 Nginx 语法；未实测备份恢复。证据见 `../../artifacts/test-docker-deployment-final.log`、`../../artifacts/build-content-docker.log`、`../../artifacts/test-content-compose-runtime.log`、`../../artifacts/test-content-package-commands.log`。

交付压缩包为 `../../artifacts/qingkong-content-deploy.tar.gz`，不含真实凭据、数据库或媒体。所有容器验证在本机隔离项目进行，测试容器和数据卷已清理；没有访问或部署用户服务器。远端部署和 HTTPS／客户端联调由后续实际结果确认，专业审核、正式音频授权及配对真机验收仍待完成。

## 2026-11-22 SSH 授权部署与镜像发布

用户授权 SSH 部署后，已将公共后端部署到 `xqk.geckoai.cn` 的 `/opt/qingkong-content`。镜像发布至 `registry.cn-hangzhou.aliyuncs.com/geckoai/qingkong-content:20261122-096642645c03`，服务器拉取后健康检查通过；实际 amd64 镜像摘要匹配发布结果，SQLite 完整性检查正常，数据位于持久化命名卷。Compose 现在支持 `QINGKONG_CONTENT_IMAGE` 版本选择，更新说明和部署包已同步。

原 Nginx 配置已备份，配置检查通过后平滑接入 `/api/` 和管理入口。真实 HTTPS 的 5 个公共接口、匿名管理拒绝、实际管理员登录／退出和 Secure Cookie 均通过；原网站首页字节一致，未修改其他站点或容器。当前公共目录 revision 为 0，文章、专辑和音轨均为空；没有导入或发布测试资料。详细证据与镜像摘要见 `../Verification.md` 最新部署记录。

远端部署这一外部条件已补齐；实际客户端发布／修订／撤回联调、专业审核、正式音频授权、代理／OSS 日志资料及配对真机验收仍未完成，全部阶段完成标准尚未达成。

## 2026-11-22 网页登录来源策略修复

用户报告网页 CSRF 误拒绝后，复现 `no-referrer` 导致表单 Origin 为 `null` 的冲突，改为 `same-origin`，保留 token 与严格来源校验。新增表单回归先失败后通过，后台共 19 项通过；增加 `null` 来源拒绝检查。修复镜像 `20261122-2c006d421037` 已推送并上线，实际 HTTPS 表单登录／退出和远端健康复核通过，账号密码与公共内容保持不变。浏览器工具不可用，未进行真实浏览器 UI 点击；完整证据见 `../Verification.md` 最新章节。
