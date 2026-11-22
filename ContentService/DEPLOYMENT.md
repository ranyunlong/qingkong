# Docker 部署 · xqk.geckoai.cn

沿用现有 HTTPS 入口，只部署公共内容后端。域名为 `https://xqk.geckoai.cn`；音频文件继续使用 OSS。后端不接收健康、心情或日记。

本方案运行一个 Python 后端和一个持久化 SQLite 数据卷，不需要额外数据库、上传或转码服务。容器默认以普通用户运行，宿主机只监听 `127.0.0.1:8787`。以下命令在包含 `compose.yaml` 的目录运行，服务器需要 Docker Engine 和 Docker Compose v2。

**当前部署（2026-11-22）**：已按用户 SSH 授权完成后台与文章图片升级，发布目录为 `/opt/qingkong-content/releases/20261122-images-adbccdbf74ce/`。本次升级保留原管理员凭据、网站首页和公共内容，快照 revision 仍为 46，公开内容仍为 6 篇功能测试文章、3 张专辑和 30 首曲目；所有测试文章明确标注未专业审核。升级备份为 `/opt/qingkong-content/backups/article-images-20261122-072000`。现有 Nginx 配置备份另位于 `/opt/qingkong-content/backups/nginx/`，实际反代片段为 `/etc/nginx/qingkong-content.locations.conf`。服务器更新时保留现有 `.env`，无需再次生成凭据。

官网隐私页已于 2026-11-22 单独更新为公共内容服务说明，旧页备份位于 `/opt/qingkong-content/backups/website/`；没有改首页或重载 Nginx。后续独立测试已验证线上文章修订／撤回、音轨真实文件替换与专辑连带撤回后的缓存清理，临时内容均已撤回，当前快照 revision 46、公开内容仍为 6／3／30。用户手动验收及配对真机结果另行记录，不由这些检查替代。

上述隐私页发布之后，本地官网政策又有文案修改，最新版本尚未再次部署核对。功能覆盖与当前缺口见 [2026-11-22 审计](../docs/FeatureAudit-2026-11-22.md)。

## 1. 拉取镜像与生成凭据

当前发布的服务器镜像为 `registry.cn-hangzhou.aliyuncs.com/geckoai/qingkong-content:20261122-images-adbccdbf74ce`，包含后台界面、音乐文件识别及文章图片功能，架构为 `linux/amd64`。源码运行需要 Python 3.10+、`mutagen==1.48.1` 和 `Pillow==13.0.0`；Docker 镜像使用 Python 3.13。以下方式直接拉取镜像，服务器无需访问 Docker Hub 或安装 Python。仓库若为私有，先按你现有的凭据方式登录阿里云仓库。

```sh
export QINGKONG_CONTENT_IMAGE='registry.cn-hangzhou.aliyuncs.com/geckoai/qingkong-content:20261122-images-adbccdbf74ce'
docker compose pull content
docker compose run --rm --no-deps \
  --user "$(id -u):$(id -g)" \
  --volume "$PWD:/output" \
  --entrypoint python content \
  -m ContentService.configure --output /output/.env
printf "QINGKONG_CONTENT_IMAGE='%s'\n" "$QINGKONG_CONTENT_IMAGE" >> .env
docker compose config --quiet
docker compose up -d --no-build
docker compose ps
```

生成配置的命令会询问管理员名称和两次密码，密码至少 12 字符。生成的 `.env` 权限为 `600`，包含密码散列及随机会话秘密，不保存密码原文、不打印秘密、不覆盖已有配置。随后将所选镜像写入 `.env`，供以后启动和更新使用。

已存在 `.env` 时保留原文件，跳过凭据生成和追加镜像字段，按第 3 节更新。`.env.example` 仅供查看字段，不含可用凭据；若手工填写 `.env`，保留值两侧的单引号，尤其不能展开密码散列中的 `$`。Compose 自动读取 `.env`，无需在 shell 中 `source` 它。检查配置请使用 `--quiet`，普通 `docker compose config` 会输出解析后的环境变量。

如需从源码本地构建，保持 `.env` 中 `QINGKONG_CONTENT_IMAGE='qingkong-content:local'`（或不设置此字段），先执行 `docker compose build`，再使用上面的配置生成命令；无需执行镜像拉取和追加镜像字段步骤。构建需要能访问 Dockerfile 指定的 Python 基础镜像。

没有有效管理员配置时后端会拒绝启动。首次启动数据库为空，不自动导入文章、歌单或审核／发布测试状态。服务启动后约 30 秒内可在 `docker compose ps` 看到健康状态。

本机检查：

```sh
curl --fail http://127.0.0.1:8787/api/v1/snapshot
```

正常返回包含 `schemaVersion`、`revision` 和文章／专辑／曲目数组的 JSON。首次为空数组是正常状态。

## 2. 接入现有 HTTPS 反向代理

将同目录的 `nginx.conf.example` 中三个 `location` 合并到已有 `xqk.geckoai.cn` 的 HTTPS `server` 块，沿用现有证书。图片上传使用精确匹配的独立入口。检查 Nginx 配置后按你现有的部署方式重载。

| 外部地址 | 转发到后端 | 用途 |
|---|---|---|
| `https://xqk.geckoai.cn/api/v1/snapshot` | `http://127.0.0.1:8787/api/v1/snapshot` | App 公共目录 |
| `https://xqk.geckoai.cn/api/v1/...` | 保留原路径 | 分类、文章、专辑、曲目 |
| `https://xqk.geckoai.cn/admin/api/images` | 保留原路径 | 登录后的正文图片上传，独立 `10m` 限制 |
| `https://xqk.geckoai.cn/admin` 与 `/admin/...` | 保留原路径 | 管理、登录及发布 |

`proxy_pass` 使用 `http://127.0.0.1:8787`，末尾不加 `/`；后端本来就包含 `/api/v1/...`，不应删除 `/api` 前缀。`Host` 必须保留外部域名，让管理页面的 Origin／CSRF 校验与 HTTPS 一致。Compose 已开启 Secure 管理 Cookie，请通过 HTTPS 打开后台。

只代理 `/api/` 可以供 App 读取目录，但管理页面还需要 `/admin` 和 `/admin/`。已有网站根路径可保持原配置。管理入口可在现有反向代理按实际管理网络增加访问限制。

后台普通表单反代的请求体上限为 `2m`，图片上传精确路径为 `10m`，管理读取超时为 `75s`，用于容纳富文本表单并等待音乐文件识别返回。音乐通过服务端从 HTTPS 地址临时下载，音频文件不随后台表单上传。公共 API 的限制继续按示例中各自的 `location` 配置。

示例假定 Nginx 运行在宿主机。如果你的反向代理也是容器，需要将它与 `content` 加入同一个 Docker 网络，代理目标使用该网络中的 `http://content:8787`；容器里的 `127.0.0.1` 指向它自己。不要为解决网络连接而直接公开后端端口。

若宿主机 `8787` 已占用，在 `.env` 调整 `QINGKONG_CONTENT_PORT`，同时修改反向代理目标端口。应用容器内部端口保持 `8787`。

部署后检查：

```sh
curl --fail https://xqk.geckoai.cn/api/v1/snapshot
```

浏览器打开 `https://xqk.geckoai.cn/admin/login`，使用生成配置时设置的名称和密码登录。创建草稿后，确认公共目录仍不出现草稿；只有明确审核及发布后的文章才对外可见。专业审核仍由真实审核人员完成。

App 默认使用 **`https://xqk.geckoai.cn`**，客户端在域名根地址后添加 `api/v1/snapshot`，无需用户填写地址，也不提供内容服务设置页面。iPhone 与 Watch 均默认连接该服务，两端分别下载与校验。开源派生版本可在 `Sources/Shared/ContentLibrary.swift` 的 `defaultServiceAddress` 修改默认服务。

## 3. 更新、数据与备份

更新镜像版本时，先将 `.env` 中 `QINGKONG_CONTENT_IMAGE` 改为已发布的新版本，然后：

```sh
docker compose pull content
docker compose up -d --no-build
docker compose ps
docker compose logs --tail=50 content
```

从源码本地构建的环境仍使用 `docker compose up -d --build`。更换镜像不改变管理员凭据或数据卷。

数据库、SQLite 辅助文件和正文配图 `uploads/` 保存在 `content-data` 命名卷，容器重建会保留内容、审核、历史记录及图片。配图上传成功后通过公共图片 URL 读取，属于公共内容，不上传个人健康或日记图片。保持同一个 Compose 项目名称，不额外启动多个后端实例共同写入此卷。停止／删除容器不会自动删除命名卷；`docker compose down -v` 会删除数据，日常更新不使用该命令。

停机备份示例（备份文件还应另存到服务器之外）：

```sh
umask 077
mkdir -p backups
docker compose stop content
docker compose run --rm --no-deps -T --entrypoint tar content \
  -C /data -czf - . > "backups/content-$(date +%Y%m%d-%H%M%S).tar.gz"
docker compose start content
```

备份命令以应用用户读取整个数据目录，不单独复制运行中的 `.sqlite3` 文件。恢复时先停服务并备份当前数据，再完整还原该目录及文件属主 `10001:10001`，随后启动并核对目录 revision。服务重启会使管理员会话失效，需重新登录。单独妥善保存 `.env`；不要放入公开网站、镜像或代码仓库。

## 4. 日志与当前验收范围

### 2026-11-22 后台与文章图片升级记录

登录页与后台采用统一的 iOS 风格，文章管理位于 `/admin/articles`，音乐管理位于 `/admin/music`，`/admin` 保留为文章入口。文章编辑支持富文本及逐条维护参考来源；歌曲在选择专辑并粘贴长期 HTTPS 音频地址后自动读取文件信息，识别结果可手动修改。识别临时下载文件、读取标签并计算完整文件摘要，处理后删除临时文件；识别本身不写数据库、不创建草稿、不自动发布。

正文支持填写 HTTPS 图片链接及上传本地 JPG／PNG／WebP。上传要求有效登录、同源 Origin 和 CSRF；服务校验文件并转为去元数据的 JPEG／PNG，以摘要文件名保存在数据卷。原文件最多 10 MiB，处理后图片最多 8 MiB、最长边 2560 像素。上传本身不发布文章或改变目录 revision；图片 URL 是公共资源。手机采用原生图文渲染，图片尚未做持久离线缓存，最终图片交互与视觉仍待验收。

| 发布项目 | 本次记录 |
|---|---|
| 镜像标签 | `registry.cn-hangzhou.aliyuncs.com/geckoai/qingkong-content:20261122-images-adbccdbf74ce` |
| 镜像 ID | `sha256:d35fb38718f5f37688d9338ef4e67753ab81a0856a0cbf579ed63445c3ad0705` |
| Manifest 摘要 | `sha256:0e85b196cefb65e61e0216f1b3c2e464db7a0eb044f0ba51019e8a10a450f1da` |
| 发布目录 | `/opt/qingkong-content/releases/20261122-images-adbccdbf74ce/` |
| 升级备份 | `/opt/qingkong-content/backups/article-images-20261122-072000` |
| 容器资源 | 内存上限 `768m`（805306368 字节）；`/tmp` 为 `rw,noexec,nosuid,size=450m` 的 tmpfs |
| 后台 Nginx | 普通表单 `2m`，图片上传精确路径 `10m`；读取超时 `75s` |

本次部署日志确认容器健康、SQLite 完整性结果为 `ok`，公共内容、管理员凭据和网站首页均未改变；快照 revision 为 46，文章／专辑／曲目数量为 6／3／30。发布镜像标签与本地发布记录一致，Manifest 摘要见推送日志。证据见 [`deploy-content-article-images.log`](../artifacts/deploy-content-article-images.log)、[`article-images-release.json`](../artifacts/article-images-release.json)、[`push-content-article-images.log`](../artifacts/push-content-article-images.log) 和 [`check-article-images-https.json`](../artifacts/check-article-images-https.json)。

服务器真实音频识别日志确认：文件内标题为 `Sparks Fly`，时长约 260.933 秒，真实大小为 10584640 字节，计算所得 SHA256 和字节数均与已发布文件一致；文件缺少 `owner`、`source`、`license` 版权字段，仍需运营方补齐并核实授权。证据见 [`test-media-live-server.log`](../artifacts/test-media-live-server.log)。这些结果不代表版权验证或用户手动界面验收。

后端不输出访问路径、IP、请求正文或凭据；Docker 运行日志按每份 5 MB、最多 3 份轮转。2026-11-22 只读检查确认主机平台为阿里云 ECS，公共接口及管理入口继承 Nginx 的 `/var/log/nginx/access.log` 与 `/var/log/nginx/error.log`。访问格式包含 IP、时间、请求路径及参数、状态、响应大小、来源页与浏览器信息，不包含 Cookie 或请求正文。`/etc/logrotate.d/nginx` 配置每日轮转、最多 52 份历史归档、延迟压缩、空日志不轮转；没有固定天数上限。本次仅核对配置，未读取实际请求日志或修改共享日志策略，未验证调度和实际删除时间。

App、官网政策源码与商店核对资料已同步已知设置，官网隐私页发布情况见本文开头的记录。云平台自身日志及正式 OSS／媒体提供方和保留规则仍需运营方确认，正式音源发布前应补齐。

当前远端容器健康、镜像摘要、SQLite 完整性与数据卷、HTTPS 公共接口、管理员登录／退出、匿名管理拒绝及原首页一致性均已核验。配对真机上的发布／修订／撤回同步，以及 iPhone／Watch 联网、断网、锁屏、路由和存储不足行为仍需实际验收。测试文章及音轨占位资料不代表专业审核或正式音频授权。
