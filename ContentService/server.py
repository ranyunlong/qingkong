#!/usr/bin/env python3
"""Public content editorial service. See README.md before use."""
import argparse
import base64
import hashlib
import hmac
import html
import ipaddress
import json
import math
import os
import re
import secrets
import stat
import sqlite3
import threading
import time
import uuid
from datetime import datetime, timezone
from contextlib import contextmanager
from http.cookies import SimpleCookie, CookieError
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

from ContentService.richtext import sanitize_html
from ContentService.media_inspection import inspect_media, MediaInspectionError
from ContentService.images import store_image, ImageUploadError


KINDS = ("articles", "albums", "tracks")
KIND_LABELS = {"articles": "文章", "albums": "专辑", "tracks": "音轨"}
STATUS_LABELS = {"draft": "草稿", "in_review": "待审核", "reviewed": "审核通过", "published": "已发布", "withdrawn": "已撤回"}
ACTION_LABELS = {"save_draft": "保存草稿", "submit": "提交审核", "review": "审核通过", "publish": "发布", "publish_test": "发布功能测试（未专业审核）", "withdraw": "撤回", "restore": "历史恢复", "album_withdrawn": "随专辑撤回", "license_expired": "授权到期撤回"}
MAX_BODY = 262144
MAX_CONTENT_BODY = 2 * 1024 * 1024
SESSION_SECONDS = 8 * 3600


class Invalid(ValueError):
    pass


def now():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def canonical(value):
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"), sort_keys=True)


def password_hash(password, salt=None):
    if len(password) < 12:
        raise Invalid("密码至少 12 个字符")
    salt = salt or secrets.token_bytes(16)
    digest = hashlib.pbkdf2_hmac("sha256", password.encode(), salt, 600000)
    return "pbkdf2_sha256$600000$" + base64.b64encode(salt).decode() + "$" + base64.b64encode(digest).decode()


def check_password(password, encoded):
    try:
        algorithm, rounds, salt, expected = encoded.split("$")
        count = int(rounds)
        if algorithm != "pbkdf2_sha256" or not 600000 <= count <= 2000000:
            return False
        actual = hashlib.pbkdf2_hmac("sha256", password.encode(), base64.b64decode(salt, validate=True), count)
        return hmac.compare_digest(actual, base64.b64decode(expected, validate=True))
    except (ValueError, TypeError):
        return False


def text_field(data, key, maximum=200, required=True):
    value = data.get(key, "")
    if not isinstance(value, str) or len(value) > maximum or (required and not value.strip()):
        raise Invalid(f"{key} 必须是非空文本且不超过 {maximum} 字符")
    if any(ord(c) < 32 and c not in "\n\r\t" for c in value):
        raise Invalid(f"{key} 含无效控制字符")
    return value.strip()


def https_url(value, required=False):
    if value in (None, "") and not required:
        return None
    if (not isinstance(value, str) or len(value) > 2048 or "\\" in value
            or any(c.isspace() or ord(c) < 32 or ord(c) == 127 for c in value)):
        raise Invalid("链接必须是有效的长期 HTTPS 地址")
    try:
        parts = urlsplit(value)
        host = parts.hostname
        port = parts.port
    except ValueError:
        raise Invalid("链接格式无效")
    if parts.scheme != "https" or not host or parts.username or parts.password or parts.fragment or port not in (None, 443):
        raise Invalid("链接必须使用 HTTPS，且不能含凭据、片段或非标准端口")
    if host in ("localhost", "127.0.0.1", "::1") or host.endswith((".local", ".localhost")):
        raise Invalid("不能使用本机地址作为公共媒体链接")
    try:
        address = ipaddress.ip_address(host)
    except ValueError:
        address = None
    if address and not address.is_global:
        raise Invalid("公共链接不能使用内网、回环或保留 IP 地址")
    transient = {"expires", "expiry", "signature", "sig", "token", "security-token", "auth_key", "ossaccesskeyid"}
    for key in parse_qs(parts.query, keep_blank_values=True):
        low = key.lower()
        if low in transient or low.startswith(("x-amz-", "x-oss-", "x-goog-")):
            raise Invalid("请填写长期地址，不能使用临时签名或令牌链接")
    return value


def iso_date(value):
    if value in (None, ""):
        return None
    if not isinstance(value, str) or not re.fullmatch(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z", value):
        raise Invalid("期限须为 UTC ISO8601，例如 2027-12-31T23:59:59Z")
    try:
        datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ")
    except ValueError:
        raise Invalid("期限日期无效")
    return value


def is_test_article(data):
    return data.get("title", "").startswith("[测试]") and data.get("body", "").startswith("【仅供功能测试】")


def validate(kind, data):
    if kind not in KINDS or not isinstance(data, dict):
        raise Invalid("未知内容类型")
    common = {"title", "summary", "coverURL", "sortOrder"}
    allowed = common | ({"body", "bodyHTML", "category", "references"} if kind == "articles" else
                        {"albumID", "audioURL", "durationSeconds", "fileVersion", "copyright", "byteSize", "sha256"} if kind == "tracks" else set())
    if set(data) - allowed:
        raise Invalid("含未支持字段（本服务不接收个人健康或日记数据）")
    result = {"title": text_field(data, "title"), "summary": text_field(data, "summary", 1000, False),
              "coverURL": https_url(data.get("coverURL")), "sortOrder": data.get("sortOrder", 0)}
    if type(result["sortOrder"]) is not int or abs(result["sortOrder"]) > 100000:
        raise Invalid("sortOrder 须为 -100000 到 100000 的整数")
    if kind == "articles":
        body_html = data.get("bodyHTML")
        if body_html is not None and not isinstance(body_html, str):
            raise Invalid("bodyHTML 须为文本或 null")
        if body_html and body_html.strip():
            try:
                safe, plain = sanitize_html(body_html, https_url)
            except ValueError as error:
                raise Invalid(str(error))
            result.update(bodyHTML=safe, body=plain)
        else:
            result["body"] = text_field(data, "body", 60000)
        result["category"] = text_field(data, "category", 80)
        refs = data.get("references", [])
        if not isinstance(refs, list) or len(refs) > 30:
            raise Invalid("参考来源须为列表，最多 30 条")
        result["references"] = []
        for ref in refs:
            if not isinstance(ref, dict) or set(ref) != {"title", "url"}:
                raise Invalid("参考来源需包含 title 和 url")
            result["references"].append({"title": text_field(ref, "title", 500), "url": https_url(ref["url"], True)})
        result["review"] = None
    elif kind == "tracks":
        album = text_field(data, "albumID", 36)
        try:
            uuid.UUID(album)
        except ValueError:
            raise Invalid("albumID 须为稳定 UUID")
        duration = data.get("durationSeconds")
        if isinstance(duration, bool) or not isinstance(duration, (int, float)) or not math.isfinite(duration) or not 0 < duration <= 86400:
            raise Invalid("durationSeconds 须大于 0 且不超过 86400")
        size = data.get("byteSize")
        checksum = data.get("sha256")
        if type(size) is not int or not 0 < size <= 9223372036854775807:
            raise Invalid("byteSize 须为正 Int64，需填写真实文件字节数")
        if not isinstance(checksum, str) or not re.fullmatch(r"[0-9a-f]{64}", checksum):
            raise Invalid("sha256 须为真实文件的 64 位小写十六进制摘要")
        rights = data.get("copyright")
        if not isinstance(rights, dict) or set(rights) - {"owner", "source", "license", "expiresAt"}:
            raise Invalid("版权信息格式无效")
        result.update(albumID=album, audioURL=https_url(data.get("audioURL"), True), durationSeconds=duration,
                      fileVersion=text_field(data, "fileVersion", 100), byteSize=size, sha256=checksum,
                      copyright={"owner": text_field(rights, "owner", 500), "source": text_field(rights, "source", 2000),
                                 "license": text_field(rights, "license", 2000), "expiresAt": iso_date(rights.get("expiresAt"))})
    return result


class Store:
    def __init__(self, path):
        self.path = path
        self.lock = threading.RLock()
        with self.connect() as db:
            db.executescript("""
            PRAGMA journal_mode=WAL;
            CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY,value INTEGER NOT NULL);
            INSERT OR IGNORE INTO meta VALUES('revision',0);
            CREATE TABLE IF NOT EXISTS content(id TEXT PRIMARY KEY,kind TEXT NOT NULL,draft TEXT NOT NULL,
              published TEXT,status TEXT NOT NULL,updated_at TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS history(history_id INTEGER PRIMARY KEY AUTOINCREMENT,content_id TEXT NOT NULL,
              kind TEXT NOT NULL,draft TEXT NOT NULL,published TEXT,status TEXT NOT NULL,operation TEXT NOT NULL,
              actor TEXT NOT NULL,created_at TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS tombstones(id TEXT NOT NULL,kind TEXT NOT NULL,revision INTEGER NOT NULL,
              withdrawn_at TEXT NOT NULL,PRIMARY KEY(id,kind));
            """)

    @contextmanager
    def connect(self):
        db = sqlite3.connect(self.path, timeout=15)
        db.row_factory = sqlite3.Row
        try:
            with db:
                yield db
        finally:
            db.close()

    def revision(self, db):
        return db.execute("SELECT value FROM meta WHERE key='revision'").fetchone()[0]

    def bump(self, db):
        db.execute("UPDATE meta SET value=value+1 WHERE key='revision'")
        return self.revision(db)

    def record(self, db, identity, operation, actor):
        row = db.execute("SELECT * FROM content WHERE id=?", (identity,)).fetchone()
        db.execute("INSERT INTO history(content_id,kind,draft,published,status,operation,actor,created_at) VALUES(?,?,?,?,?,?,?,?)",
                   (identity, row["kind"], row["draft"], row["published"], row["status"], operation, actor, now()))

    def visible(self, db):
        rows = db.execute("SELECT id,kind,published FROM content WHERE published IS NOT NULL").fetchall()
        items = {kind: [] for kind in KINDS}
        for row in rows:
            items[row["kind"]].append(json.loads(row["published"]))
        album_ids = {a["id"] for a in items["albums"]}
        items["tracks"] = [t for t in items["tracks"] if t["albumID"] in album_ids]
        for kind in KINDS:
            items[kind].sort(key=lambda x: (x["sortOrder"], x["id"]))
        for album in items["albums"]:
            album["trackIDs"] = [t["id"] for t in items["tracks"] if t["albumID"] == album["id"]]
        return items

    def reconcile(self, db, before):
        after = self.visible(db)
        old = {(kind, item["id"]) for kind in KINDS for item in before[kind]}
        live = {(kind, item["id"]) for kind in KINDS for item in after[kind]}
        for kind, identity in old - live:
            db.execute("INSERT OR REPLACE INTO tombstones VALUES(?,?,?,?)", (identity, kind, self.revision(db), now()))
        for kind, identity in live:
            db.execute("DELETE FROM tombstones WHERE id=? AND kind=?", (identity, kind))

    def expire(self, db):
        before = self.visible(db)
        expired = [track["id"] for track in before["tracks"] if track["copyright"]["expiresAt"] and track["copyright"]["expiresAt"] <= now()]
        if expired:
            self.bump(db)
            for identity in expired:
                db.execute("UPDATE content SET published=NULL,status='withdrawn',updated_at=? WHERE id=?", (now(), identity))
                self.record(db, identity, "license_expired", "system")
            self.reconcile(db, before)

    def snapshot(self):
        with self.lock, self.connect() as db:
            self.expire(db)
            data = self.visible(db)
            data.update(schemaVersion=1, revision=self.revision(db), generatedAt=now(),
                        tombstones=[{"id": r["id"], "kind": r["kind"], "revision": r["revision"], "withdrawnAt": r["withdrawn_at"]}
                                    for r in db.execute("SELECT * FROM tombstones ORDER BY revision,id")])
            return data

    def list_admin(self):
        with self.lock, self.connect() as db:
            return [self.admin_row(r) for r in db.execute("SELECT * FROM content ORDER BY updated_at DESC,id")]

    @staticmethod
    def admin_row(row):
        return {"id": row["id"], "kind": row["kind"], "draft": json.loads(row["draft"]),
                "published": json.loads(row["published"]) if row["published"] else None,
                "status": row["status"], "updatedAt": row["updated_at"]}

    def get(self, kind, identity):
        with self.lock, self.connect() as db:
            row = db.execute("SELECT * FROM content WHERE id=? AND kind=?", (identity, kind)).fetchone()
            if not row:
                raise KeyError(identity)
            result = self.admin_row(row)
            result["history"] = [dict(r) for r in db.execute("SELECT history_id AS historyID,operation,actor,created_at AS createdAt FROM history WHERE content_id=? ORDER BY history_id DESC", (identity,))]
            return result

    def save(self, kind, data, actor, identity=None):
        data = validate(kind, data)
        with self.lock, self.connect() as db:
            if kind == "tracks" and not db.execute("SELECT 1 FROM content WHERE id=? AND kind='albums'", (data["albumID"],)).fetchone():
                raise Invalid("所属专辑不存在")
            if identity:
                old = db.execute("SELECT * FROM content WHERE id=? AND kind=?", (identity, kind)).fetchone()
                if not old:
                    raise KeyError(identity)
                if kind == "tracks" and old["published"]:
                    prior = json.loads(old["published"])
                    if any(data[k] != prior[k] for k in ("audioURL", "sha256", "byteSize")) and data["fileVersion"] == prior["fileVersion"]:
                        raise Invalid("媒体地址或文件摘要改变时必须更新 fileVersion")
                db.execute("UPDATE content SET draft=?,status='draft',updated_at=? WHERE id=?", (canonical(data), now(), identity))
            else:
                identity = str(uuid.uuid4())
                db.execute("INSERT INTO content VALUES(?,?,?,NULL,'draft',?)", (identity, kind, canonical(data), now()))
            self.record(db, identity, "save_draft", actor)
        return self.get(kind, identity)

    def action(self, kind, identity, action, data, actor):
        allowed = {"review": {"reviewer", "credentials", "confirmed"}, "restore": {"historyID"},
                   "submit": set(), "publish": set(), "publish_test": set(), "withdraw": set()}
        if action not in allowed or set(data) - allowed[action]:
            raise Invalid("操作含未支持字段")
        with self.lock, self.connect() as db:
            self.expire(db)
            row = db.execute("SELECT * FROM content WHERE id=? AND kind=?", (identity, kind)).fetchone()
            if not row:
                raise KeyError(identity)
            draft = json.loads(row["draft"])
            before = self.visible(db)
            if action == "submit":
                if kind != "articles" or row["status"] != "draft":
                    raise Invalid("只有文章草稿可提交审核")
                db.execute("UPDATE content SET status='in_review',updated_at=? WHERE id=?", (now(), identity))
            elif action == "review":
                if kind != "articles" or row["status"] != "in_review" or not draft["references"]:
                    raise Invalid("文章须先提交审核并补齐真实参考来源")
                if data.get("confirmed") is not True:
                    raise Invalid("需要明确确认已完成专业审核")
                draft["review"] = {"reviewer": text_field(data, "reviewer", 200), "credentials": text_field(data, "credentials", 1000), "reviewedAt": now()}
                db.execute("UPDATE content SET draft=?,status='reviewed',updated_at=? WHERE id=?", (canonical(draft), now(), identity))
            elif action in ("publish", "publish_test"):
                if action == "publish_test":
                    if kind != "articles" or not is_test_article(draft) or not draft["references"]:
                        raise Invalid("功能测试发布仅用于标题以 [测试]、正文以【仅供功能测试】开头且有来源的测试文章")
                    draft["testOnly"] = True
                    draft["review"] = {"reviewer": "功能测试发布（未专业审核）", "credentials": "仅供功能测试；本记录标记测试发布，未进行医学专业审核", "reviewedAt": now()}
                elif kind == "articles" and (row["status"] != "reviewed" or not draft.get("review") or not draft["references"]):
                    raise Invalid("文章须有参考来源并明确完成本次版本的专业审核后发布")
                else:
                    draft.pop("testOnly", None)
                if kind == "tracks":
                    expires = draft["copyright"]["expiresAt"]
                    if expires and expires <= now():
                        raise Invalid("版权授权已到期，不能发布")
                    if not db.execute("SELECT 1 FROM content WHERE id=? AND kind='albums' AND published IS NOT NULL", (draft["albumID"],)).fetchone():
                        raise Invalid("请先发布所属专辑")
                revision = self.bump(db)
                previous = json.loads(row["published"]) if row["published"] else {}
                public = dict(draft, id=identity, updatedAt=now(), publishedAt=previous.get("publishedAt", now()), revision=revision)
                db.execute("UPDATE content SET draft=?,published=?,status='published',updated_at=? WHERE id=?", (canonical(draft), canonical(public), now(), identity))
            elif action == "withdraw":
                self.bump(db)
                db.execute("UPDATE content SET published=NULL,status='withdrawn',updated_at=? WHERE id=?", (now(), identity))
                if kind == "albums":
                    for track in before["tracks"]:
                        if track["albumID"] == identity:
                            db.execute("UPDATE content SET published=NULL,status='withdrawn',updated_at=? WHERE id=?", (now(), track["id"]))
                            self.record(db, track["id"], "album_withdrawn", actor)
            elif action == "restore":
                history_id = data.get("historyID")
                if type(history_id) is not int:
                    raise Invalid("historyID 须为整数")
                historical = db.execute("SELECT draft FROM history WHERE history_id=? AND content_id=?", (history_id, identity)).fetchone()
                if not historical:
                    raise Invalid("历史版本不存在")
                restored = json.loads(historical["draft"])
                if kind == "articles":
                    restored["review"] = None
                db.execute("UPDATE content SET draft=?,status='draft',updated_at=? WHERE id=?", (canonical(restored), now(), identity))
            else:
                raise Invalid("未知操作")
            self.record(db, identity, action, actor)
            self.reconcile(db, before)
        return self.get(kind, identity)


class AppServer(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, address, store, username, encoded_password, secret, secure_cookies=False):
        if len(secret) < 32 or not username or not check_password_format(encoded_password):
            raise Invalid("需要管理员名称、有效密码散列与至少 32 字符会话秘密")
        self.store = store
        self.username = username
        self.encoded_password = encoded_password
        self.secret = secret.encode()
        self.secure_cookies = secure_cookies
        self.sessions = {}
        self.attempts = {}
        self.session_lock = threading.RLock()
        super().__init__(address, Handler)


def check_password_format(encoded):
    try:
        algorithm, count, salt, digest = encoded.split("$")
        return algorithm == "pbkdf2_sha256" and 600000 <= int(count) <= 2000000 and len(base64.b64decode(salt, validate=True)) >= 16 and len(base64.b64decode(digest, validate=True)) == 32
    except (ValueError, TypeError):
        return False


class Handler(BaseHTTPRequestHandler):
    server_version = "QingkongContent"
    sys_version = ""

    def log_message(self, *args):
        pass  # No content, credentials, query strings, client address or personal data logs.

    def send(self, status, body, content_type="application/json; charset=utf-8", cookie=None, script_nonce=None):
        raw = body.encode() if isinstance(body, str) else canonical(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(raw)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("Referrer-Policy", "same-origin")
        policy = "default-src 'none'; style-src 'unsafe-inline'; img-src 'self' https:; form-action 'self'; frame-ancestors 'none'; base-uri 'none'"
        if script_nonce:
            policy += f"; script-src 'nonce-{script_nonce}'; connect-src 'self'"
        self.send_header("Content-Security-Policy", policy)
        if cookie:
            self.send_header("Set-Cookie", cookie)
        self.end_headers()
        self.wfile.write(raw)

    def redirect(self, path, cookie=None):
        self.send_response(303)
        self.send_header("Location", path)
        self.send_header("Content-Length", "0")
        self.send_header("Cache-Control", "no-store")
        if cookie:
            self.send_header("Set-Cookie", cookie)
        self.end_headers()

    def cookie(self, token, clear=False):
        result = f"qk_admin={token}; Path=/admin; HttpOnly; SameSite=Strict; Max-Age={0 if clear else SESSION_SECONDS}"
        if self.server.secure_cookies:
            result += "; Secure"
        return result

    def new_session(self, authenticated=False):
        token = secrets.token_urlsafe(32)
        key = hmac.new(self.server.secret, token.encode(), hashlib.sha256).hexdigest()
        entry = {"authenticated": authenticated, "csrf": secrets.token_urlsafe(32), "expires": time.time() + (SESSION_SECONDS if authenticated else 600)}
        with self.server.session_lock:
            self.server.sessions = {k: v for k, v in self.server.sessions.items() if v["expires"] > time.time()}
            self.server.sessions[key] = entry
        return token, entry

    def session(self):
        try:
            cookies = SimpleCookie(self.headers.get("Cookie", ""))
            token = cookies["qk_admin"].value
        except (CookieError, KeyError):
            return None, None
        key = hmac.new(self.server.secret, token.encode(), hashlib.sha256).hexdigest()
        with self.server.session_lock:
            entry = self.server.sessions.get(key)
            if entry and entry["expires"] > time.time():
                return key, entry
        return None, None

    def body(self):
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            raise Invalid("无效请求长度")
        path = urlsplit(self.path).path
        limit = MAX_CONTENT_BODY if path == "/admin/save" or path.startswith("/admin/api/content/") else MAX_BODY
        if not 0 < length <= limit or self.headers.get("Transfer-Encoding"):
            raise Invalid("请求为空或超过 " + ("2 MiB" if limit == MAX_CONTENT_BODY else "256 KiB"))
        try:
            raw = self.rfile.read(length).decode("utf-8")
            media = self.headers.get("Content-Type", "").split(";")[0]
            if media == "application/json":
                data = json.loads(raw)
                if not isinstance(data, dict):
                    raise Invalid("请求须为 JSON 对象")
                return data
            if media == "application/x-www-form-urlencoded":
                return {key: values if key in ("referenceTitle", "referenceURL") else values[-1]
                        for key, values in parse_qs(raw, keep_blank_values=True).items()}
            raise Invalid("仅支持 JSON 或表单")
        except (UnicodeDecodeError, json.JSONDecodeError):
            raise Invalid("请求编码或 JSON 无效")

    def do_GET(self):
        try:
            self.get()
        except KeyError:
            self.send(404, {"error": "内容不存在"})
        except Invalid as error:
            self.send(400, {"error": str(error)})

    def get(self):
        path = urlsplit(self.path).path
        if path.startswith("/api/v1/images/"):
            return self.public_image(path.removeprefix("/api/v1/images/"))
        if path in ("/api/v1/snapshot", "/api/public/snapshot"):
            return self.send(200, self.server.store.snapshot())
        if path.startswith("/api/v1/"):
            parts = path.strip("/").split("/")
            snapshot = self.server.store.snapshot()
            if parts == ["api", "v1", "categories"]:
                return self.send(200, {"revision": snapshot["revision"], "categories": sorted({a["category"] for a in snapshot["articles"]})})
            if len(parts) in (3, 4) and parts[2] in KINDS:
                items = snapshot[parts[2]]
                if len(parts) == 4:
                    item = next((a for a in items if a["id"] == parts[3]), None)
                    if item is None:
                        raise KeyError(parts[3])
                    return self.send(200, item)
                query = parse_qs(urlsplit(self.path).query)
                if parts[2] == "articles" and "category" in query:
                    items = [a for a in items if a["category"] == query["category"][0]]
                return self.send(200, {"revision": snapshot["revision"], "items": items})
        if path == "/admin/login":
            token, session = self.new_session()
            return self.page(self.login_page(session), self.cookie(token))
        if path.startswith("/admin"):
            _, session = self.session()
            if not session or not session["authenticated"]:
                return self.send(401, {"error": "请先登录管理员"})
            if path == "/admin/api/session":
                return self.send(200, {"csrfToken": session["csrf"], "username": self.server.username})
            if path == "/admin/api/content":
                return self.send(200, {"items": self.server.store.list_admin()})
            parts = path.strip("/").split("/")
            if len(parts) == 5 and parts[:3] == ["admin", "api", "content"] and parts[3] in KINDS:
                return self.send(200, self.server.store.get(parts[3], parts[4]))
            if path in ("/admin", "/admin/articles", "/admin/music"):
                section = "music" if path == "/admin/music" else "articles"
                return self.page(self.dashboard(session, section))
            if path == "/admin/edit":
                query = parse_qs(urlsplit(self.path).query)
                kind = query.get("kind", ["articles"])[0]
                identity = query.get("id", [""])[0]
                item = self.server.store.get(kind, identity) if identity else None
                album_id = query.get("albumID", [""])[0]
                return self.page(self.editor(session, kind, item, album_id), editor=True)
        self.send(404, {"error": "接口不存在"})

    def public_image(self, filename):
        if not re.fullmatch(r"[0-9a-f]{64}\.(?:jpg|png)", filename):
            raise KeyError(filename)
        path = Path(self.server.store.path).resolve().parent / "uploads" / filename
        try:
            descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
        except OSError:
            raise KeyError(filename) from None
        with os.fdopen(descriptor, "rb") as image:
            info = os.fstat(image.fileno())
            if not stat.S_ISREG(info.st_mode):
                raise KeyError(filename)
            self.send_response(200)
            self.send_header("Content-Type", "image/jpeg" if filename.endswith(".jpg") else "image/png")
            self.send_header("Content-Length", str(info.st_size))
            self.send_header("Cache-Control", "public, max-age=31536000, immutable")
            self.send_header("X-Content-Type-Options", "nosniff")
            self.end_headers()
            while chunk := image.read(65536):
                self.wfile.write(chunk)

    def upload_image(self, session):
        # Raw uploads need header authentication before any potentially large body is read.
        csrf = self.headers.get("X-CSRF-Token", "")
        host = self.headers.get("Host", "")
        expected = ("https" if self.server.secure_cookies else "http") + "://" + host
        if (not csrf or not hmac.compare_digest(csrf.encode(), session["csrf"].encode())
                or self.headers.get("Origin") != expected):
            return self.send(403, {"error": "CSRF 校验失败，请刷新管理页面"})
        try:
            parts = urlsplit("https://" + host)
            if (len(self.headers.get_all("Host", [])) != 1 or not parts.hostname
                    or parts.username is not None or parts.password is not None
                    or parts.path or parts.query or parts.fragment
                    or any(character.isspace() or ord(character) < 32 for character in host)):
                raise ValueError()
            parts.port  # Validate the port spelling before returning a public URL.
            if len(self.headers.get_all("Content-Length", [])) != 1 or self.headers.get("Transfer-Encoding"):
                raise ValueError()
            length = int(self.headers.get("Content-Length", ""))
        except ValueError:
            raise Invalid("图片请求的主机或长度无效") from None
        previous_timeout = self.connection.gettimeout()
        try:
            self.connection.settimeout(5)
            filename, result = store_image(self.rfile, length, self.headers.get("Content-Type", ""),
                                           Path(self.server.store.path).resolve().parent / "uploads")
        except ImageUploadError as error:
            raise Invalid(str(error)) from None
        finally:
            self.connection.settimeout(previous_timeout)
        result["url"] = "https://" + host + "/api/v1/images/" + filename
        return self.send(201, result)

    def do_POST(self):
        try:
            self.post()
        except KeyError:
            self.send(404, {"error": "内容不存在"})
        except Invalid as error:
            self.send(400, {"error": str(error)})

    def post(self):
        path = urlsplit(self.path).path
        if not path.startswith("/admin/"):
            return self.send(404, {"error": "本服务只接收管理员公共内容操作"})
        key, session = self.session()
        if not session or (path != "/admin/login" and not session["authenticated"]):
            return self.send(401, {"error": "请先登录管理员"})
        if path == "/admin/api/images":
            return self.upload_image(session)
        data = self.body()
        csrf = self.headers.get("X-CSRF-Token", data.get("csrf", ""))
        origin = self.headers.get("Origin")
        expected = ("https" if self.server.secure_cookies else "http") + "://" + self.headers.get("Host", "")
        if not isinstance(csrf, str) or not hmac.compare_digest(csrf.encode(), session["csrf"].encode()) or (origin and origin != expected):
            return self.send(403, {"error": "CSRF 校验失败，请刷新管理页面"})
        if path == "/admin/login":
            ip = self.client_address[0]
            with self.server.session_lock:
                attempts = [t for t in self.server.attempts.get(ip, []) if t > time.time() - 900]
                if len(attempts) >= 5:
                    return self.send(429, {"error": "登录尝试过多，请 15 分钟后重试"})
                attempts.append(time.time())
                self.server.attempts[ip] = attempts
            username = data.get("username", "")
            password = data.get("password", "")
            valid_password = isinstance(password, str) and check_password(password, self.server.encoded_password)
            if not isinstance(username, str) or not hmac.compare_digest(username.encode(), self.server.username.encode()) or not valid_password:
                return self.send(401, {"error": "管理员或密码错误"})
            with self.server.session_lock:
                self.server.sessions.pop(key, None)
                self.server.attempts.pop(ip, None)
            token, _ = self.new_session(True)
            return self.redirect("/admin", self.cookie(token))
        if path == "/admin/logout":
            with self.server.session_lock:
                self.server.sessions.pop(key, None)
            return self.redirect("/admin/login", self.cookie("", True))
        if path == "/admin/api/media/inspect":
            if set(data) - {"url", "csrf"}:
                raise Invalid("文件识别仅接受 url")
            try:
                return self.send(200, inspect_media(data.get("url")))
            except MediaInspectionError as error:
                raise Invalid(str(error))
        if path == "/admin/save":
            kind = data.get("kind")
            identity = data.get("id") or None
            payload = self.decode_editor(kind, data)
            item = self.server.store.save(kind, payload, self.server.username, identity)
            return self.redirect(f'/admin/edit?kind={kind}&id={item["id"]}')
        if path == "/admin/action":
            action_data = {k: v for k, v in data.items() if k not in {"csrf", "kind", "id", "action"}}
            if "confirmed" in data:
                action_data["confirmed"] = data.get("confirmed") == "yes"
            if "historyID" in data:
                try:
                    action_data["historyID"] = int(data["historyID"])
                except ValueError:
                    raise Invalid("历史版本编号无效")
            item = self.server.store.action(data.get("kind"), data.get("id"), data.get("action"), action_data, self.server.username)
            return self.redirect(f'/admin/edit?kind={item["kind"]}&id={item["id"]}')
        parts = path.strip("/").split("/")
        if len(parts) in (4, 5, 6) and parts[:3] == ["admin", "api", "content"] and parts[3] in KINDS:
            kind = parts[3]
            if len(parts) == 4:
                return self.send(201, self.server.store.save(kind, data, self.server.username))
            if len(parts) == 5:
                return self.send(200, self.server.store.save(kind, data, self.server.username, parts[4]))
            return self.send(200, self.server.store.action(kind, parts[4], parts[5], data, self.server.username))
        self.send(404, {"error": "接口不存在"})

    @staticmethod
    def form(action, session, inner, attributes=""):
        return f'<form method="post" action="{action}" {attributes}><input type="hidden" name="csrf" value="{html.escape(session["csrf"])}">{inner}</form>'

    def page(self, inner, cookie=None, editor=False):
        assets = Path(__file__).parent
        style = (assets / "admin_style.css").read_text(encoding="utf-8")
        nonce = secrets.token_urlsafe(24) if editor else None
        script = f'<script nonce="{nonce}">{(assets / "admin_editor.js").read_text(encoding="utf-8")}</script>' if editor else ""
        self.send(200, '<!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>小晴空 · 内容管理</title><style>' + style + '</style></head><body>' + inner + script + '</body></html>',
                  "text/html; charset=utf-8", cookie, script_nonce=nonce)

    @staticmethod
    def icon(name):
        paths = {
            "sun": '<circle cx="12" cy="12" r="4"/><path d="M12 2v2m0 16v2M2 12h2m16 0h2M5 5l1.5 1.5m11 11L19 19M5 19l1.5-1.5m11-11L19 5"/>',
            "article": '<rect x="5" y="3" width="14" height="18" rx="2"/><path d="M9 8h6M9 12h6m-6 4h4"/>',
            "music": '<path d="M9 18V5l11-2v13M9 9l11-2"/><ellipse cx="6" cy="18" rx="3" ry="2.5"/><ellipse cx="17" cy="16" rx="3" ry="2.5"/>',
            "album": '<rect x="3" y="3" width="18" height="18" rx="4"/><circle cx="12" cy="12" r="5"/><circle cx="12" cy="12" r="1"/>',
            "right": '<path d="m9 5 7 7-7 7"/>',
            "plus": '<path d="M12 5v14M5 12h14"/>',
            "back": '<path d="m14 5-7 7 7 7"/>',
        }
        return '<svg class="icon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">' + paths.get(name, paths["article"]) + '</svg>'

    def login_page(self, session):
        return ('<main class="login-layout"><section class="login-card"><div class="login-brand"><div class="brand-mark">'
                + self.icon("sun") + '</div><h1>小晴空</h1><p>登录内容管理</p></div>'
                + self.form("/admin/login", session,
                            '<label>管理员<input name="username" autocomplete="username" autocapitalize="none" spellcheck="false" placeholder="输入管理员名称" required></label>'
                            '<label>密码<input name="password" type="password" autocomplete="current-password" placeholder="输入登录密码" required></label>'
                            '<button class="primary" type="submit">登录</button>')
                + '<p class="field-hint">管理文章、专辑与歌曲。个人健康、心情与日记仅保存在用户设备。</p></section></main>')

    def shell(self, session, section, title, inner):
        nav = ""
        for key, label, icon in (("articles", "文章管理", "article"), ("music", "专辑与音乐", "music")):
            current = ' aria-current="page"' if section == key else ""
            active = " is-active" if section == key else ""
            nav += f'<a class="nav-link{active}" href="/admin/{key}"{current}><span class="nav-icon">{self.icon(icon)}</span>{label}</a>'
        return ('<div class="app-shell"><aside class="sidebar"><a class="brand" href="/admin/articles"><span class="brand-mark">'
                + self.icon("sun") + '</span><span class="brand-copy"><strong>小晴空</strong><small>内容管理</small></span></a>'
                + '<nav class="sidebar-nav" aria-label="内容管理分区">' + nav + '</nav><div class="sidebar-footer">'
                + '<p>公共内容管理<br>个人记录保存在用户设备</p>'
                + self.form("/admin/logout", session, '<button class="quiet" type="submit">退出登录</button>', 'class="signout-form"')
                + '</div></aside><div class="workspace"><header class="topbar"><div class="breadcrumb"><a href="/admin/'
                + section + '">' + ("文章管理" if section == "articles" else "专辑与音乐") + '</a>'
                + self.icon("right") + '<strong>' + html.escape(title) + '</strong></div><span class="topbar-note">'
                + html.escape(self.server.username) + '</span></header><main class="content">' + inner + '</main></div></div>')

    @staticmethod
    def badge(item):
        status = item["status"]
        live = '<span class="live-state">线上有已发布版本</span>' if item["published"] else '<span class="muted">尚未发布</span>'
        return f'<span class="status status-{status}">{STATUS_LABELS[status]}</span>' + live

    def dashboard(self, session, section="articles"):
        rows = self.server.store.list_admin()
        if section == "articles":
            articles = [r for r in rows if r["kind"] == "articles"]
            inner = ('<div class="page-heading"><div><p class="page-kicker">小晴空 · 内容</p><h1 class="page-title">文章管理</h1>'
                     '<p class="page-description">编辑安心小知识，整理参考来源，并管理审核与发布。</p></div>'
                     '<div class="heading-actions"><a class="button primary" href="/admin/edit?kind=articles">'
                     + self.icon("plus") + '新建文章</a></div></div>')
            inner += f'<p class="summary-line"><span>共 <strong>{len(articles)}</strong> 篇文章</span><span>已发布 <strong>{sum(bool(r["published"]) for r in articles)}</strong> 篇</span></p>'
            inner += '<section class="content-card"><div class="section-heading"><h2 class="section-title">全部文章</h2><p class="section-note">修改后保存为草稿</p></div><ul class="item-list">'
            for item in articles:
                data = item["draft"]
                link = f'/admin/edit?kind=articles&amp;id={item["id"]}'
                inner += ('<li class="item-row"><span class="row-icon article-icon">' + self.icon("article") + '</span><div class="item-main">'
                          f'<h3 class="item-title"><a href="{link}">{html.escape(data["title"])}</a></h3>'
                          f'<p class="item-subtitle">{html.escape(data.get("summary", ""))}</p><div class="item-meta">'
                          + self.badge(item) + f'<span>{html.escape(data.get("category", ""))}</span></div></div>'
                          f'<div class="row-actions"><a class="button quiet" href="{link}">编辑{self.icon("right")}</a></div></li>')
            inner += '</ul>'
            if not articles:
                inner += '<div class="empty-state"><strong>还没有文章</strong><p>从一篇新的安心小知识开始。</p></div>'
            inner += '</section>'
        else:
            albums = [r for r in rows if r["kind"] == "albums"]
            tracks = [r for r in rows if r["kind"] == "tracks"]
            inner = ('<div class="page-heading"><div><p class="page-kicker">小晴空 · 声音</p><h1 class="page-title">专辑与音乐</h1>'
                     '<p class="page-description">按专辑整理歌曲，读取音频信息，管理内容发布。</p></div><div class="heading-actions">'
                     '<a class="button secondary" href="/admin/edit?kind=albums">' + self.icon("plus")
                     + '新建专辑</a><a class="button primary" href="/admin/edit?kind=tracks">'
                     + self.icon("plus") + '新建歌曲</a></div></div>')
            inner += f'<p class="summary-line"><span><strong>{len(albums)}</strong> 张专辑</span><span><strong>{len(tracks)}</strong> 首歌曲</span></p>'
            for album in albums:
                data = album["draft"]
                songs = [r for r in tracks if r["draft"]["albumID"] == album["id"]]
                songs.sort(key=lambda r: (r["draft"]["sortOrder"], r["draft"]["title"], r["id"]))
                inner += ('<section class="content-card"><div class="album-header"><span class="row-icon album-icon">' + self.icon("album")
                          + '</span><div class="album-copy"><h2 class="item-title">'
                          f'<a href="/admin/edit?kind=albums&amp;id={album["id"]}">{html.escape(data["title"])}</a></h2>'
                          f'<p class="item-subtitle">{html.escape(data.get("summary", ""))}</p><div class="item-meta">'
                          + self.badge(album) + f'<span>{len(songs)} 首歌曲</span></div></div><div class="album-actions">'
                          f'<a class="button secondary" href="/admin/edit?kind=albums&amp;id={album["id"]}">编辑专辑</a>'
                          f'<a class="button" href="/admin/edit?kind=tracks&amp;albumID={album["id"]}">添加歌曲</a></div></div><ol class="track-list">')
                for index, track in enumerate(songs, 1):
                    song = track["draft"]
                    seconds = int(song["durationSeconds"])
                    link = f'/admin/edit?kind=tracks&amp;id={track["id"]}'
                    inner += (f'<li class="track-row"><span class="track-index">{index:02}</span><div class="item-main">'
                              f'<h3 class="item-title"><a href="{link}">{html.escape(song["title"])}</a></h3>'
                              f'<p class="item-subtitle">{html.escape(song.get("summary", ""))}</p>'
                              f'<div class="item-meta">{self.badge(track)}<span>{seconds // 60}:{seconds % 60:02}</span></div></div>'
                              f'<div class="row-actions"><a class="button quiet" href="{link}">编辑{self.icon("right")}</a></div></li>')
                inner += '</ol>'
                if not songs:
                    inner += '<div class="empty-state"><p>这张专辑还没有歌曲，添加一首开始整理。</p></div>'
                inner += '</section>'
            if not albums:
                inner += '<section class="content-card empty-state"><strong>创建第一张专辑</strong><p>添加专辑后，就可以粘贴音频链接读取歌曲信息。</p><a class="button primary" href="/admin/edit?kind=albums">新建专辑</a></section>'
        return self.shell(session, section, "内容列表", inner)

    def editor(self, session, kind, item, album_id=""):
        if kind not in KINDS:
            raise Invalid("未知内容类型")
        data = item["draft"] if item else {}
        identity = item["id"] if item else ""
        section = "articles" if kind == "articles" else "music"
        label = "歌曲" if kind == "tracks" else KIND_LABELS[kind]
        title = ("编辑" if item else "新建") + label
        inner = (f'<div class="page-heading"><div><p class="page-kicker">内容编辑</p><h1 class="page-title">{title}</h1>'
                 '<p class="page-description">保存后成为草稿，确认发布后更新手机端内容。</p></div>'
                 f'<a class="button secondary" href="/admin/{section}">{self.icon("back")}返回列表</a></div>')
        if item:
            inner += '<p class="summary-line">' + self.badge(item) + '</p>'
        fields = f'<input type="hidden" name="kind" value="{kind}"><input type="hidden" name="id" value="{identity}">'

        def field(key, label, value=None, area=False, type="text", required=False, hint=""):
            value = data.get(key, "") if value is None else value
            value = "" if value is None else str(value)
            attrs = f'name="{key}"' + (" required" if required else "")
            control = f'<textarea {attrs}>{html.escape(value)}</textarea>' if area else f'<input type="{type}" {attrs} value="{html.escape(value, quote=True)}"' + (' step="any"' if type == "number" else '') + '>'
            return f'<label>{label}{control}' + (f'<span class="field-hint">{hint}</span>' if hint else '') + '</label>'

        if kind == "tracks":
            fields += '<section class="form-section"><h2 class="section-title">1. 选择专辑</h2><p class="section-note">先选择这首歌曲所属的专辑。</p><label>所属专辑<select name="albumID" required><option value="">请选择专辑</option>'
            for album in self.server.store.list_admin():
                if album["kind"] == "albums":
                    selected = " selected" if album["id"] == data.get("albumID", album_id) else ""
                    fields += f'<option value="{album["id"]}"{selected}>{html.escape(album["draft"]["title"])}</option>'
            fields += '</select></label></section><section class="form-section"><h2 class="section-title">2. 读取音乐文件</h2><p class="section-note">粘贴长期 HTTPS 链接，自动读取文件里的信息。</p>'
            fields += field("audioURL", "音乐文件链接", type="url", required=True)
            fields += '<div class="heading-actions"><button type="button" class="secondary" data-inspect-media>读取文件信息</button></div><p class="field-hint" data-media-status role="status" aria-live="polite">自动识别名称、时长、文件摘要和文件内的版权标记。识别后仍可修改。</p></section>'
        fields += '<section class="form-section"><h2 class="section-title">' + ('3. 歌曲信息' if kind == "tracks" else "基本信息") + '</h2><p class="section-note">让内容有一个清晰的名称和介绍。</p><div class="field-grid">'
        fields += field("title", "标题" if kind == "articles" else "名称", required=True)
        if kind == "articles":
            fields += field("category", "分类", required=True)
        elif kind == "tracks":
            fields += field("durationSeconds", "时长（秒）", type="number", required=True)
        fields += '<div class="field-wide">' + field("summary", "摘要 / 介绍", area=True) + '</div>'
        fields += field("coverURL", "封面链接（可选）", type="url")
        fields += field("sortOrder", "排序", data.get("sortOrder", 0), type="number")
        fields += '</div></section>'
        if kind == "articles":
            original_html = data.get("bodyHTML", "")
            safe = sanitize_html(original_html, https_url)[0] if original_html else "".join('<p>' + html.escape(line) + '</p>' for line in data.get("body", "").splitlines())
            fields += '<section class="form-section"><h2 class="section-title">正文</h2><p class="section-note">支持标题、文字样式、列表、引用、链接和图片。</p>'
            fields += '<input type="hidden" name="bodyHTML" value=""><div class="rich-editor" data-rich-editor hidden><div class="editor-toolbar" role="toolbar" aria-label="正文格式">'
            for command, value, label in (("formatBlock", "p", "正文"), ("formatBlock", "h2", "标题"), ("formatBlock", "h3", "小标题"), ("bold", "", "粗体"), ("italic", "", "斜体"), ("underline", "", "下划线"), ("strikeThrough", "", "删除线"), ("insertUnorderedList", "", "项目列表"), ("insertOrderedList", "", "编号列表"), ("formatBlock", "blockquote", "引用"), ("createLink", "", "链接")):
                fields += f'<button type="button" data-editor-command="{command}" data-command-value="{value}" aria-label="{label}">{label}</button>'
            fields += '<button type="button" data-editor-image-url>图片链接</button><button type="button" data-editor-image-upload>上传图片</button></div><input hidden type="file" accept="image/jpeg,image/png,image/webp" data-editor-image-file><div class="editor-surface" data-editor-surface contenteditable="true" role="textbox" aria-multiline="true" aria-label="文章正文" data-placeholder="在这里开始写作…">' + safe + '</div></div>'
            fields += '<div data-plain-fallback class="editor-fallback">' + field("body", "正文（纯文本后备）", area=True) + '</div><p class="editor-help">支持 HTTPS 图片链接与本地上传 JPEG、PNG、WebP，每张不超过 10 MiB，正文最多 30 张。</p></section>'
            fields += '<section class="form-section"><div class="reference-heading"><h2 class="section-title">参考来源</h2><button class="quiet" type="button" data-add-reference>添加来源</button></div><p class="section-note">每条来源填写一个标题和一个链接，最多 30 条。</p><div class="reference-editor" data-reference-list>'
            for ref in data.get("references", []) or [{"title": "", "url": ""}]:
                fields += '<div class="reference-row" data-reference-row>' + field("referenceTitle", "来源标题", ref["title"]) + field("referenceURL", "来源链接", ref["url"], type="url") + '<button type="button" data-remove-reference aria-label="移除来源">×</button></div>'
            fields += '</div></section>'
        if kind == "tracks":
            fields += '<section class="form-section"><h2 class="section-title">文件信息</h2><p class="section-note">从实际文件计算，文件变化后重新读取。</p><div class="field-grid">'
            for key, label, type in (("fileVersion", "文件版本", "text"), ("byteSize", "文件大小（字节）", "number"), ("sha256", "SHA256", "text")):
                fields += '<div' + (' class="field-wide"' if key == "sha256" else '') + '>' + field(key, label, type=type, required=True) + '</div>'
            fields += '</div></section><section class="form-section"><h2 class="section-title">版权与授权</h2><p class="section-note">仅填写真实版权与授权资料。文件中没有的内容请自行补充。</p><div class="field-grid">'
            rights = data.get("copyright", {})
            for key, label in (("owner", "版权所有者"), ("source", "授权来源"), ("license", "授权范围 / 许可"), ("expiresAt", "授权截止（可选）")):
                fields += field(key, label, rights.get(key, ""), required=key != "expiresAt", hint="UTC 日期，例如 2027-12-31T23:59:59Z；永久授权可留空。" if key == "expiresAt" else "")
            fields += '</div></section>'
        fields += '<div class="form-actions"><p class="field-hint">保存不会自动发布</p><button class="primary" type="submit">保存草稿</button></div>'
        attributes = 'class="editor-form" data-content-editor' + (' data-media-editor' if kind == "tracks" else '')
        inner += '<div class="editor-layout"><div class="editor-main"><section class="content-card">' + self.form("/admin/save", session, fields, attributes) + '</section>'
        if item:
            preview_body = sanitize_html(data["bodyHTML"], https_url)[0] if data.get("bodyHTML") else '<p style="white-space:pre-wrap">' + html.escape(data.get("body", "")) + '</p>'
            inner += '<section class="content-card preview-card"><h2 class="section-title">草稿预览</h2><article class="article-preview"><h3>' + html.escape(data["title"]) + '</h3><p>' + html.escape(data.get("summary", "")) + '</p><div class="rich-preview">' + preview_body + '</div></article>'
            if kind == "articles":
                inner += '<ul class="reference-list">'
                for ref in data["references"]:
                    inner += '<li><a href="' + html.escape(ref["url"], quote=True) + '">' + html.escape(ref["title"]) + '</a></li>'
                inner += '</ul>'
            inner += '</section>'
        inner += '</div><aside class="editor-aside">'
        if item:
            review_status = "功能测试（未专业审核）" if data.get("testOnly") else "专业审核：" + ("已记录" if data.get("review") else "未审核")
            inner += '<section class="content-card action-card"><h2 class="section-title">审核与发布</h2><p class="section-note">' + html.escape(review_status if kind == "articles" else "确认内容与授权后发布。") + '</p><div class="action-list">'
            hidden = f'<input type="hidden" name="kind" value="{kind}"><input type="hidden" name="id" value="{identity}">'

            def action_form(action, label, extra="", button_class="secondary"):
                return self.form("/admin/action", session, hidden + f'<input type="hidden" name="action" value="{action}">' + extra + f'<button class="{button_class}" type="submit">{label}</button>', 'class="action-form"')

            if kind == "articles":
                if is_test_article(data):
                    inner += action_form("publish_test", "发布功能测试（未专业审核）")
                if item["status"] == "draft":
                    inner += action_form("submit", "提交审核")
                inner += action_form("review", "记录审核通过",
                                     '<label>审核人<input name="reviewer" required></label><label>专业资质 / 审核范围<input name="credentials" required></label>'
                                     '<label class="checkbox-label"><input type="checkbox" name="confirmed" value="yes" required>我确认已实际完成本版本专业审核，来源和适用条件已核实</label>')
                if data.get("review"):
                    review = data["review"]
                    inner += '<p class="field-hint">' + html.escape(review["reviewer"] + ' · ' + review["credentials"] + ' · ' + review["reviewedAt"]) + '</p>'
            inner += action_form("publish", "发布当前版本", button_class="primary")
            if item["published"]:
                inner += action_form("withdraw", "撤回专辑与歌曲" if kind == "albums" else "撤回公共版本", button_class="danger")
            inner += '</div></section><section class="content-card"><div class="section-heading"><h2 class="section-title">版本历史</h2><p class="section-note">恢复后成为草稿</p></div><ul class="history-list">'
            for version in item["history"]:
                inner += '<li class="history-row"><h3 class="item-title">' + html.escape(ACTION_LABELS.get(version["operation"], version["operation"])) + '</h3><p class="history-meta">' + html.escape(version["createdAt"] + ' · ' + version["actor"]) + '</p>'
                inner += action_form("restore", "恢复为草稿", f'<input type="hidden" name="historyID" value="{version["historyID"]}">') + '</li>'
            inner += '</ul></section>'
        else:
            inner += '<section class="content-card action-card"><h2 class="section-title">先保存草稿</h2><p class="section-note">保存后可以预览内容、管理发布和查看版本历史。</p></section>'
        inner += '</aside></div>'
        return self.shell(session, section, title, inner)

    @staticmethod
    def decode_editor(kind, data):
        payload = {k: data.get(k, "") for k in ("title", "summary", "coverURL")}
        try:
            payload["sortOrder"] = int(data.get("sortOrder") or 0)
            if kind == "articles":
                if "referenceTitle" in data or "referenceURL" in data:
                    titles = data.get("referenceTitle", [])
                    urls = data.get("referenceURL", [])
                    titles = titles if isinstance(titles, list) else [titles]
                    urls = urls if isinstance(urls, list) else [urls]
                    if len(titles) != len(urls) or len(titles) > 30:
                        raise Invalid("参考来源须成对填写，最多 30 条")
                    refs = [{"title": title, "url": url} for title, url in zip(titles, urls) if title.strip() or url.strip()]
                else:
                    refs = json.loads(data.get("references", "[]"))
                payload.update(body=data.get("body"), category=data.get("category"), references=refs)
                if "bodyHTML" in data:
                    payload["bodyHTML"] = data["bodyHTML"]
            if kind == "tracks":
                payload.update({k: data.get(k, "") for k in ("albumID", "audioURL", "fileVersion", "sha256")})
                payload.update(durationSeconds=float(data.get("durationSeconds", "")), byteSize=int(data.get("byteSize", "")),
                               copyright={k: data.get(k, "") for k in ("owner", "source", "license", "expiresAt")})
        except Invalid:
            raise
        except (ValueError, TypeError, AttributeError):
            raise Invalid("数字或参考来源格式无效")
        return payload


SEED_TOPICS = [
    ("理解焦虑", "焦虑来临时，先认识自己的感受"), ("理解焦虑", "为什么不急着给自己贴标签"),
    ("身体感受", "身体不适时，怎样描述给专业人员"), ("身体感受", "心跳变化：记录观察而不自行诊断"),
    ("生活变化", "准备戒烟：先整理需要的支持"), ("生活变化", "减少咖啡因前，记录自己的日常习惯"),
    ("睡眠", "睡不着的一晚，怎样温和对待自己"), ("睡眠", "整理一个适合自己的睡前环境"),
    ("健康数据", "看健康趋势前，先看来源与采样时间"), ("健康数据", "HRV 数据的边界与适用条件"),
    ("健康数据", "缺少记录时，不补零也不猜测"), ("寻求支持", "第一次求助前，可以准备哪些问题"),
    ("寻求支持", "怎样向信任的人表达需要陪伴"), ("日常放松", "一分钟安静陪伴的使用说明"),
    ("日常放松", "选择适合当下的放松方式"), ("身体感受", "何时需要及时求助：待专业核实的清单"),
    ("睡眠", "声音陪伴与个人偏好"), ("理解焦虑", "记录感受与解释原因之间的区别")]


def seed(store):
    existing = {item["draft"]["title"] for item in store.list_admin() if item["kind"] == "articles"}
    for category, title in SEED_TOPICS:
        if title not in existing:
            store.save("articles", {"title": title, "summary": "编辑选题草稿 · 未经专业审核 · 不可发布", "category": category,
                                   "body": "【编辑提纲，未经专业审核】\n目标：形成一篇温和、准确的短篇支持内容。\n待撰写与核实：\n1. 为什么可能出现：说明适用范围、证据与不确定性，避免自行归因。\n2. 现在可以做什么：由专业审核人员核实可行建议与限制。\n3. 何时寻求专业帮助：由专业审核人员核实，不能以手表数据作诊断。\n4. 补齐可追溯参考来源、审核人及资质。\n此处只有选题与提纲，不构成医学建议，不代表已审核。", "references": []}, "seed_editorial_topics")


def main():
    parser = argparse.ArgumentParser(description="小晴空公共内容后台")
    parser.add_argument("--db", default=os.environ.get("QINGKONG_CONTENT_DB", "content.sqlite3"))
    parser.add_argument("--host", choices=("127.0.0.1", "0.0.0.0"), default="127.0.0.1",
                        help="默认仅本机；容器内使用 0.0.0.0，并通过宿主机反向代理访问")
    parser.add_argument("--port", type=int, default=8787)
    parser.add_argument("--seed-drafts", action="store_true")
    parser.add_argument("--hash-password", action="store_true")
    args = parser.parse_args()
    if args.hash_password:
        import getpass
        print(password_hash(getpass.getpass("管理员密码（至少 12 字符）：")))
        return
    store = Store(args.db)
    if args.seed_drafts:
        seed(store)
    server = AppServer((args.host, args.port), store, os.environ.get("QINGKONG_ADMIN_USERNAME", ""),
                       os.environ.get("QINGKONG_ADMIN_PASSWORD_HASH", ""), os.environ.get("QINGKONG_SESSION_SECRET", ""),
                       os.environ.get("QINGKONG_SECURE_COOKIES") == "1")
    print(f"小晴空公共内容服务：http://{args.host}:{server.server_port}/admin/login", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
