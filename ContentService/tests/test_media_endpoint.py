"""Exercise media-inspection authentication and persistence through real HTTP."""
import copy
import http.client
import json
import re
import tempfile
import threading
import unittest
from pathlib import Path
from unittest.mock import patch

from ContentService.media_inspection import MediaInspectionError
from ContentService.server import AppServer, Store, password_hash


class MediaEndpointTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.encoded = password_hash("A local media endpoint test password!")

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.store = Store(str(Path(self.directory.name) / "test.sqlite3"))
        self.store.save("albums", {"title": "已有专辑", "summary": "保持原内容"}, "fixture")
        self.server = AppServer(("127.0.0.1", 0), self.store, "editor", self.encoded, "test-media-secret-" * 4)
        self.addCleanup(self.server.server_close)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.addCleanup(self.stop_server)
        self.cookie = None
        self.csrf = None
        self.url = "https://media.example.org/test.wav"
        self.result = {"title": "测试音乐", "summary": "文件标签摘要", "durationSeconds": 1.5,
                       "byteSize": 24044, "sha256": "a" * 64, "fileVersion": "sha256-" + "a" * 12,
                       "copyright": {"owner": "", "source": "", "license": "", "expiresAt": None}}

    def stop_server(self):
        self.server.shutdown()
        self.thread.join(timeout=5)

    def request(self, method, path, data=None, *, auth=True, csrf=True, origin=None):
        headers = {}
        if auth and self.cookie:
            headers["Cookie"] = self.cookie
        if csrf and self.csrf:
            headers["X-CSRF-Token"] = self.csrf
        if origin is not None:
            headers["Origin"] = origin
        body = None
        if data is not None:
            body = json.dumps(data, ensure_ascii=False).encode()
            headers["Content-Type"] = "application/json"
        connection = http.client.HTTPConnection("127.0.0.1", self.server.server_port, timeout=5)
        try:
            connection.request(method, path, body, headers)
            response = connection.getresponse()
            raw = response.read().decode()
            response_headers = dict(response.getheaders())
            if response_headers.get("Content-Type", "").startswith("application/json"):
                raw = json.loads(raw)
            return response.status, raw, response_headers
        finally:
            connection.close()

    def login(self):
        status, page, headers = self.request("GET", "/admin/login", auth=False)
        self.assertEqual(status, 200)
        self.cookie = headers["Set-Cookie"].split(";", 1)[0]
        self.csrf = re.search(r'name="csrf" value="([^\"]+)"', page)[1]
        status, _, headers = self.request("POST", "/admin/login", {
            "username": "editor", "password": "A local media endpoint test password!"})
        self.assertEqual(status, 303)
        self.cookie = headers["Set-Cookie"].split(";", 1)[0]
        status, session, _ = self.request("GET", "/admin/api/session")
        self.assertEqual(status, 200)
        self.csrf = session["csrfToken"]

    def database_dump(self):
        with self.store.connect() as database:
            return "\n".join(database.iterdump())

    def test_anonymous_gets_401_without_invoking_inspection(self):
        before = self.database_dump()
        with patch("ContentService.server.inspect_media") as inspect:
            status, result, _ = self.request("POST", "/admin/api/media/inspect", {"url": self.url}, auth=False)
        self.assertEqual(status, 401)
        self.assertIn("error", result)
        inspect.assert_not_called()
        self.assertEqual(self.database_dump(), before)

    def test_missing_csrf_gets_403_without_invoking_inspection(self):
        self.login()
        before = self.database_dump()
        with patch("ContentService.server.inspect_media") as inspect:
            status, result, _ = self.request("POST", "/admin/api/media/inspect", {"url": self.url}, csrf=False)
        self.assertEqual(status, 403)
        self.assertIn("error", result)
        inspect.assert_not_called()
        self.assertEqual(self.database_dump(), before)

    def test_wrong_origin_gets_403_without_invoking_inspection(self):
        self.login()
        before = self.database_dump()
        with patch("ContentService.server.inspect_media") as inspect:
            status, result, _ = self.request("POST", "/admin/api/media/inspect", {"url": self.url}, origin="https://wrong.example.org")
        self.assertEqual(status, 403)
        self.assertIn("error", result)
        inspect.assert_not_called()
        self.assertEqual(self.database_dump(), before)

    def test_authenticated_inspection_returns_helper_result_without_writes(self):
        self.login()
        before = self.database_dump()
        expected = copy.deepcopy(self.result)
        with patch("ContentService.server.inspect_media", return_value=expected) as inspect:
            status, result, headers = self.request("POST", "/admin/api/media/inspect", {"url": self.url},
                                                 origin=f"http://127.0.0.1:{self.server.server_port}")
        self.assertEqual(status, 200)
        self.assertEqual(result, expected)
        self.assertTrue(headers["Content-Type"].startswith("application/json"))
        self.assertEqual(headers["Cache-Control"], "no-store")
        inspect.assert_called_once_with(self.url)
        self.assertEqual(self.database_dump(), before)

    def test_inspection_error_returns_400_without_writes(self):
        self.login()
        before = self.database_dump()
        with patch("ContentService.server.inspect_media", side_effect=MediaInspectionError("音频文件无法识别")) as inspect:
            status, result, _ = self.request("POST", "/admin/api/media/inspect", {"url": self.url})
        self.assertEqual(status, 400)
        self.assertEqual(result, {"error": "音频文件无法识别"})
        inspect.assert_called_once_with(self.url)
        self.assertEqual(self.database_dump(), before)

    def test_unknown_fields_are_rejected_before_inspection(self):
        self.login()
        before = self.database_dump()
        for key in ("albumID", "sha256", "unrecognized"):
            with self.subTest(key=key), patch("ContentService.server.inspect_media") as inspect:
                status, result, _ = self.request("POST", "/admin/api/media/inspect", {"url": self.url, key: "unexpected"})
                self.assertEqual(status, 400)
                self.assertIn("error", result)
                inspect.assert_not_called()
        self.assertEqual(self.database_dump(), before)


if __name__ == "__main__":
    unittest.main()
