import hashlib
import io
import os
import resource
import socket
import struct
import sys
import tempfile
import time
import unittest
import wave
import zlib
from unittest.mock import Mock, patch

from mutagen.id3 import COMM, TCOP, TIT2, TXXX, WCOP
from mutagen.wave import WAVE

from ContentService import media_inspection as media


def wav_bytes(tagged=False):
    output = io.BytesIO()
    with wave.open(output, "wb") as audio:
        audio.setnchannels(1)
        audio.setsampwidth(2)
        audio.setframerate(8000)
        audio.writeframes(b"\0\0" * 12000)
    if not tagged:
        return output.getvalue()
    with tempfile.NamedTemporaryFile(suffix=".wav") as file:
        file.write(output.getvalue())
        file.flush()
        audio = WAVE(file.name)
        audio.add_tags()
        audio.tags.add(TIT2(encoding=3, text=["本地测试音轨"]))
        audio.tags.add(COMM(encoding=3, lang="zho", desc="", text=["真实内嵌摘要"]))
        audio.tags.add(TCOP(encoding=3, text=["测试版权归属声明"]))
        audio.tags.add(WCOP(url="https://example.org/rights"))
        audio.tags.add(TXXX(encoding=3, desc="LICENSE", text=["CC0-1.0"]))
        audio.save()
        file.seek(0)
        return file.read()


def compressed_tag_wav(expanded_bytes):
    """Create a real compressed ID3v2.3 title without allocating its expansion."""
    compressor = zlib.compressobj()
    compressed = [compressor.compress(b"\x00")]
    block = b"A" * (64 * 1024)
    remaining = expanded_bytes - 1
    while remaining:
        count = min(remaining, len(block))
        compressed.append(compressor.compress(block[:count]))
        remaining -= count
    compressed.append(compressor.flush())
    payload = struct.pack(">I", expanded_bytes) + b"".join(compressed)
    frame = b"TIT2" + struct.pack(">I", len(payload)) + b"\x00\x80" + payload
    size = len(frame)
    syncsafe_size = bytes((size >> 21 & 127, size >> 14 & 127, size >> 7 & 127, size & 127))
    tag = b"ID3\x03\x00\x00" + syncsafe_size + frame
    body = wav_bytes()[8:] + b"id3 " + struct.pack("<I", len(tag)) + tag
    if len(tag) % 2:
        body += b"\x00"
    return b"RIFF" + struct.pack("<I", len(body)) + body


class Response:
    def __init__(self, data=b"", status=200, headers=None):
        self.data = io.BytesIO(data)
        self.status = status
        self.headers = headers or {}

    def getheader(self, key, default=None):
        return self.headers.get(key, default)

    def read1(self, size):
        return self.data.read(size)

    def close(self):
        self.data.close()


class InspectionTests(unittest.TestCase):
    def setUp(self):
        self.connections = []
        self.responses = [Response(wav_bytes())]
        self.dns = patch.object(media.socket, "getaddrinfo", return_value=[
            (socket.AF_INET, socket.SOCK_STREAM, 6, "", ("93.184.216.34", 443))
        ])
        self.dns.start()
        self.addCleanup(self.dns.stop)

        owner = self

        class Connection:
            def __init__(self, host, family, address, deadline):
                self.host, self.address = host, address
                self.closed = False
                owner.connections.append(self)

            def request(self, method, path, headers):
                self.requested = (method, path, headers)

            def getresponse(self):
                return owner.responses.pop(0)

            def close(self):
                self.closed = True

            def finish(self):
                self.close()

        self.connection = patch.object(media, "_PinnedHTTPSConnection", Connection)
        self.connection.start()
        self.addCleanup(self.connection.stop)

    def test_real_wav_hash_size_duration_filename_and_unknown_rights(self):
        data = wav_bytes()
        result = media.inspect_media("https://example.org/%E9%9B%A8%E5%A3%B0.wav")
        self.assertEqual(result["title"], "雨声")
        self.assertEqual(result["summary"], "")
        self.assertAlmostEqual(result["durationSeconds"], 1.5)
        self.assertEqual(result["byteSize"], len(data))
        self.assertEqual(result["sha256"], hashlib.sha256(data).hexdigest())
        self.assertEqual(result["fileVersion"], "sha256-" + hashlib.sha256(data).hexdigest()[:12])
        self.assertEqual(result["copyright"], {"owner": "", "source": "", "license": "", "expiresAt": None})
        self.assertEqual(self.connections[0].address, ("93.184.216.34", 443))
        self.assertTrue(self.connections[0].closed)

    def test_embedded_tags_are_read_from_actual_audio(self):
        self.responses = [Response(wav_bytes(tagged=True))]
        result = media.inspect_media("https://example.org/audio.wav")
        self.assertEqual(result["title"], "本地测试音轨")
        self.assertEqual(result["summary"], "真实内嵌摘要")
        self.assertEqual(result["copyright"], {"owner": "测试版权归属声明", "source": "https://example.org/rights", "license": "CC0-1.0", "expiresAt": None})

    def test_artist_does_not_imply_copyright(self):
        data = wav_bytes(tagged=True)
        with tempfile.NamedTemporaryFile(suffix=".wav") as file:
            file.write(data)
            file.flush()
            audio = WAVE(file.name)
            audio.tags.delall("TCOP")
            audio.tags.delall("WCOP")
            audio.tags.delall("TXXX")
            from mutagen.id3 import TPE1
            audio.tags.add(TPE1(encoding=3, text=["测试歌手"]))
            audio.save()
            file.seek(0)
            self.responses = [Response(file.read())]
        result = media.inspect_media("https://example.org/audio.wav")
        self.assertEqual(result["copyright"]["owner"], "")
        self.assertEqual(result["copyright"]["license"], "")

    def test_invalid_or_empty_audio_is_rejected_and_temp_removed(self):
        for data in (b"", b"<html>not audio</html>"):
            self.responses = [Response(data)]
            paths = []
            original = tempfile.NamedTemporaryFile

            def temporary(*args, **kwargs):
                file = original(*args, **kwargs)
                paths.append(file.name)
                return file

            with patch.object(media.tempfile, "NamedTemporaryFile", temporary):
                with self.assertRaisesRegex(media.MediaInspectionError, "音频"):
                    media.inspect_media("https://example.org/audio.wav")
            self.assertTrue(paths)
            self.assertTrue(all(not os.path.exists(path) for path in paths))

    def test_unsafe_urls_are_rejected_before_network(self):
        urls = ["http://example.org/a", "https://name:pass@example.org/a", "https://example.org:8443/a",
                "https://example.org/a#fragment", "https://localhost/a", "https://127.0.0.1/a",
                "https://[::1]/a", "https://10.0.0.1/a", "https://169.254.169.254/a",
                "https://192.0.2.1/a", "https://example.org/a?token=secret",
                "https://example.org/a?X-Amz-Signature=secret", "https://example.org/a?sig=secret",
                "https://example.org/a?%74oken=secret", "https://example.org/a\r\nX:bad"]
        for url in urls:
            with self.subTest(url=url), self.assertRaises(media.MediaInspectionError):
                media.inspect_media(url)
        self.assertEqual(self.connections, [])

    def test_all_dns_addresses_must_be_global(self):
        with patch.object(media.socket, "getaddrinfo", return_value=[
            (socket.AF_INET, socket.SOCK_STREAM, 6, "", ("93.184.216.34", 443)),
            (socket.AF_INET, socket.SOCK_STREAM, 6, "", ("10.0.0.1", 443)),
        ]):
            with self.assertRaisesRegex(media.MediaInspectionError, "公网"):
                media.inspect_media("https://example.org/audio.wav")
        self.assertEqual(self.connections, [])

    def test_redirect_revalidates_destination_and_limits_three_hops(self):
        self.responses = [Response(status=302, headers={"Location": "https://127.0.0.1/a"})]
        with self.assertRaises(media.MediaInspectionError):
            media.inspect_media("https://example.org/audio.wav")
        self.assertEqual(len(self.connections), 1)
        self.responses = [Response(status=302, headers={"Location": "/next"}) for _ in range(4)]
        with self.assertRaisesRegex(media.MediaInspectionError, "重定向"):
            media.inspect_media("https://example.org/audio.wav")
        self.assertEqual(len(self.connections), 5)

    def test_successful_relative_redirect_keeps_real_audio_result(self):
        self.responses = [Response(status=302, headers={"Location": "/final.wav"}), Response(wav_bytes())]
        result = media.inspect_media("https://example.org/start")
        self.assertEqual(result["title"], "final")
        self.assertEqual(len(self.connections), 2)

    def test_dns_is_checked_again_for_same_host_after_redirect(self):
        self.responses = [Response(status=302, headers={"Location": "/final.wav"}), Response(wav_bytes())]
        with patch.object(media.socket, "getaddrinfo", side_effect=[
            [(socket.AF_INET, socket.SOCK_STREAM, 6, "", ("93.184.216.34", 443))],
            [(socket.AF_INET, socket.SOCK_STREAM, 6, "", ("127.0.0.1", 443))],
        ]):
            with self.assertRaisesRegex(media.MediaInspectionError, "公网"):
                media.inspect_media("https://example.org/start")
        self.assertEqual(len(self.connections), 1)

    def test_dns_wait_has_a_deadline(self):
        import threading
        released = threading.Event()

        def slow_dns(*args, **kwargs):
            released.wait(2)
            return []

        try:
            with patch.object(media.socket, "getaddrinfo", slow_dns), patch.object(media, "DNS_TIMEOUT", .01):
                start = time.monotonic()
                with self.assertRaisesRegex(media.MediaInspectionError, "解析超时"):
                    media.inspect_media("https://example.org/audio.wav")
                self.assertLess(time.monotonic() - start, 1)
        finally:
            released.set()

    def test_metadata_parser_respects_overall_deadline(self):
        with tempfile.NamedTemporaryFile(suffix=".wav") as file:
            file.write(wav_bytes())
            file.flush()
            with self.assertRaisesRegex(media.MediaInspectionError, "超时"):
                media._inspect_metadata(file.name, "https://example.org/audio.wav", time.monotonic() - 1)

    def test_declared_and_streamed_size_limits(self):
        self.responses = [Response(headers={"Content-Length": str(200 * 1024 * 1024 + 1)})]
        with self.assertRaisesRegex(media.MediaInspectionError, "200 MiB"):
            media.inspect_media("https://example.org/audio.wav")
        self.responses = [Response(wav_bytes())]
        with patch.object(media, "MAX_BYTES", 32), self.assertRaises(media.MediaInspectionError):
            media.inspect_media("https://example.org/audio.wav")

    def test_network_timeout_and_deadline_have_readable_errors(self):
        with patch.object(media._PinnedHTTPSConnection, "getresponse", side_effect=TimeoutError):
            with self.assertRaisesRegex(media.MediaInspectionError, "超时"):
                media.inspect_media("https://example.org/audio.wav")
        with patch.object(media, "TOTAL_TIMEOUT", -1):
            with self.assertRaisesRegex(media.MediaInspectionError, "超时"):
                media.inspect_media("https://example.org/audio.wav")

    def test_concurrency_is_limited_to_two(self):
        self.assertTrue(media._INSPECTIONS.acquire(blocking=False))
        self.assertTrue(media._INSPECTIONS.acquire(blocking=False))
        try:
            with self.assertRaisesRegex(media.MediaInspectionError, "繁忙"):
                media.inspect_media("https://example.org/audio.wav")
        finally:
            media._INSPECTIONS.release()
            media._INSPECTIONS.release()


class PinnedConnectionTests(unittest.TestCase):
    def test_deadline_can_abort_response_after_http_client_closes_connection(self):
        # HTTPConnection.getresponse closes its own socket reference when a
        # response has Connection: close; the response's file still owns it.
        with patch.object(media.socket, "socket"), patch.object(media.ssl, "create_default_context") as context:
            connection = media._PinnedHTTPSConnection("audio.example.org", socket.AF_INET, ("93.184.216.34", 443), time.monotonic() + 60)
            try:
                connection.connect()
                connection.close()
                connection._abort()
                context.return_value.wrap_socket.return_value.shutdown.assert_called_once_with(socket.SHUT_RDWR)
            finally:
                connection.finish()

    def test_socket_uses_validated_ip_but_tls_validates_original_host(self):
        with patch.object(media.socket, "socket") as socket_type, patch.object(media.ssl, "create_default_context") as context:
            import time
            connection = media._PinnedHTTPSConnection("audio.example.org", socket.AF_INET, ("93.184.216.34", 443), time.monotonic() + 60)
            try:
                connection.connect()
                socket_type.return_value.connect.assert_called_once_with(("93.184.216.34", 443))
                context.return_value.wrap_socket.assert_called_once_with(socket_type.return_value, server_hostname="audio.example.org")
                context.assert_called_once_with()
            finally:
                connection.finish()


class ParserMemoryLimitTests(unittest.TestCase):
    def test_linux_worker_hard_limits_address_space_before_parsing_audio(self):
        with tempfile.NamedTemporaryFile(suffix=".wav") as file:
            file.write(compressed_tag_wav(8 * 1024 * 1024))
            file.flush()
            sender = Mock()
            with patch.object(sys, "platform", "linux"), patch.object(resource, "setrlimit") as limit:
                media._metadata_worker(file.name, "https://example.org/audio.wav", sender)
            limit.assert_called_once_with(resource.RLIMIT_AS, (128 * 1024 * 1024, 128 * 1024 * 1024))
            success, result = sender.send.call_args[0][0]
            self.assertTrue(success)
            self.assertEqual(result["title"], "A" * 200)
            self.assertAlmostEqual(result["durationSeconds"], 1.5)
            sender.close.assert_called_once_with()

    def test_mac_worker_does_not_limit_its_large_virtual_address_space(self):
        with tempfile.NamedTemporaryFile(suffix=".wav") as file:
            file.write(wav_bytes())
            file.flush()
            sender = Mock()
            with patch.object(sys, "platform", "darwin"), patch.object(resource, "setrlimit") as limit:
                media._metadata_worker(file.name, "https://example.org/audio.wav", sender)
            limit.assert_not_called()
            self.assertTrue(sender.send.call_args[0][0][0])

    @unittest.skipUnless(sys.platform.startswith("linux"), "真实 RLIMIT_AS 解析回归仅适用于 Linux")
    def test_real_linux_parser_rejects_compressed_id3_memory_bomb(self):
        with tempfile.NamedTemporaryFile(suffix=".wav") as file:
            data = compressed_tag_wav(256 * 1024 * 1024)
            self.assertLess(len(data), 1024 * 1024)
            file.write(data)
            file.flush()
            with self.assertRaisesRegex(media.MediaInspectionError, "内存"):
                media._inspect_metadata(file.name, "https://example.org/audio.wav", time.monotonic() + 10)


if __name__ == "__main__":
    unittest.main()
