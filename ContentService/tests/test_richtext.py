import unittest
import xml.etree.ElementTree as ET
from urllib.parse import urlsplit

from ContentService.richtext import sanitize_html


def validate_url(value):
    parts = urlsplit(value)
    if parts.scheme != "https" or parts.hostname != "example.org" or parts.username:
        raise ValueError("Unapproved URL")
    return value


class RichTextTests(unittest.TestCase):
    def clean(self, value):
        markup, plain = sanitize_html(value, validate_url)
        ET.fromstring("<root>" + markup + "</root>")
        return markup, plain

    def test_supported_formatting_and_block_boundaries_survive(self):
        markup, plain = self.clean(
            '<div>开头<br>换行</div><h1>大标题</h1><h3>小标题</h3>'
            '<p><strong>重点</strong><b>粗体</b><em>强调</em><i>斜体</i><u>下划线</u><s>删除线</s></p>'
            '<blockquote>引文<ul><li>第一项<ol><li>嵌套项</li></ol></li><li>第二项</li></ul>结尾</blockquote>'
        )
        self.assertIn("<p>开头<br/>换行</p><h2>大标题</h2>", markup)
        for tag in ("h3", "strong", "b", "em", "i", "u", "s", "blockquote", "ul", "ol", "li"):
            self.assertIn("<" + tag + ">", markup)
        self.assertEqual(plain, "开头\n换行\n大标题\n小标题\n重点粗体强调斜体下划线删除线\n引文\n第一项\n嵌套项\n第二项\n结尾")

    def test_dangerous_elements_drop_their_contents_even_with_mismatched_end_tags(self):
        markup, plain = self.clean(
            '<p>安全开头</p><div><iframe><b>隐藏</b></div>仍应隐藏</iframe>'
            '<script>alert(1)</script><style>p{display:none}</style><object>对象</object>'
            '<svg><foreignObject><p>矢量内容</p></foreignObject></svg>'
            '<math>公式</math><template>模板</template><head><title>标题</title></head>'
            '<img src="javascript:alert(2)" onerror="alert(2)"><embed src="https://example.org/a">嵌入内容</embed>'
            '<p>安全结尾</p>'
        )
        self.assertEqual(plain, "安全开头\n安全结尾")
        self.assertNotIn("隐藏", markup)
        self.assertNotIn("script", markup)
        self.assertNotIn("src=", markup)

    def test_images_keep_order_safe_attributes_and_xml_compatibility(self):
        markup, plain = self.clean('<p>前<img src="https://example.org/a.png?a=1&amp;b=2" '
                                   'alt="山 &amp; 海" width="320" height="200" '
                                   'onclick="bad()" srcset="bad" style="x">后</p>')
        image = ET.fromstring('<root>' + markup + '</root>').find('.//img')
        self.assertEqual(image.attrib, {'src': 'https://example.org/a.png?a=1&b=2',
                                       'alt': '山 & 海', 'width': '320', 'height': '200'})
        self.assertIn('/>', markup)
        self.assertEqual(plain, '前\n山 & 海\n后')

    def test_image_only_content_and_default_alt(self):
        markup, plain = self.clean('<img src="https://example.org/a.png">')
        self.assertEqual(plain, '正文图片')
        self.assertIn('alt="正文图片"', markup)
        self.assertEqual(self.clean('<img src="https://example.org/a.png" alt="">')[1], '[图片]')

    def test_images_reject_unsafe_urls_attributes_and_limits(self):
        for source in ('http://example.org/a', 'data:image/png;base64,YQ==', 'blob:https://example.org/a',
                       'javascript:alert(1)', '//example.org/a', 'https://other.example/a',
                       'https://example.org/a.SVG', 'https://example.org/a.svgz?download=1',
                       'https://example.org/a%2esvg', 'https://example.org/a\\image.png'):
            with self.subTest(source=source):
                markup, plain = self.clean('<p>安全</p><img src="' + source + '">')
                self.assertNotIn('<img', markup)
                self.assertEqual(plain, '安全')
        markup, _ = self.clean('<img src="https://example.org/a" width="0" height="10001" alt="' + '字' * 301 + '">')
        image = ET.fromstring('<root>' + markup + '</root>').find('img')
        self.assertEqual(image.attrib, {'src': 'https://example.org/a', 'alt': '正文图片'})
        image = '<img src="https://example.org/a">'
        self.assertEqual(self.clean(image * 30)[0].count('<img'), 30)
        with self.assertRaisesRegex(ValueError, '30'):
            self.clean(image * 31)

    def test_only_validated_https_links_and_no_other_attributes_survive(self):
        markup, plain = self.clean(
            '<p id="x" style="color:red" onclick="bad()">'
            '<a href="https://example.org/?a=1&amp;b=2" target="_blank" onmouseover="bad()">允许</a>'
            '<a href="javascript:alert(1)">脚本</a><a href="http://example.org/">HTTP</a>'
            '<a href="https://other.example/">校验拒绝</a></p>'
        )
        root = ET.fromstring("<root>" + markup + "</root>")
        links = root.findall(".//a")
        self.assertEqual([(link.attrib, link.text) for link in links], [({"href": "https://example.org/?a=1&b=2"}, "允许")])
        self.assertTrue(all(not node.attrib for node in root.iter() if node.tag != "a"))
        self.assertEqual(plain, "允许脚本HTTP校验拒绝")

    def test_entities_are_xml_compatible_and_literal_markup_stays_text(self):
        markup, plain = self.clean('<p>A&nbsp;B &copy; &#x1F319; &bogus; &lt;b&gt; &amp;</p>')
        self.assertNotIn("&nbsp;", markup)
        self.assertNotIn("&copy;", markup)
        self.assertIn("&amp;bogus;", markup)
        self.assertEqual(plain, "A B © 🌙 &bogus; <b> &")
        self.assertIn("&lt;b&gt;", markup)

    def test_malformed_nesting_is_balanced_and_unknown_tags_keep_text(self):
        markup, plain = self.clean('<p>开头<strong>重点</p>段后</strong><unknown>普通内容</unknown>'
                                   '<blockquote>引用<ul><li>甲<li>乙</ul>列表后')
        self.assertIn("<p>开头<strong>重点</strong></p>", markup)
        for text in ("开头", "重点", "段后", "普通内容", "引用", "甲", "乙", "列表后"):
            self.assertIn(text, plain)
        self.assertNotIn("unknown", markup)

    def test_browser_strike_format_is_normalized(self):
        markup, plain = self.clean("<p>保留<strike>删除内容</strike></p>")
        self.assertEqual(markup, "<p>保留<s>删除内容</s></p>")
        self.assertEqual(plain, "保留删除内容")

    def test_empty_controls_and_resource_limits_are_rejected(self):
        cases = [None, "", " \n\t", "<script>不可见</script>", "<p>&nbsp;</p>",
                 "x\x00", "x\x08", "x\x7f", "<p>&#1;</p>", "<p>&#xD800;</p>",
                 "x" * 120001, "x" * 60001, "&" * 24001, "<br>" * 5001 + "x", "<b>" * 41 + "x"]
        for value in cases:
            with self.subTest(value=str(value)[:45]):
                with self.assertRaises(ValueError):
                    sanitize_html(value, validate_url)
        self.assertEqual(self.clean("x" * 60000)[1], "x" * 60000)
        self.assertEqual(self.clean("<b>" * 40 + "x")[1], "x")
        self.assertEqual(self.clean("<br>" * 5000 + "x")[1], "x")


if __name__ == "__main__":
    unittest.main()
