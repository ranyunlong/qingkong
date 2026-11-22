# 公共内容 JSON 契约 v1

服务只管理公共内容，不接收健康、心情、日记、用户账号或分析事件。音频由运营方已有长期 HTTPS 地址提供，不上传或托管音频。公共文章配图支持管理员上传，也支持运营方提供长期 HTTPS 图片地址。

## 公共读取

所有公共读取免登录。公共 JSON 接口响应 UTF-8 JSON，`Cache-Control: no-store`；公共配图读取返回图片二进制并允许缓存。公共内容 JSON 不返回草稿、审核中内容、版本历史或管理员会话。配图上传后即可公开读取，不受文章草稿、审核或发布状态控制。

| 方法与路径 | 结果 |
| --- | --- |
| `GET /api/v1/snapshot` | 完整已发布快照，含墓碑；客户端推荐使用 |
| `GET /api/public/snapshot` | 同上，兼容别名 |
| `GET /api/v1/articles` | `{revision,items:[Article]}` |
| `GET /api/v1/articles?category=分类` | 该分类的已发布文章，分类需 URL 编码 |
| `GET /api/v1/articles/{id}` | 单个已发布 Article，不存在／草稿／撤回返回 404 |
| `GET /api/v1/categories` | `{revision,categories:[String]}`，仅公开文章使用的分类 |
| `GET /api/v1/albums`、`/api/v1/tracks` | `{revision,items:[Album或Track]}` |
| `GET /api/v1/albums/{id}`、`/api/v1/tracks/{id}` | 单个已发布内容；不存在／下架返回 404 |
| `GET /api/v1/images/{sha256}.jpg`、`/api/v1/images/{sha256}.png` | 已上传的公共文章配图二进制；不存在返回 404，含图片 Content-Type、`Cache-Control: public, max-age=31536000, immutable` 与 `X-Content-Type-Options: nosniff` |

快照结构（以下是空库实际结构）：

```json
{"schemaVersion":1,"revision":0,"generatedAt":"2026-11-21T00:00:00Z","articles":[],"albums":[],"tracks":[],"tombstones":[]}
```

`revision` 为 Int64 兼容的递增全局整数；发布、撤回及版权到期改变公共状态时增加。保存草稿／审核及上传配图不改变公共 revision。`generatedAt` 是服务生成响应时间，并非文章更新时间。同一快照来自数据库的一次串行读取／事务。全局 revision 的连续性以当前数据库为准，不能用它推断两条内容的因果或最新审核情况。

所有 `id` 为稳定 UUID 字符串，文件地址变化不会改变音轨 ID。所有日期均为 UTC ISO8601，固定 `yyyy-MM-dd'T'HH:mm:ss'Z'`，无毫秒。可空字段以 `null` 输出。数值 `sortOrder` 越小越靠前，相同则以 ID 排序。`publishedAt` 为当前在线发布序列的首次发布时间，撤回后重新发布以新的时间开始；`updatedAt` 为当前已发布版本发布时间。

| Article 字段 | 类型与含义 |
| --- | --- |
| `id`, `title`, `summary`, `body`, `category` | String；正文为纯文本，客户端不可直接作为 HTML 执行 |
| `bodyHTML` | String?，可选的服务端白名单清洗后 HTML；旧内容可缺省，`body` 始终保留纯文本兼容 |
| `coverURL` | String?，长期 HTTPS 图片地址 |
| `references` | `[{title:String,url:String}]`，至少一条经运营者核实的来源 |
| `review` | `{reviewer:String,credentials:String,reviewedAt:String}`，专业审核声明 |
| `updatedAt`, `publishedAt` | UTC 日期字符串 |
| `revision`, `sortOrder` | Int |

| Album 字段 | 类型与含义 |
| --- | --- |
| `id`, `title`, `summary` | String |
| `coverURL` | String? |
| `trackIDs` | `[String]`，按已发布音轨排序计算；不含下架／授权到期音轨 |
| `updatedAt`, `publishedAt` | UTC 日期字符串 |
| `revision`, `sortOrder` | Int |

| Track 字段 | 类型与含义 |
| --- | --- |
| `id`, `title`, `summary`, `albumID`, `audioURL`, `fileVersion` | String；audioURL 为长期 HTTPS；fileVersion 与稳定 id 独立 |
| `coverURL` | String? |
| `durationSeconds` | Double，大于 0，最多 86400 |
| `byteSize` | Int64，大于 0，原文件准确字节数 |
| `sha256` | String，原文件 SHA256 的 64 位小写十六进制摘要 |
| `copyright` | `{owner:String,source:String,license:String,expiresAt:String?}`；expiresAt 为 UTC 日期或 null |
| `updatedAt`, `publishedAt` | UTC 日期字符串 |
| `revision`, `sortOrder` | Int |

`tombstones` 为 `[{id:String,kind:String,revision:Int,withdrawnAt:String}]`。kind 为 `articles`／`albums`／`tracks`。墓碑持久保留，重新发布对应 ID 后删除。专辑撤回会同时清除其已发布音轨并生成音轨墓碑；专辑重新上架不会自动重新发布曲目。

客户端在完整请求、解码和 schema 校验成功后原子替换公共目录，以**完整 ID 集合**处理撤回，墓碑作为明确的撤回信息补充。移除已撤回文章的可读缓存，移除／停止提供已撤回音轨与过时版本的下载文件和播放入口；本地收藏可以保留 ID 并提示内容不可用，不得继续显示旧正文。失败时保留旧缓存并说明上次成功同步时间，不把失败当成空目录。音轨仅在文件完整写入、`byteSize` 和 `sha256` 均验证通过后标记离线可用。运营者提供的地址可访问性、文件真实性及版权仍需上线前实测。

## 受保护管理接口

后台网页 `/admin/login`、文章分区 `/admin/articles`、音乐分区 `/admin/music`、`/admin/edit?kind=articles&id=UUID`；`/admin` 兼容文章入口。音乐按专辑列出歌曲，新建歌曲先选择专辑，再粘贴链接读取文件信息。所有管理 API 使用同一个 Cookie 会话，没有公共默认凭据，拒绝匿名访问（401）。管理写操作必须同时带登录 Cookie 与 `X-CSRF-Token`，若带 `Origin` 则须与当前服务来源一致，校验失败 403；参数无效 400，不存在 404。未知路径 404。错误体为 `{"error":"说明"}`。不支持 DELETE；内容通过撤回保留审计历史。

1. `GET /admin/login` 返回登录表单、预登录 `qk_admin` Cookie 以及隐藏 `csrf` 字段。
2. `POST /admin/login` 支持 JSON／表单：`{username,password,csrf}`，也可用 CSRF 请求头。登录成功 303 到 `/admin`，并轮换 Cookie；错误 401，15 分钟五次失败后 429。
3. `GET /admin/api/session` 返回 `{csrfToken,username}`，后续写请求在头部带 `X-CSRF-Token`。
4. `POST /admin/logout` 带 CSRF，立即销毁会话并 303 到登录页。

| 管理路径 | 功能 |
| --- | --- |
| `GET /admin/api/content` | `{items:[AdminContent]}`，仅后台可查看草稿 |
| `GET /admin/api/content/{kind}/{id}` | AdminContent 加 `history:[{historyID,operation,actor,createdAt}]` |
| `POST /admin/api/media/inspect` | `{url:String}`：识别公开 HTTPS 音频；200 返回文件信息，失败 400；不写数据库 |
| `POST /admin/api/images` | 原始 JPEG／PNG／WebP 图片二进制；201 返回 `{url,width,height,byteSize}`，不修改公共 revision、不保存或发布文章 |
| `POST /admin/api/content/{kind}` | 创建草稿，201；提交编辑字段 |
| `POST /admin/api/content/{kind}/{id}` | 替换草稿，200；清除本次文章审核，线上版本保持 |
| `POST /admin/api/content/articles/{id}/submit` | `{}`：草稿提交审核 |
| `POST /admin/api/content/articles/{id}/review` | `{reviewer,credentials,confirmed:true}`：记录实际完成的专业审核；必须已提交且来源齐备 |
| `POST /admin/api/content/{kind}/{id}/publish` | `{}`：明确发布。文章必须审核通过；音轨须所属专辑已发布且版权有效 |
| `POST /admin/api/content/articles/{id}/publish_test` | `{}`：明确发布非医学功能测试文章。要求标题以 `[测试]`、正文以 `【仅供功能测试】` 开头且有来源；生成 `testOnly:true` 及明确“未专业审核”的发布记录，历史操作为 `publish_test`。普通文章不能使用此入口 |
| `POST /admin/api/content/{kind}/{id}/withdraw` | `{}`：撤回；专辑同时撤回当前发布曲目 |
| `POST /admin/api/content/{kind}/{id}/restore` | `{historyID:Int}`：恢复为草稿，文章审核清空，线上版保持当前状态 |

AdminContent 为 `{id,kind,draft:编辑字段,published:公开字段或null,status,updatedAt}`。状态为 `draft`／`in_review`／`reviewed`／`published`／`withdrawn`。`status=draft` 可以仍有 `published`：代表正在修订线上内容。

公开文章的可选字段 `testOnly:true` 表示功能测试文案，此时 `review` 只保留明确标注未专业审核的测试发布信息。客户端须以测试状态展示；缺少该字段的旧快照继续兼容。编辑与历史恢复仍生成草稿，不能把测试发布记录当成正式专业审核。

编辑字段：文章 `title,summary,body,bodyHTML,category,coverURL,sortOrder,references`；专辑 `title,summary,coverURL,sortOrder`；音轨 `title,summary,coverURL,sortOrder,albumID,audioURL,durationSeconds,fileVersion,byteSize,sha256,copyright`。summary／coverURL／sortOrder 可省略。只允许这些字段，未知字段拒绝，`id`、审核时间、发布时间、revision 均由服务生成。音轨的版权来源为可追溯文字，不要求 URL；媒体相关字段完整才能保存。

`bodyHTML` 可省略或为 `null`。非空时服务端清洗 HTML，并从清洗后的内容派生 `body`，不信任客户端同时提交的纯文本；未提供或为空时继续按原契约校验并保存 `body`。旧纯文本文章无需迁移。允许的标签为 `p,br,h2,h3,strong,b,em,i,u,s,ul,ol,li,blockquote,a,img`；`div` 归一为 `p`、`h1` 归一为 `h2`，链接只保留通过校验的 HTTPS `href`。脚本、样式、事件属性及其他嵌入内容不会保留。`img` 的 `src` 必须为通过校验的 HTTPS 栅格图片地址，拒绝 `.svg`／`.svgz` 路径、反斜线与控制字符；`alt` 最多 300 字符，缺省或超长时使用「正文图片」。可选 `width`、`height` 为不大于 10000 的正整数，每篇最多 30 张图片。派生的 `body` 保留图片 `alt`，显式空白 `alt` 使用「[图片]」占位，公共快照及详情继续提供纯文本兼容。手机客户端以原生图文控件按正文顺序展示，限制图片下载，不执行 HTML 或使用 WebView。

内容保存接口（`/admin/save`、`/admin/api/content/...`）请求上限 2 MiB，容纳中文表单的编码开销；图片上传单独限 10 MiB，登录、操作和文件识别仍限 256 KiB。文章纯文本最多 60000 字符、HTML 输入及清洗后结果最多 120000 字符，最多 5000 个标签和 40 层嵌套。标题 200、摘要 1000、分类 80，最多 30 条来源。来源标题最多 500 字符、链接最多 2048。参考来源页面改为逐条编辑，API 的 `references:[{title:String,url:String}]` 契约保持不变。链接拒绝临时签名参数，禁止嵌入凭据或内网 IP；服务端保存文章、来源和媒体目录本身不会请求外链，管理员明确调用文件识别接口时会下载音频。浏览器编辑／预览或手机显示文章图片时会向图片地址发起 GET，外部图片不会由服务端代取或上传到本地。

### 公共文章配图上传

`POST /admin/api/images` 的请求体为原始图片二进制，不是 JSON、表单或 multipart；`Content-Type` 仅接受 `image/jpeg`、`image/png`、`image/webp`。必须同时提供已登录 Cookie、`X-CSRF-Token` 和与当前服务同源的 `Origin`。图片上传必须用于所有读者可见的文章配图，不接收私人健康、心情或日记图片。

上传请求需提供准确的 `Content-Length`，不接受 `Transfer-Encoding`。本地 HTTP 开发环境按 HTTP Origin 校验，启用 Secure Cookie 的 HTTPS 部署按 HTTPS Origin 校验；返回的公共图片 `url` 始终为当前 Host 下的绝对 HTTPS 地址。

原始文件最多 10 MiB，像素总数最多 20000000，宽高各不超过 10000，仅接受静态图片，真实文件格式须与 Content-Type 一致。服务端通过 `Pillow==13.0.0` 解码并重新编码，去除 metadata，必要时按比例缩至最长边 2560；输出超过 8 MiB 时继续缩图，最终保存为不超过 8 MiB 的 JPEG 或 PNG。同一时间只处理一张上传图片，读取与处理共用约 25 秒期限，Linux 图片处理子进程地址空间上限为 384 MiB。文件写入 SQLite 数据库同级的 `uploads/` 目录，Docker 部署中位于持久化数据卷；备份与恢复必须同时保存数据库与图片目录。

成功以 201 返回 JSON 对象；格式无效、超限、超时或繁忙返回 400 和中文 `error`，匿名返回 401，CSRF／来源校验失败返回 403。认证与 CSRF／来源检查先于读取图片请求体。

| 字段 | 类型与含义 |
| --- | --- |
| `url` | String，处理后图片的绝对 HTTPS 地址，路径为 `/api/v1/images/{sha256}.jpg` 或 `.png` |
| `width`, `height` | Int，重新编码后的真实宽高 |
| `byteSize` | Int，保存后的真实文件字节数 |

上传不修改 revision、不创建或保存文章草稿、不提交审核、不自动发布文章。上传完成的图片立即可通过难以猜测的 SHA256 地址免登录读取；摘要 URL 不是访问权限，文章未发布或撤回也不会使已上传图片变为私有。运营者只应上传确认可公开且有权使用的配图。图片 GET 返回图片 Content-Type、`X-Content-Type-Options: nosniff` 和 `Cache-Control: public, max-age=31536000, immutable`，公共 JSON 仍使用 `Cache-Control: no-store`。

编辑器支持选择本地文件上传、填写 HTTPS 图片链接、粘贴 HTTPS 图片地址及粘贴剪贴板中的本地图片；上传响应的 `url` 或外部 HTTPS 地址写入清洗后的 `bodyHTML`。保存图片链接不会触发服务端远程下载；图片在编辑、预览及客户端展示时由浏览器或手机请求。

手机客户端单张图片下载最多 8 MiB，真实图片单边最多 20000、总像素最多 4000 万，显示时下采样至最长边 1600。只接受 JPEG、PNG、GIF、WebP、HEIC／HEIF 等受支持的栅格图片，校验响应类型和真实图片格式，拒绝 SVG。请求及重定向始终要求无凭据 HTTPS 地址，不携带 Cookie 或凭据，不使用持久缓存。加载中或失败时保留替代文字；无法安全解析的正文 HTML 整篇回退到 `body` 纯文本。

### 音乐文件识别

`POST /admin/api/media/inspect` 使用已登录 Cookie 和 `X-CSRF-Token`；通用 `csrf` 字段也可放在请求体。请求业务字段仅有 `url`，其他未知字段返回 400。认证、CSRF 和来源检查先于文件识别；匿名返回 401，CSRF／来源校验失败返回 403，均不会请求音频服务器。

成功返回以下对象，供编辑填入或修改歌曲表单：

| 字段 | 类型与来源 |
| --- | --- |
| `title` | String，内嵌标题；缺少时使用最终 URL 的文件名 |
| `summary` | String，内嵌 comment／description；缺少时为空字符串 |
| `durationSeconds` | Double，文件解析得到的真实时长，大于 0 |
| `byteSize` | Int，实际下载的完整文件字节数 |
| `sha256` | String，完整文件的 64 位小写 SHA256 |
| `fileVersion` | String，`sha256-` 加摘要前 12 位 |
| `copyright` | `{owner:String,source:String,license:String,expiresAt:null}`，仅复制文件内已有版权／授权标记，未知文本为空字符串 |

识别不写数据库、不创建草稿、不发布内容。文件中的版权、来源与许可只是内嵌声明，服务不能验证其真实性，不会从歌名或歌手推断授权，也不会推断截止时间；发布前仍需人工核实并补齐资料。

仅接受不含凭据、片段、临时签名／令牌及非标准端口的 HTTPS 长期地址。下载不继承代理环境；每次请求和重定向均校验所有 DNS 地址为公网，并固定连接到已验证 IP，TLS 证书和 SNI 仍使用原域名。最多三次 HTTPS 重定向、200 MiB 文件、两个并发识别请求；域名解析、连接、读取与可终止的本地元数据解析共用约 60 秒总期限，临时文件在结束后清理。Linux 解析子进程另设 128 MiB 地址空间硬限制，避免压缩标签耗尽服务内存。地址不安全、文件无效、下载失败、超限、超时或繁忙均返回 400 和中文 `error`，编辑可改用实际文件资料手动填写。
