# 公共内容测试样本

`snapshot.json` 提供 6 篇中文文章、3 个文章分类，以及用户提供的 3 张专辑、30 首音轨，兼容客户端公共快照格式。快照整体标注 `testOnly`，不属于 App 资源，不会默认加载或自动发布。

## 测试文章

所有文章标题、摘要、正文与审核字段均明确标注测试用途；不含医学结论、真实审核人或正式发布时间。来源使用不可访问的 `example.invalid` 测试地址，文章封面为空，不请求远端图片。

每篇文章带 `testOnly:true`，客户端与磁盘缓存会保留这一标记并显示「功能测试 · 未专业审核」。用户于 2026-11-22 明确要求在后台添加文章和专辑测试后，线上测试内容经受保护接口单独创建；正式库 ID 与本夹具 ID 独立，文章参考链接改为实际产品介绍，测试发布不代表完成专业审核。发布记录见 `../../../artifacts/publish-xqk-test-content.json`。

| 文章 | 分类 | 主要用途 |
|---|---|---|
| 从安心首页开始 | 使用指南 | 短文、已读状态、阅读后入口 |
| 收藏一篇想再看的文章 | 阅读与收藏 | 收藏／取消收藏、正文关键字搜索 |
| 断网后再读一次 | 阅读与收藏 | 离线说明、上次成功检查时间 |
| 查看更新时间与修订 | 阅读与收藏 | 保持 ID 的修订、撤回与收藏清理 |
| 了解记录与隐私 | 使用指南 | 多段正文、同分类相关阅读 |
| 长文、标点与可访问性 | 排版检查 | 长标题、长文滚动、emoji、中英文标点与 HTML 纯文本 |

从项目根目录运行：

```sh
sh scripts/check_content_library.sh
```

该命令运行实际 `ContentLibrary`，使用隔离的本地目录、偏好和 URLSession。全部响应由进程内测试协议拦截，不访问外网，不启动内容服务，不使用模拟器或真机。初始快照取自 `snapshot.json`，修订和撤回版本在测试内生成。14 项检查覆盖默认服务地址、最新专辑与曲序、当前与最近专辑、本地播放偏好、实际刷新、磁盘缓存重读、收藏、断网、修订、撤回、冲突撤回响应保留有效缓存、旧版本及损坏响应、服务切换与请求载荷。撤回类型使用后台实际的 `articles`／`albums`／`tracks`。

测试快照中的 `review`、`publishedAt` 只是模拟客户端输入格式，不能用来证明专业审核或正式发布。此目录不属于 App 资源，不会被默认加载，也不会自动导入后台。若需要在后台查看草稿，仅选择编辑字段 `title`、`summary`、`body`、`category`、`coverURL`、`references`、`sortOrder` 保存；不得复制快照的审核和发布状态。临时 SQLite 验证已确认这条路径保存后为未审核草稿，公共列表为空。

## 用户测试歌单

| 专辑 | 来源 | 曲目数 |
|---|---|---|
| 晴天随行 | 第一份歌单 | 10 |
| 星光慢行 | 第二份歌单 | 10 |
| 微风来信 | 第三份歌单 | 10 |

保留附件原顺序、完整曲名与 Explicit 标记。歌曲及封面使用用户提供的 HTTPS 地址；“Sorry - Justin Bieber” 未提供曲目封面，沿用专辑封面。附件中的公司、创建人、部门等管理字段未带入公共快照。完整曲目表见 [歌单预览](../../../artifacts/test-playlists-preview.md)。

30 个完整 MP3 已下载至 `build/TestPlaylistMedia/<track UUID>.mp3`，共 256,735,401 字节。逐首实际检查确认：文件大小与附件一致；`digest` 按 `MD5:` 冒号后的 32 位十六进制值解析，30 首源 MD5 全部匹配；另计算 SHA256，供现有客户端文件完整性与缓存版本检查使用。AVFoundation 已确认全部可播放、读取实际时长并解码初始 PCM 帧，未实际播放声音。29 张曲目封面通过 HTTPS 响应和图片格式检查。

使用已下载的媒体检查实际下载管理：

```sh
sh scripts/check_test_playlists.sh
# 或指定包含 <track UUID>.mp3 的本地目录
sh scripts/check_test_playlists.sh /absolute/path/to/media
```

脚本不自动下载媒体；缺少本地目录或文件时报告缺失。6 项检查覆盖全部 30 首 MP3 的完整下载校验、离线状态、独立设备目录隔离、重构后的重新校验、撤回时保护正在使用的文件及释放后清理、删除与空间计数。检查使用临时目录，不访问网络、不播放音频、不运行模拟器或设备。媒体文件仅位于 build 目录，不加入 App。

另外可显式运行实际 HTTPS 下载链路：

```sh
sh scripts/check_live_audio_download.sh --network
```

此检查使用生产 `AudioDownloads.download()`、URLSession 下载回调和完整文件校验，只选择快照中最小的一首音轨，并限制单个文件不超过 20 MB。当前为 6,367,017 字节的 “Only The Young (Featured in Miss Americana) - Taylor Swift”；两次完整下载合计 12,734,034 字节，另有一次中途取消的部分传输。4 项检查覆盖部分文件不可离线及取消、重试完成、版本替换后重新下载、重新构造后校验及删除空间计数。文件目录隔离并在结束时清理；仅在进程内临时覆盖下载网络偏好，不修改 App 持久偏好。不带 `--network` 时直接退出，不编译或联网。

真实链路曾复现下载暂存文件缺少音频后缀导致 AVFoundation 拒绝完整 MP3，修复为保留 URL 或响应 MIME 对应的安全后缀后，4 项检查通过：`artifacts/test-live-audio-download-final.log`。上述 30 首本地文件检查仍为独立的 6 项，不包含真实网络请求。此处仅验证 Mac 当前网络下的 URLSession，不代表 iPhone／Watch 的物理断网、蜂窝切换、锁屏、后台或路由验收；不播放声音。

证据：`artifacts/test-client-tombstone-contract-final.log`、`artifacts/test-user-playlists-final.log`、`artifacts/test-playlist-assets.json`、`artifacts/check-test-playlist-digests.json`。将文章、专辑和曲目的允许编辑字段保存至临时 SQLite 后，共 39 条记录均为草稿，公共列表均为空，见 `artifacts/check-test-library.json`。

另外用独立临时库及回环 HTTP 服务检查了模拟发布、修订与连带撤回，再用生产 Swift 模型校验该服务的实际 JSON。4 项后台检查和 4 项跨语言检查通过，覆盖 12 条真实后台生成的三类撤回记录；测试结束后服务已关闭、数据库已移除。此处的非医学文章审核是临时测试中的模拟操作，不代表专业审核，也未向正式服务发布。证据见 `artifacts/check-backend-playlist-contract.json`、`artifacts/test-backend-playlist-contract.log`、`artifacts/test-swift-backend-playlist-contract.log`。

这些样本可用于开发联调，不能替代首批正式文章的专业审核、正式音频授权与有效期资料，也不能替代真机视觉、辅助功能、锁屏／后台／路由或配对 Watch 验收。音轨版权文本和有效期仅为明确标注的测试占位，不代表已获得正式发布授权。
