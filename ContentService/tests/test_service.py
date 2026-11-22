import copy
import http.client
import json
import re
import tempfile
import threading
import unittest
from pathlib import Path
from urllib.parse import urlencode

from ContentService.server import AppServer, Invalid, Store, https_url, password_hash, seed


class ServiceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.encoded = password_hash("A local test password 2026!")

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.db_path = str(Path(self.directory.name) / "test.sqlite3")
        self.store = Store(self.db_path)
        self.server = AppServer(("127.0.0.1", 0), self.store, "editor", self.encoded, "test-secret-" * 4)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.cookie = None
        self.csrf = None

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()
        self.directory.cleanup()

    def request(self, method, path, data=None, auth=True, csrf=True, extra=None):
        connection = http.client.HTTPConnection("127.0.0.1", self.server.server_port, timeout=5)
        headers = {}
        if auth and self.cookie:
            headers["Cookie"] = self.cookie
        if csrf and self.csrf:
            headers["X-CSRF-Token"] = self.csrf
        if extra:
            headers.update(extra)
        body = None
        if data is not None:
            body = json.dumps(data, ensure_ascii=False).encode()
            headers["Content-Type"] = "application/json"
        connection.request(method, path, body, headers)
        response = connection.getresponse()
        raw = response.read().decode()
        response_headers = dict(response.getheaders())
        connection.close()
        if response_headers.get("Content-Type", "").startswith("application/json"):
            raw = json.loads(raw)
        return response.status, raw, response_headers

    def login(self):
        status, page, headers = self.request("GET", "/admin/login", auth=False)
        self.assertEqual(status, 200)
        self.cookie = headers["Set-Cookie"].split(";", 1)[0]
        self.csrf = re.search(r'name="csrf" value="([^"]+)"', page)[1]
        status, _, headers = self.request("POST", "/admin/login", {"username": "editor", "password": "A local test password 2026!"})
        self.assertEqual(status, 303)
        self.assertIn("HttpOnly", headers["Set-Cookie"])
        self.assertIn("SameSite=Strict", headers["Set-Cookie"])
        self.cookie = headers["Set-Cookie"].split(";", 1)[0]
        status, session, _ = self.request("GET", "/admin/api/session")
        self.assertEqual(status, 200)
        self.csrf = session["csrfToken"]

    def article(self, title="测试文章"):
        return {"title": title, "summary": "编辑摘要", "body": "经过编辑核实的测试正文，不构成医疗建议。", "category": "理解焦虑",
                "references": [{"title": "编辑测试来源", "url": "https://example.org/reference"}], "sortOrder": 1}

    def create(self, kind, payload):
        status, item, _ = self.request("POST", f"/admin/api/content/{kind}", payload)
        self.assertEqual(status, 201, item)
        return item

    def action(self, item, action, payload=None, expected=200):
        status, result, _ = self.request("POST", f'/admin/api/content/{item["kind"]}/{item["id"]}/{action}', payload or {})
        self.assertEqual(status, expected, result)
        return result

    def review_publish(self, item):
        self.action(item, "submit")
        self.action(item, "review", {"reviewer": "测试审核员", "credentials": "测试专业审核声明", "confirmed": True})
        return self.action(item, "publish")

    def snapshot(self):
        status, result, _ = self.request("GET", "/api/v1/snapshot", auth=False)
        self.assertEqual(status, 200)
        return result

    def test_anonymous_cannot_access_admin_or_write_and_no_health_endpoint(self):
        for path in ("/admin", "/admin/api/content", "/admin/api/session", "/admin/edit"):
            self.assertEqual(self.request("GET", path, auth=False)[0], 401)
        self.assertEqual(self.request("POST", "/admin/api/content/articles", self.article(), auth=False)[0], 401)
        self.assertEqual(self.request("POST", "/api/health", {"heartRate": 80}, auth=False)[0], 404)

    def test_login_requires_csrf_and_rate_limits(self):
        self.assertEqual(self.request("POST", "/admin/login", {"username": "editor", "password": "bad"}, auth=False)[0], 401)
        _, page, headers = self.request("GET", "/admin/login")
        self.cookie = headers["Set-Cookie"].split(";", 1)[0]
        self.csrf = re.search(r'name="csrf" value="([^"]+)"', page)[1]
        self.assertEqual(self.request("POST", "/admin/login", {"username": "editor", "password": "bad"}, csrf=False)[0], 403)
        for _ in range(5):
            self.assertEqual(self.request("POST", "/admin/login", {"username": "editor", "password": "bad"})[0], 401)
        self.assertEqual(self.request("POST", "/admin/login", {"username": "editor", "password": "bad"})[0], 429)

    def test_draft_not_public_and_requires_actual_review_steps(self):
        self.login()
        item = self.create("articles", self.article())
        self.assertEqual(self.snapshot()["articles"], [])
        self.assertEqual(self.request("GET", f'/api/v1/articles/{item["id"]}', auth=False)[0], 404)
        self.action(item, "publish", expected=400)
        self.action(item, "review", {"confirmed": True, "reviewer": "editor", "credentials": "审核"}, expected=400)
        self.action(item, "submit")
        self.action(item, "review", {"reviewer": "editor", "credentials": "审核", "confirmed": False}, expected=400)
        self.action(item, "review", {"reviewer": "editor", "credentials": "审核", "confirmed": True})
        self.action(item, "publish")
        public = self.snapshot()["articles"][0]
        self.assertEqual(public["review"]["reviewer"], "editor")
        self.assertRegex(public["updatedAt"], r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$")

    def test_missing_sources_cannot_be_reviewed(self):
        self.login()
        payload = self.article()
        payload["references"] = []
        item = self.create("articles", payload)
        self.action(item, "submit")
        self.action(item, "review", {"confirmed": True, "reviewer": "editor", "credentials": "审核"}, expected=400)

    def test_publish_edit_revision_withdraw_and_restore_history(self):
        self.login()
        item = self.create("articles", self.article("初版标题"))
        old_history = self.store.get("articles", item["id"])["history"][0]["historyID"]
        self.review_publish(item)
        initial = self.snapshot()
        status, updated, _ = self.request("POST", f'/admin/api/content/articles/{item["id"]}', self.article("修订标题"))
        self.assertEqual(status, 200)
        self.assertEqual(updated["status"], "draft")
        self.assertIsNone(updated["draft"]["review"])
        self.assertEqual(self.snapshot()["articles"][0]["title"], "初版标题")
        self.action(item, "publish", expected=400)
        self.review_publish(item)
        second = self.snapshot()
        self.assertGreater(second["revision"], initial["revision"])
        self.assertEqual(second["articles"][0]["title"], "修订标题")
        self.action(item, "withdraw")
        withdrawn = self.snapshot()
        self.assertEqual(withdrawn["articles"], [])
        self.assertEqual(withdrawn["tombstones"][0]["id"], item["id"])
        restored = self.action(item, "restore", {"historyID": old_history})
        self.assertEqual(restored["draft"]["title"], "初版标题")
        self.assertEqual(restored["status"], "draft")
        self.assertIsNone(restored["draft"]["review"])
        self.assertEqual(self.snapshot()["articles"], [])
        self.review_publish(item)
        self.assertEqual(self.snapshot()["tombstones"], [])

    def test_album_and_track_withdraw_and_file_version(self):
        self.login()
        album = self.create("albums", {"title": "测试专辑", "summary": "简介"})
        payload = {"title": "自然音测试", "albumID": album["id"], "audioURL": "https://media.example.org/waves.m4a",
                   "durationSeconds": 120.5, "fileVersion": "v1", "byteSize": 4096, "sha256": "a" * 64,
                   "copyright": {"owner": "测试版权人", "source": "直接授权合同编号 TEST", "license": "测试播放授权", "expiresAt": None}}
        track = self.create("tracks", payload)
        self.action(track, "publish", expected=400)
        self.action(album, "publish")
        self.action(track, "publish")
        public = self.snapshot()
        self.assertEqual(public["albums"][0]["trackIDs"], [track["id"]])
        self.assertEqual(public["tracks"][0]["byteSize"], 4096)
        new_payload = copy.deepcopy(payload)
        new_payload["audioURL"] = "https://media.example.org/waves2.m4a"
        self.assertEqual(self.request("POST", f'/admin/api/content/tracks/{track["id"]}', new_payload)[0], 400)
        new_payload["fileVersion"] = "v2"
        self.assertEqual(self.request("POST", f'/admin/api/content/tracks/{track["id"]}', new_payload)[0], 200)
        self.assertEqual(self.snapshot()["tracks"][0]["fileVersion"], "v1")
        self.action(track, "publish")
        self.assertEqual(self.snapshot()["tracks"][0]["fileVersion"], "v2")
        self.action(album, "withdraw")
        public = self.snapshot()
        self.assertEqual(public["albums"], [])
        self.assertEqual(public["tracks"], [])
        self.assertEqual({t["kind"] for t in public["tombstones"]}, {"albums", "tracks"})
        self.action(album, "publish")
        self.assertEqual(self.snapshot()["tracks"], [])

    def test_license_expiry_removes_public_track_and_persists_tombstone(self):
        self.login()
        album = self.create("albums", {"title": "专辑"})
        self.action(album, "publish")
        track = self.create("tracks", {"title": "音轨", "albumID": album["id"], "audioURL": "https://media.example.org/a.m4a",
                                      "durationSeconds": 10, "fileVersion": "1", "byteSize": 12, "sha256": "b" * 64,
                                      "copyright": {"owner": "作者", "source": "授权记录", "license": "许可", "expiresAt": "2099-01-01T00:00:00Z"}})
        self.action(track, "publish")
        before = self.snapshot()
        # Simulate a persisted publication crossing its real authorization deadline.
        with self.store.connect() as db:
            row = db.execute("SELECT published FROM content WHERE id=?", (track["id"],)).fetchone()
            public = json.loads(row[0])
            public["copyright"]["expiresAt"] = "2020-01-01T00:00:00Z"
            db.execute("UPDATE content SET published=? WHERE id=?", (json.dumps(public), track["id"]))
        after = self.snapshot()
        self.assertEqual(after["tracks"], [])
        self.assertEqual(after["albums"][0]["trackIDs"], [])
        self.assertGreater(after["revision"], before["revision"])
        self.assertEqual(after["tombstones"][0]["id"], track["id"])
        self.assertEqual(Store(self.db_path).snapshot()["tombstones"], after["tombstones"])

    def test_csrf_origin_logout_and_session_rotation(self):
        self.login()
        payload = self.article()
        self.assertEqual(self.request("POST", "/admin/api/content/articles", payload, csrf=False)[0], 403)
        self.assertEqual(self.request("POST", "/admin/api/content/articles", payload, extra={"X-CSRF-Token": "bad-token"})[0], 403)
        self.assertEqual(self.request("POST", "/admin/api/content/articles", payload, extra={"Origin": "https://evil.example"})[0], 403)
        self.assertEqual(self.request("POST", "/admin/api/content/articles", payload, extra={"Origin": "null"})[0], 403)
        self.assertEqual(self.snapshot()["articles"], [])
        self.assertEqual(self.request("POST", "/admin/logout", {})[0], 303)
        self.assertEqual(self.request("GET", "/admin/api/content")[0], 401)

    def test_same_origin_html_login_with_browser_referrer_policy(self):
        status, page, headers = self.request("GET", "/admin/login", auth=False)
        self.assertEqual(status, 200)
        csrf = re.search(r'name="csrf" value="([^"]+)"', page)[1]
        cookie = headers["Set-Cookie"].split(";", 1)[0]
        base = f"http://127.0.0.1:{self.server.server_port}"
        # Fetch's append-request-Origin algorithm serializes no-referrer form POSTs as null.
        # https://fetch.spec.whatwg.org/#append-a-request-origin-header
        origin = "null" if headers.get("Referrer-Policy") == "no-referrer" else base
        connection = http.client.HTTPConnection("127.0.0.1", self.server.server_port, timeout=5)
        try:
            payload = urlencode({"username": "editor", "password": "A local test password 2026!", "csrf": csrf})
            connection.request("POST", "/admin/login", payload.encode(),
                               {"Cookie": cookie, "Content-Type": "application/x-www-form-urlencoded", "Origin": origin})
            response = connection.getresponse()
            body = response.read().decode()
            self.assertEqual(response.status, 303, body)
            self.assertEqual(response.getheader("Location"), "/admin")
            authenticated_cookie = response.getheader("Set-Cookie").split(";", 1)[0]
            connection.request("GET", "/admin", headers={"Cookie": authenticated_cookie})
            response = connection.getresponse()
            response.read()
            self.assertEqual(response.status, 200)
        finally:
            connection.close()

    def test_validation_blocks_bad_urls_shapes_and_personal_data(self):
        self.login()
        for url in ("http://example.org/a", "https://user:pass@example.org/a", "https://example.org/a?Signature=x", "https://example.org/a?x-oss-signature=x", "https://localhost/a", "https://192.168.1.1/a", "https://[::1]/a", "javascript:alert(1)"):
            bad = self.article()
            bad["coverURL"] = url
            self.assertEqual(self.request("POST", "/admin/api/content/articles", bad)[0], 400, url)
        for key, value in (("health", {"heartRate": 80}), ("diary", "private"), ("sortOrder", True), ("references", "bad"), ("body", "")):
            bad = self.article()
            bad[key] = value
            self.assertEqual(self.request("POST", "/admin/api/content/articles", bad)[0], 400, key)
        self.assertEqual(self.request("POST", "/admin/api/content/articles", [1, 2])[0], 400)

    def test_explicit_test_publication_does_not_fabricate_professional_review(self):
        self.login()
        ordinary = self.create("articles", self.article("普通待审文章"))
        self.action(ordinary, "publish_test", expected=400)
        self.action(ordinary, "publish", expected=400)
        payload = self.article("[测试] 阅读与收藏")
        payload["body"] = "【仅供功能测试】非医学文案，用于检查阅读和收藏。"
        item = self.create("articles", payload)
        self.action(item, "publish", expected=400)
        published = self.action(item, "publish_test")
        article = self.snapshot()["articles"][0]
        self.assertTrue(article["testOnly"])
        self.assertIn("未专业审核", article["review"]["reviewer"])
        self.assertIn("功能测试", article["review"]["credentials"])
        history = self.request("GET", f'/admin/api/content/articles/{item["id"]}')[1]["history"]
        self.assertEqual(history[0]["operation"], "publish_test")
        self.assertEqual(published["status"], "published")
        _, page, _ = self.request("GET", f'/admin/edit?kind=articles&id={item["id"]}')
        self.assertIn("功能测试（未专业审核）", page)
        self.assertNotIn("专业审核：已记录", page)
        payload["title"] = "移除测试标记的修订"
        self.request("POST", f'/admin/api/content/articles/{item["id"]}', payload)
        self.action(item, "publish_test", expected=400)
        self.action(item, "publish", expected=400)
        self.assertEqual(self.snapshot()["articles"][0]["title"], "[测试] 阅读与收藏")
        album = self.create("albums", {"title": "测试专辑"})
        self.action(album, "publish_test", expected=400)

    def test_browser_form_save_review_and_restore(self):
        self.login()
        def form(path, payload):
            connection = http.client.HTTPConnection("127.0.0.1", self.server.server_port, timeout=5)
            payload["csrf"] = self.csrf
            connection.request("POST", path, urlencode(payload).encode(), {"Cookie": self.cookie, "Content-Type": "application/x-www-form-urlencoded"})
            response = connection.getresponse()
            body = response.read().decode()
            headers = dict(response.getheaders())
            connection.close()
            self.assertEqual(response.status, 303, body)
            return headers["Location"]
        path = form("/admin/save", {"kind": "articles", "title": "网页文章", "summary": "摘要", "body": "正文", "category": "测试", "sortOrder": "0", "references": '[{"title":"来源","url":"https://example.org/source"}]'})
        item = self.store.list_admin()[0]
        self.assertIn(item["id"], path)
        hidden = {"kind": "articles", "id": item["id"]}
        form("/admin/action", dict(hidden, action="submit"))
        form("/admin/action", dict(hidden, action="review", reviewer="网页审核人", credentials="专业审核范围", confirmed="yes"))
        form("/admin/action", dict(hidden, action="publish"))
        self.assertEqual(self.snapshot()["articles"][0]["review"]["reviewer"], "网页审核人")
        history_id = self.store.get("articles", item["id"])["history"][-1]["historyID"]
        form("/admin/action", dict(hidden, action="restore", historyID=str(history_id)))
        self.assertIsNone(self.store.get("articles", item["id"])["draft"]["review"])

    def test_html_preview_escapes_content_and_ui_edit_forms_work(self):
        self.login()
        payload = self.article('<script>alert("x")</script>')
        item = self.create("articles", payload)
        status, page, headers = self.request("GET", f'/admin/edit?kind=articles&id={item["id"]}')
        self.assertEqual(status, 200)
        self.assertIn("&lt;script&gt;", page)
        self.assertNotIn('<script>', page)
        self.assertIn("frame-ancestors 'none'", headers["Content-Security-Policy"])
        self.assertIn("专业资质", page)

    def test_seed_is_idempotent_unreviewed_and_public_empty(self):
        seed(self.store)
        seed(self.store)
        items = self.store.list_admin()
        self.assertEqual(len(items), 18)
        self.assertTrue(all(i["status"] == "draft" and i["draft"]["review"] is None and not i["draft"]["references"] for i in items))
        self.assertEqual(self.snapshot()["articles"], [])

    def test_public_lists_categories_details_and_alias(self):
        self.login()
        item = self.create("articles", self.article())
        self.review_publish(item)
        status, data, _ = self.request("GET", "/api/v1/categories", auth=False)
        self.assertEqual((status, data["categories"]), (200, ["理解焦虑"]))
        self.assertEqual(self.request("GET", "/api/v1/articles", auth=False)[1]["items"][0]["id"], item["id"])
        self.assertEqual(self.request("GET", f'/api/v1/articles/{item["id"]}', auth=False)[0], 200)
        self.assertEqual(self.request("GET", "/api/public/snapshot", auth=False)[1]["revision"], self.snapshot()["revision"])

    def test_password_configuration_rejects_weak_or_missing_secrets(self):
        with self.assertRaises(Invalid):
            password_hash("short")
        with self.assertRaises(Invalid):
            AppServer(("127.0.0.1", 0), self.store, "editor", "plaintext", "x" * 40)
        with self.assertRaises(Invalid):
            AppServer(("127.0.0.1", 0), self.store, "editor", self.encoded, "short")


if __name__ == "__main__":
    unittest.main()
