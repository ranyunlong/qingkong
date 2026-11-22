import html
import http.client
import json
import tempfile
import threading
import unittest
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import parse_qs, urlencode, urlsplit

from ContentService.server import AppServer, Store, password_hash


class Page(HTMLParser):
    """Keep just enough HTML structure to inspect links, forms and album groups."""

    void_tags = {"area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr"}

    def __init__(self, source):
        super().__init__()
        self.nodes = []
        self.stack = []
        self.feed(source)

    def handle_starttag(self, tag, attrs):
        node = {"tag": tag, "attrs": dict(attrs), "parents": tuple(self.stack)}
        self.nodes.append(node)
        if tag not in self.void_tags:
            self.stack.append(node)

    def handle_endtag(self, tag):
        for index in range(len(self.stack) - 1, -1, -1):
            if self.stack[index]["tag"] == tag:
                del self.stack[index:]
                break

    def links(self, href):
        return [node for node in self.nodes if node["tag"] == "a" and node["attrs"].get("href") == href]

    def csrf(self, action):
        for node in self.nodes:
            if node["tag"] == "input" and node["attrs"].get("name") == "csrf":
                if any(parent["tag"] == "form" and parent["attrs"].get("action") == action for parent in node["parents"]):
                    return node["attrs"]["value"]
        raise AssertionError(f"No CSRF field in {action} form")


class AdminUITests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.encoded = password_hash("A local test password 2026!")

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.store = Store(str(Path(self.directory.name) / "test.sqlite3"))
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

    def request(self, method, path, data=None, *, form=False, auth=True):
        connection = http.client.HTTPConnection("127.0.0.1", self.server.server_port, timeout=5)
        headers = {"Cookie": self.cookie} if auth and self.cookie else {}
        body = None
        if data is not None:
            body = (urlencode(data, doseq=True) if form else json.dumps(data, ensure_ascii=False)).encode()
            headers["Content-Type"] = "application/x-www-form-urlencoded" if form else "application/json"
            if not form and self.csrf:
                headers["X-CSRF-Token"] = self.csrf
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
        status, _, headers = self.request("POST", "/admin/login", {
            "username": "editor", "password": "A local test password 2026!",
            "csrf": Page(page).csrf("/admin/login"),
        }, form=True)
        self.assertEqual(status, 303)
        self.cookie = headers["Set-Cookie"].split(";", 1)[0]
        status, session, _ = self.request("GET", "/admin/api/session")
        self.assertEqual(status, 200)
        self.csrf = session["csrfToken"]

    @staticmethod
    def article(title="分区文章", summary="文章摘要"):
        return {"title": title, "summary": summary, "body": "经过编辑核实的正文。", "category": "睡眠",
                "references": [{"title": "参考来源", "url": "https://example.org/reference"}]}

    @staticmethod
    def track(album, title="分区歌曲", summary="歌曲摘要"):
        return {"title": title, "summary": summary, "albumID": album["id"],
                "audioURL": "https://media.example.org/waves.m4a", "durationSeconds": 30,
                "fileVersion": "v1", "byteSize": 4096, "sha256": "a" * 64,
                "copyright": {"owner": "版权人", "source": "授权记录", "license": "播放授权", "expiresAt": None}}

    def create(self, kind, payload):
        status, item, headers = self.request("POST", f"/admin/api/content/{kind}", payload)
        self.assertEqual(status, 201, item)
        self.assertTrue(headers["Content-Type"].startswith("application/json"))
        return item

    def get_page(self, path):
        status, page, headers = self.request("GET", path)
        self.assertEqual(status, 200, page)
        self.assertTrue(headers["Content-Type"].startswith("text/html"))
        return page

    def assert_navigation(self, source, current):
        page = Page(source)
        for path in ("/admin/articles", "/admin/music"):
            self.assertTrue(page.links(path), f"Missing section link {path}")
        self.assertTrue(any(
            node["attrs"].get("aria-current") == "page" or "is-active" in node["attrs"].get("class", "").split()
            for link in page.links(current) for node in [link, *link["parents"]]
        ), f"Missing active section marker for {current}")

    def test_sections_require_login(self):
        for path in ("/admin", "/admin/articles", "/admin/music"):
            with self.subTest(path=path):
                self.assertEqual(self.request("GET", path, auth=False)[0], 401)

    def test_sections_filter_content_and_preserve_json_catalog(self):
        self.login()
        article = self.create("articles", self.article())
        album = self.create("albums", {"title": "分区专辑", "summary": "专辑摘要"})
        track = self.create("tracks", self.track(album))
        for path in ("/admin", "/admin/articles"):
            with self.subTest(path=path):
                page = self.get_page(path)
                self.assertIn(article["draft"]["title"], page)
                self.assertNotIn(album["draft"]["title"], page)
                self.assertNotIn(track["draft"]["title"], page)
                self.assert_navigation(page, "/admin/articles")
        music = self.get_page("/admin/music")
        self.assertIn(album["draft"]["title"], music)
        self.assertIn(track["draft"]["title"], music)
        self.assertNotIn(article["draft"]["title"], music)
        self.assert_navigation(music, "/admin/music")
        status, catalog, headers = self.request("GET", "/admin/api/content")
        self.assertEqual(status, 200)
        self.assertTrue(headers["Content-Type"].startswith("application/json"))
        self.assertEqual({item["id"] for item in catalog["items"]}, {article["id"], album["id"], track["id"]})
        status, public, _ = self.request("GET", "/api/v1/snapshot", auth=False)
        self.assertEqual(status, 200)
        self.assertEqual([public[kind] for kind in ("articles", "albums", "tracks")], [[], [], []])

    def test_music_groups_tracks_with_their_own_albums(self):
        self.login()
        albums = [self.create("albums", {"title": title}) for title in ("海边专辑", "林间专辑")]
        tracks = [self.create("tracks", self.track(album, title)) for album, title in zip(albums, ("海浪歌曲", "林间歌曲"))]
        page = Page(self.get_page("/admin/music"))
        album_links = [page.links(f'/admin/edit?kind=albums&id={album["id"]}') for album in albums]
        for index, track in enumerate(tracks):
            with self.subTest(track=track["id"]):
                links = page.links(f'/admin/edit?kind=tracks&id={track["id"]}')
                self.assertTrue(links)
                self.assertTrue(album_links[index])
                self.assertTrue(any(
                    any(any(parent is group for parent in album_link["parents"]) for album_link in album_links[index])
                    and not any(any(parent is group for parent in other["parents"]) for other in album_links[1 - index])
                    for link in links for group in link["parents"]
                ), "Song must share an album group with its own album only")

    def test_editors_link_back_to_their_section_and_track_can_preselect_album(self):
        self.login()
        album = self.create("albums", {"title": "预选专辑"})
        for kind, section in (("articles", "/admin/articles"), ("albums", "/admin/music"), ("tracks", "/admin/music")):
            with self.subTest(kind=kind):
                self.assertTrue(Page(self.get_page(f"/admin/edit?kind={kind}")).links(section))
        page = Page(self.get_page(f'/admin/edit?kind=tracks&albumID={album["id"]}'))
        self.assertTrue(any(node["tag"] == "option" and node["attrs"].get("value") == album["id"]
                            and "selected" in node["attrs"] for node in page.nodes))

    def test_html_forms_save_publish_and_keep_published_version_when_draft_changes(self):
        self.login()
        payload = self.article("已发布初版")
        payload.pop("references")
        payload.update(bodyHTML="<p>已发布正文 <strong>重点</strong></p>",
                       referenceTitle=["第一条来源", "", "第二条来源"],
                       referenceURL=["https://example.org/first", "", "https://example.org/second"])
        new_page = self.get_page("/admin/edit?kind=articles")
        status, _, headers = self.request("POST", "/admin/save", {
            **payload, "kind": "articles", "csrf": Page(new_page).csrf("/admin/save"),
        }, form=True)
        self.assertEqual(status, 303)
        editor_url = headers["Location"]
        identity = parse_qs(urlsplit(editor_url).query)["id"][0]
        saved = self.request("GET", f"/admin/api/content/articles/{identity}")[1]
        self.assertEqual(saved["draft"]["references"], [
            {"title": "第一条来源", "url": "https://example.org/first"},
            {"title": "第二条来源", "url": "https://example.org/second"},
        ])
        self.assertIn("<strong>重点</strong>", saved["draft"]["bodyHTML"])
        for action, extra in (("submit", {}), ("review", {"reviewer": "测试审核人", "credentials": "测试专业审核", "confirmed": "yes"}), ("publish", {})):
            page = self.get_page(editor_url)
            status, _, _ = self.request("POST", "/admin/action", {
                "kind": "articles", "id": identity, "action": action,
                "csrf": Page(page).csrf("/admin/action"), **extra,
            }, form=True)
            self.assertEqual(status, 303, action)
        before = self.request("GET", "/api/v1/snapshot", auth=False)[1]
        self.assertEqual(before["articles"][0]["title"], "已发布初版")
        revised = {**payload, "kind": "articles", "id": identity, "title": "未发布修订",
                   "bodyHTML": "<p>修订正文 <em>新内容</em></p>"}
        self.assertEqual(self.request("POST", "/admin/save", revised, form=True)[0], 403)
        editor = self.get_page(editor_url)
        revised["csrf"] = Page(editor).csrf("/admin/save")
        self.assertEqual(self.request("POST", "/admin/save", revised, form=True)[0], 303)
        after = self.request("GET", "/api/v1/snapshot", auth=False)[1]
        self.assertEqual(after["articles"], before["articles"])
        self.assertIn("未发布修订", self.get_page(editor_url))
        status, item, _ = self.request("GET", f"/admin/api/content/articles/{identity}")
        self.assertEqual(status, 200)
        self.assertEqual(item["status"], "draft")
        self.assertIsNone(item["draft"]["review"])
        self.assertIn("新内容", item["draft"]["body"])
        self.assertIn("<em>新内容</em>", item["draft"]["bodyHTML"])

    def test_article_form_has_plain_fallback_and_reference_rows_validate(self):
        self.login()
        editor = Page(self.get_page("/admin/edit?kind=articles"))
        self.assertTrue(any(node["tag"] == "textarea" and node["attrs"].get("name") == "body" for node in editor.nodes))
        self.assertTrue(any(node["tag"] == "input" and node["attrs"].get("name") == "bodyHTML"
                            and node["attrs"].get("type") == "hidden" for node in editor.nodes))
        for field in ("referenceTitle", "referenceURL"):
            self.assertTrue(any(node["tag"] == "input" and node["attrs"].get("name") == field for node in editor.nodes))
        self.assertFalse(any(node["tag"] == "textarea" and node["attrs"].get("name") == "references" for node in editor.nodes))
        payload = self.article("来源字段校验")
        payload.pop("references")
        payload.update(kind="articles", csrf=editor.csrf("/admin/save"))
        cases = [
            {"referenceTitle": ["有标题"], "referenceURL": [""]},
            {"referenceTitle": [""], "referenceURL": ["https://example.org/no-title"]},
            {"referenceTitle": ["标题"] * 31, "referenceURL": ["https://example.org/source"] * 31},
        ]
        for rows in cases:
            with self.subTest(rows=len(rows["referenceTitle"]), title=rows["referenceTitle"][0]):
                self.assertEqual(self.request("POST", "/admin/save", {**payload, **rows}, form=True)[0], 400)

    def test_long_chinese_rich_article_form_saves_both_body_representations(self):
        self.login()
        plain = "经过核实的中文正文" * 2000
        rich = "<p>" + plain + "</p>"
        editor = Page(self.get_page("/admin/edit?kind=articles"))
        payload = {**self.article("长篇中文富文本"), "kind": "articles", "body": plain, "bodyHTML": rich,
                   "csrf": editor.csrf("/admin/save")}
        payload.pop("references")
        payload.update(referenceTitle=["参考来源"], referenceURL=["https://example.org/reference"])
        encoded_size = len(urlencode(payload, doseq=True).encode())
        self.assertGreater(encoded_size, 256 * 1024)
        self.assertLess(encoded_size, 2 * 1024 * 1024)
        status, result, headers = self.request("POST", "/admin/save", payload, form=True)
        self.assertEqual(status, 303, result)
        identity = parse_qs(urlsplit(headers["Location"]).query)["id"][0]
        status, saved, _ = self.request("GET", f"/admin/api/content/articles/{identity}")
        self.assertEqual(status, 200)
        self.assertEqual(saved["draft"]["body"], plain)
        self.assertEqual(saved["draft"]["bodyHTML"], rich)

    def test_article_editor_saves_image_links_and_exposes_local_upload(self):
        self.login()
        editor_html = self.get_page("/admin/edit?kind=articles")
        editor = Page(editor_html)
        for attribute in ("data-editor-image-url", "data-editor-image-upload"):
            self.assertTrue(any(node["tag"] == "button" and attribute in node["attrs"]
                                and node["attrs"].get("type") == "button" for node in editor.nodes))
        self.assertTrue(any(node["tag"] == "input" and node["attrs"].get("type") == "file"
                            and "data-editor-image-file" in node["attrs"] for node in editor.nodes))
        rich = '<p>图片前的正文</p><img src="https://example.org/photo.png" alt="海边的晴空" width="800" height="600"/><p>图片后的正文</p>'
        payload = {**self.article("图文草稿"), "kind": "articles", "bodyHTML": rich,
                   "csrf": editor.csrf("/admin/save")}
        payload.pop("references")
        payload.update(referenceTitle=["参考来源"], referenceURL=["https://example.org/reference"])
        status, result, headers = self.request("POST", "/admin/save", payload, form=True)
        self.assertEqual(status, 303, result)
        identity = parse_qs(urlsplit(headers["Location"]).query)["id"][0]
        saved = self.request("GET", f"/admin/api/content/articles/{identity}")[1]["draft"]
        images = [node for node in Page(saved["bodyHTML"]).nodes if node["tag"] == "img"]
        self.assertEqual(len(images), 1)
        self.assertEqual(images[0]["attrs"]["src"], "https://example.org/photo.png")
        self.assertEqual(images[0]["attrs"]["alt"], "海边的晴空")
        self.assertLess(saved["body"].index("图片前的正文"), saved["body"].index("海边的晴空"))
        self.assertLess(saved["body"].index("海边的晴空"), saved["body"].index("图片后的正文"))
        reloaded = self.get_page(headers["Location"])
        self.assertIn('src="https://example.org/photo.png"', reloaded)
        _, _, response_headers = self.request("GET", headers["Location"])
        self.assertIn("img-src 'self' https:", response_headers["Content-Security-Policy"])

    def test_request_size_limits_reject_oversized_content_and_keep_small_action_limits(self):
        self.login()
        # Send only headers: oversized bodies must be rejected before the server
        # waits for their content, including a client that never supplies it.
        for path, length in (("/admin/save", 2 * 1024 * 1024 + 1),
                             ("/admin/api/content/articles", 2 * 1024 * 1024 + 1),
                             ("/admin/action", 256 * 1024 + 1),
                             ("/admin/api/media/inspect", 256 * 1024 + 1)):
            with self.subTest(path=path):
                connection = http.client.HTTPConnection("127.0.0.1", self.server.server_port, timeout=5)
                try:
                    connection.putrequest("POST", path)
                    connection.putheader("Cookie", self.cookie)
                    connection.putheader("Content-Type", "application/x-www-form-urlencoded")
                    connection.putheader("Content-Length", str(length))
                    connection.endheaders()
                    response = connection.getresponse()
                    self.assertEqual(response.status, 400)
                    self.assertIn("超过", json.loads(response.read())["error"])
                finally:
                    connection.close()
        self.assertEqual(self.store.list_admin(), [])

    def test_rich_body_is_sanitized_and_public_body_remains_plain_text(self):
        self.login()
        rich = ('<h2>富文本标题</h2><p onclick="alert(1)" style="color:red">第一段<br>'
                '<strong>加粗</strong><b>粗体</b><em>强调</em><i>斜体</i><u>下划线</u><s>删除线</s></p>'
                '<h3>小标题</h3><ul><li>列表一</li></ul><ol><li>列表二</li></ol><blockquote>引文</blockquote>'
                '<p><a href="https://example.org/source" onclick="alert(2)">安全来源</a>'
                '<a href="javascript:alert(3)">脚本链接</a><a href="http://example.org/source">非安全来源</a></p>'
                '<script>alert(4)</script><style>p{color:red}</style><iframe src="https://example.org"></iframe>'
                '<img src="x" onerror="alert(5)"><svg onload="alert(6)"></svg>')
        payload = {**self.article("富文本安全"), "body": "仅后备文本", "bodyHTML": rich}
        article = self.create("articles", payload)
        sanitized = article["draft"]["bodyHTML"]
        document = Page(sanitized)
        tags = {node["tag"] for node in document.nodes}
        self.assertTrue({"p", "br", "h2", "h3", "strong", "b", "em", "i", "u", "s", "ul", "ol", "li", "blockquote", "a"} <= tags)
        self.assertFalse(tags & {"script", "style", "iframe", "img", "svg"})
        self.assertTrue(document.links("https://example.org/source"))
        for node in document.nodes:
            for attribute, value in node["attrs"].items():
                self.assertFalse(attribute.startswith("on") or attribute == "style", attribute)
                if attribute == "href":
                    self.assertEqual(urlsplit(value).scheme, "https")
        for text in ("富文本标题", "第一段", "列表一", "列表二", "引文"):
            self.assertIn(text, article["draft"]["body"])
        self.assertNotIn("仅后备文本", article["draft"]["body"])
        self.assertNotIn("<p>", article["draft"]["body"])
        for action, extra in (("submit", {}), ("review", {"reviewer": "测试审核人", "credentials": "测试专业审核", "confirmed": True}), ("publish", {})):
            self.assertEqual(self.request("POST", f'/admin/api/content/articles/{article["id"]}/{action}', extra)[0], 200)
        status, public, headers = self.request("GET", f'/api/v1/articles/{article["id"]}', auth=False)
        self.assertEqual(status, 200)
        self.assertTrue(headers["Content-Type"].startswith("application/json"))
        self.assertEqual(public["bodyHTML"], sanitized)
        self.assertEqual(public["body"], article["draft"]["body"])
        plain = self.create("articles", self.article("纯文本兼容"))
        self.assertEqual(plain["draft"]["body"], self.article()["body"])

    def test_titles_and_summaries_are_escaped_in_lists_and_previews(self):
        self.login()
        title = '<img src=x onerror="alert(1)">标题'
        summary = '<script>alert("摘要")</script>'
        album = self.create("albums", {"title": "专辑" + title, "summary": summary})
        items = [self.create("articles", self.article("文章" + title, summary)), album,
                 self.create("tracks", self.track(album, "歌曲" + title, summary))]
        for item in items:
            with self.subTest(kind=item["kind"]):
                path = "/admin/articles" if item["kind"] == "articles" else "/admin/music"
                for page in (self.get_page(path), self.get_page(f'/admin/edit?kind={item["kind"]}&id={item["id"]}')):
                    self.assertIn(html.escape(item["draft"]["title"]), page)
                    self.assertNotIn(title, page)
                    self.assertNotIn(summary, page)
                preview = self.get_page(f'/admin/edit?kind={item["kind"]}&id={item["id"]}')
                self.assertIn(html.escape(summary), preview)


if __name__ == "__main__":
    unittest.main()
