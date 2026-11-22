"""Bounded public HTTPS audio inspection; this module never imports the server."""
import hashlib
import http.client
import ipaddress
import math
import multiprocessing
import os
import queue
import re
import socket
import ssl
import sys
import tempfile
import threading
import time
from pathlib import PurePosixPath
from urllib.parse import parse_qs, unquote, urljoin, urlsplit

import mutagen


MAX_BYTES = 200 * 1024 * 1024
TOTAL_TIMEOUT = 60.0
CONNECT_TIMEOUT = 10.0
READ_TIMEOUT = 10.0
DNS_TIMEOUT = 5.0
MAX_REDIRECTS = 3
PARSER_MEMORY_BYTES = 128 * 1024 * 1024
_INSPECTIONS = threading.BoundedSemaphore(2)
_DNS_SLOTS = threading.BoundedSemaphore(2)


class MediaInspectionError(ValueError):
    """An inspection failure safe to display to the editor."""


def _remaining(deadline):
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        raise MediaInspectionError("音频识别超时，请稍后重试或手动填写")
    return remaining


def _public_ip(value):
    try:
        address = ipaddress.ip_address(value)
    except ValueError:
        return False
    return (address.is_global and not address.is_multicast and not address.is_reserved
            and not address.is_loopback and not address.is_link_local and not address.is_unspecified)


def _validated_url(url):
    if (not isinstance(url, str) or not url or len(url) > 2048
            or any(c.isspace() or ord(c) < 32 or ord(c) == 127 for c in url)):
        raise MediaInspectionError("请填写有效的长期 HTTPS 音频链接")
    try:
        parts = urlsplit(url)
        host, port = parts.hostname, parts.port
    except ValueError:
        raise MediaInspectionError("音频链接格式无效") from None
    if (parts.scheme != "https" or not host or parts.username is not None
            or parts.password is not None or parts.fragment or "#" in url or port not in (None, 443)):
        raise MediaInspectionError("音频链接须使用 HTTPS，不能含凭据、片段或非标准端口")
    host = host.rstrip(".").lower()
    if not host or host == "localhost" or host.endswith((".localhost", ".local")):
        raise MediaInspectionError("音频链接必须指向公网地址")
    try:
        ipaddress.ip_address(host)
    except ValueError:
        try:
            host = host.encode("idna").decode("ascii")
        except UnicodeError:
            raise MediaInspectionError("音频链接域名无效") from None
        if len(host) > 253 or not all(re.fullmatch(r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?", label) for label in host.split(".")):
            raise MediaInspectionError("音频链接域名无效")
    else:
        if not _public_ip(host):
            raise MediaInspectionError("音频链接必须指向公网地址，不能访问内网或保留 IP")
    transient = {"expires", "expiry", "signature", "sig", "token", "security-token", "auth_key",
                 "ossaccesskeyid", "access_token", "auth", "authorization", "api_key", "apikey",
                 "api-key", "key", "policy", "key-pair-id"}
    for key in parse_qs(parts.query, keep_blank_values=True):
        low = key.lower()
        if low in transient or low.startswith(("x-amz-", "x-oss-", "x-goog-")):
            raise MediaInspectionError("请使用长期音频地址，不能含临时签名或令牌")
    return parts, host


def _resolve(host, deadline):
    """Bound DNS waiting and worker count, including a stalled OS resolver."""
    if not _DNS_SLOTS.acquire(blocking=False):
        raise MediaInspectionError("域名解析繁忙，请稍后重试")
    results = queue.Queue(maxsize=1)

    def resolve():
        try:
            results.put((True, socket.getaddrinfo(host, 443, type=socket.SOCK_STREAM)))
        except Exception as error:
            results.put((False, error))
        finally:
            _DNS_SLOTS.release()

    threading.Thread(target=resolve, daemon=True, name="audio-dns").start()
    try:
        success, addresses = results.get(timeout=min(DNS_TIMEOUT, _remaining(deadline)))
    except queue.Empty:
        raise MediaInspectionError("音频域名解析超时，请稍后重试") from None
    if not success:
        raise MediaInspectionError("无法解析音频域名，请检查链接") from None
    if not addresses or any(item[0] not in (socket.AF_INET, socket.AF_INET6)
                            or not _public_ip(item[4][0]) for item in addresses):
        raise MediaInspectionError("音频域名必须全部解析到公网地址")
    family, _, _, _, address = addresses[0]
    return family, address


class _PinnedHTTPSConnection(http.client.HTTPSConnection):
    """Connect to one verified address while preserving host/SNI/certificate checks."""
    def __init__(self, host, family, address, deadline):
        super().__init__(host, port=443, timeout=min(CONNECT_TIMEOUT, _remaining(deadline)),
                         context=ssl.create_default_context())
        self._family = family
        self._address = address
        self._deadline = deadline
        self._opening_socket = None
        self._active_socket = None
        self._timer = threading.Timer(_remaining(deadline), self._abort)
        self._timer.daemon = True
        self._timer.start()

    def _abort(self):
        # shutdown interrupts a peer sending headers or body bytes indefinitely.
        current = self._active_socket
        if current is not None:
            try:
                current.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            current.close()

    def connect(self):
        raw = socket.socket(self._family, socket.SOCK_STREAM)
        self._opening_socket = raw
        self._active_socket = raw
        try:
            raw.settimeout(min(CONNECT_TIMEOUT, _remaining(self._deadline)))
            raw.connect(self._address)
            raw.settimeout(min(CONNECT_TIMEOUT, _remaining(self._deadline)))
            self.sock = self._context.wrap_socket(raw, server_hostname=self.host)
            self._active_socket = self.sock
            self._opening_socket = None
            self.sock.settimeout(min(READ_TIMEOUT, _remaining(self._deadline)))
        except Exception:
            raw.close()
            raise

    def close(self):
        # getresponse() may call close() before the response body has finished.
        # Keep the watchdog and its socket reference until explicit finish().
        super().close()
        if self._opening_socket is not None:
            self._opening_socket.close()
            self._opening_socket = None

    def finish(self):
        self._timer.cancel()
        self.close()
        self._active_socket = None


def _download(url, destination, deadline):
    for redirect in range(MAX_REDIRECTS + 1):
        _remaining(deadline)
        parts, host = _validated_url(url)
        family, address = _resolve(host, deadline)
        connection = _PinnedHTTPSConnection(host, family, address, deadline)
        response = None
        try:
            # http.client does not read HTTP(S)_PROXY or redirect automatically.
            target = parts.path or "/"
            if parts.query:
                target += "?" + parts.query
            connection.request("GET", target, headers={"Accept-Encoding": "identity", "User-Agent": "QingkongMediaInspector/1", "Connection": "close"})
            response = connection.getresponse()
            _remaining(deadline)
            if response.status in (301, 302, 303, 307, 308):
                location = response.getheader("Location")
                if not location or redirect == MAX_REDIRECTS:
                    raise MediaInspectionError("音频链接重定向过多或缺少目标地址")
                url = urljoin(url, location)
                continue
            if response.status != 200:
                raise MediaInspectionError(f"音频服务器返回 HTTP {response.status}，请检查链接")
            if response.getheader("Content-Encoding", "identity").lower() not in ("", "identity"):
                raise MediaInspectionError("音频服务器返回了压缩传输内容，请提供直接文件链接")
            length = response.getheader("Content-Length")
            if length is not None:
                try:
                    length = int(length)
                except ValueError:
                    raise MediaInspectionError("音频服务器返回的文件大小无效") from None
                if length < 0:
                    raise MediaInspectionError("音频服务器返回的文件大小无效")
                if length > MAX_BYTES:
                    raise MediaInspectionError("音频文件超过 200 MiB，无法自动识别")
            digest, size = hashlib.sha256(), 0
            while True:
                _remaining(deadline)
                chunk = response.read1(64 * 1024)
                _remaining(deadline)
                if not chunk:
                    break
                size += len(chunk)
                if size > MAX_BYTES:
                    raise MediaInspectionError("音频文件超过 200 MiB，无法自动识别")
                digest.update(chunk)
                destination.write(chunk)
            if not size:
                raise MediaInspectionError("链接返回空文件，无法读取音频")
            if length is not None and size != length:
                raise MediaInspectionError("音频文件下载不完整，请稍后重试")
            destination.flush()
            return url, size, digest.hexdigest()
        finally:
            if response is not None:
                response.close()
            connection.finish()


def _tag_text(value, limit):
    if isinstance(value, (list, tuple)):
        return next((text for item in value if (text := _tag_text(item, limit))), "")
    if hasattr(value, "text"):
        return _tag_text(value.text, limit)
    if hasattr(value, "url"):
        return _tag_text(value.url, limit)
    if hasattr(value, "value"):
        return _tag_text(value.value, limit)
    if isinstance(value, bytes):
        value = value.decode("utf-8", errors="replace")
    if not isinstance(value, str):
        return ""
    return "".join(c for c in value if ord(c) >= 32 or c in "\n\r\t").strip()[:limit]


def _metadata(path, url):
    try:
        audio = mutagen.File(path)
        duration = float(audio.info.length) if audio is not None else 0.0
    except MemoryError:
        raise
    except Exception:
        raise MediaInspectionError("无法读取音频格式或时长，请提供有效的音频文件链接") from None
    if not math.isfinite(duration) or duration <= 0:
        raise MediaInspectionError("文件不包含可识别的有效音频时长")
    tags = {}
    if audio.tags is not None:
        for key, value in audio.tags.items():
            normalized = key.lower()
            # ID3 user text and MP4 free-form names retain their embedded field name.
            if normalized.startswith("txxx:"):
                normalized = normalized[5:]
            elif normalized.startswith("----:com.apple.itunes:"):
                normalized = normalized.rsplit(":", 1)[-1]
            tags.setdefault(normalized, value)

    def first(keys, limit):
        for key in keys:
            for name, value in tags.items():
                if name == key or (key == "comm" and name.startswith("comm:")):
                    text = _tag_text(value, limit)
                    if text:
                        return text
        return ""

    filename = PurePosixPath(unquote(urlsplit(url).path)).stem
    title = first(("tit2", "title", "©nam", "wm/title"), 200) or _tag_text(filename, 200) or "未命名音频"
    return {"title": title, "summary": first(("description", "comment", "comm", "©cmt", "wm/description"), 1000),
            "durationSeconds": duration,
            "copyright": {"owner": first(("tcop", "copyright", "cprt", "©cpy", "wm/copyright"), 500),
                          "source": first(("wcop", "copyrighturl", "copyright_url", "licenseurl", "license_url", "source"), 2000),
                          "license": first(("license", "licence", "wm/license"), 2000), "expiresAt": None}}


def _metadata_worker(path, url, sender):
    try:
        if sys.platform.startswith("linux"):
            # A small compressed ID3 frame can expand far beyond the download
            # limit. Bound the entire parser, including native zlib allocations.
            # macOS reserves large virtual regions and cannot use this limit.
            import resource
            resource.setrlimit(resource.RLIMIT_AS, (PARSER_MEMORY_BYTES, PARSER_MEMORY_BYTES))
        sender.send((True, _metadata(path, url)))
    except MemoryError:
        sender.send((False, "音频元数据超过内存限制，请精简文件标签后重试或手动填写"))
    except Exception:
        sender.send((False, "无法读取音频格式或时长，请提供有效的音频文件链接"))
    finally:
        sender.close()


def _inspect_metadata(path, url, deadline):
    # Untrusted parser work is isolated so a malformed file cannot exhaust the
    # request deadline or leave a parsing thread running after its temporary file.
    _remaining(deadline)
    context = multiprocessing.get_context("spawn")
    receiver, sender = context.Pipe(duplex=False)
    process = context.Process(target=_metadata_worker, args=(path, url, sender), daemon=True)
    started = False
    try:
        process.start()
        started = True
        sender.close()
        if not receiver.poll(_remaining(deadline)):
            raise MediaInspectionError("音频解析超时，请稍后重试或手动填写")
        try:
            success, result = receiver.recv()
        except EOFError:
            raise MediaInspectionError("无法读取音频文件，请检查音频格式") from None
        if not success:
            raise MediaInspectionError(result)
        _remaining(deadline)
        return result
    finally:
        receiver.close()
        sender.close()
        if started:
            if process.is_alive():
                process.terminate()
            process.join(timeout=.5)
            if process.is_alive():
                process.kill()
                process.join(timeout=.5)
            process.close()


def inspect_media(url: str) -> dict:
    """Download and inspect audio; unknown copyright fields remain empty strings."""
    if not _INSPECTIONS.acquire(blocking=False):
        raise MediaInspectionError("音频识别繁忙，最多同时识别两个链接，请稍后重试")
    path = None
    deadline = time.monotonic() + TOTAL_TIMEOUT
    try:
        _validated_url(url)
        _remaining(deadline)
        with tempfile.NamedTemporaryFile(prefix="qingkong-media-", suffix=".audio", delete=False) as file:
            path = file.name
            final_url, size, checksum = _download(url, file, deadline)
        _remaining(deadline)
        result = _inspect_metadata(path, final_url, deadline)
        _remaining(deadline)
        result.update(byteSize=size, sha256=checksum, fileVersion="sha256-" + checksum[:12])
        return result
    except MediaInspectionError:
        raise
    except (TimeoutError, socket.timeout):
        raise MediaInspectionError("音频识别连接或读取超时，请稍后重试") from None
    except (OSError, http.client.HTTPException, ValueError, UnicodeError):
        if time.monotonic() >= deadline:
            raise MediaInspectionError("音频识别超时，请稍后重试") from None
        raise MediaInspectionError("无法安全下载音频，请检查公开 HTTPS 链接及服务器证书") from None
    finally:
        if path is not None:
            try:
                os.unlink(path)
            except FileNotFoundError:
                pass
        _INSPECTIONS.release()
