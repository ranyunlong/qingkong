"""Small, bounded HTML sanitizer for public editorial article bodies."""
import html
import re
from html.parser import HTMLParser
from urllib.parse import unquote, urlsplit


MAX_HTML = 120000
MAX_PLAIN = 60000
MAX_TAGS = 5000
MAX_DEPTH = 40
ALLOWED = {"p", "br", "h2", "h3", "strong", "b", "em", "i", "u", "s", "ul", "ol", "li", "blockquote", "a", "img"}
BLOCKS = {"p", "h2", "h3", "ul", "ol", "li", "blockquote"}
DROP_CONTENT = {"script", "style", "iframe", "object", "embed", "svg", "math", "template", "head"}
VOID = {"area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr"}
NORMALIZED = {"div": "p", "h1": "h2", "strike": "s"}


def _valid_char(character):
    code = ord(character)
    return (character in "\t\n\r" or code >= 32) and not (
        0x7F <= code <= 0x9F or 0xD800 <= code <= 0xDFFF or code in (0xFFFE, 0xFFFF)
    )


class _Sanitizer(HTMLParser):
    def __init__(self, validate_url):
        super().__init__(convert_charrefs=False)
        self.validate_url = validate_url
        self.stack = []
        self.output = []
        self.output_length = 0
        self.plain = []
        self.tags = 0
        self.images = 0

    def emit(self, value):
        self.output_length += len(value)
        if self.output_length > MAX_HTML:
            raise ValueError("富文本正文不超过 120000 字符")
        self.output.append(value)

    def count_tag(self):
        self.tags += 1
        if self.tags > MAX_TAGS:
            raise ValueError("富文本标签不超过 5000 个")

    def blocked(self):
        return any(frame[2] for frame in self.stack)

    def boundary(self, tag):
        if tag in BLOCKS or tag == "br":
            self.plain.append("\n")

    def handle_starttag(self, tag, attrs):
        self.start(tag, attrs)

    def handle_startendtag(self, tag, attrs):
        self.start(tag, attrs, self_closing=True)

    def start(self, tag, attrs, self_closing=False):
        self.count_tag()
        pushes = (tag not in VOID or tag == "embed") and not self_closing
        if pushes and len(self.stack) >= MAX_DEPTH:
            raise ValueError("富文本嵌套不超过 40 层")
        blocked = self.blocked() or tag in DROP_CONTENT
        output_tag = None
        if not blocked:
            normalized = NORMALIZED.get(tag, tag)
            if normalized in ALLOWED:
                output_tag = normalized
                attributes = ""
                if normalized == "a":
                    href = dict(attrs).get("href") or ""
                    try:
                        validated = self.validate_url(href) if urlsplit(href).scheme == "https" else None
                    except (ValueError, TypeError):
                        validated = None
                    if validated:
                        attributes = ' href="' + html.escape(validated, quote=True) + '"'
                    else:
                        output_tag = None
                if normalized == "img":
                    values = dict(attrs)
                    src = values.get("src") or ""
                    try:
                        parts = urlsplit(src)
                        safe = (parts.scheme == "https" and "\\" not in src
                                and not any(character.isspace() or ord(character) < 32 or ord(character) == 127 for character in src)
                                and not unquote(parts.path).lower().endswith((".svg", ".svgz")))
                        validated = self.validate_url(src) if safe else None
                    except (ValueError, TypeError):
                        validated = None
                    if validated:
                        self.images += 1
                        if self.images > 30:
                            raise ValueError("正文图片不超过 30 张")
                        alt = values.get("alt")
                        if not isinstance(alt, str) or len(alt) > 300:
                            alt = "正文图片"
                        attributes = ' src="' + html.escape(validated, quote=True) + '" alt="' + html.escape(alt, quote=True) + '"'
                        for name in ("width", "height"):
                            dimension = values.get(name) or ""
                            if re.fullmatch(r"[1-9][0-9]{0,4}", dimension) and int(dimension) <= 10000:
                                attributes += f' {name}="{dimension}"'
                        self.plain.extend(("\n", alt.strip() or "[图片]", "\n"))
                    else:
                        output_tag = None
                if output_tag:
                    self.boundary(output_tag)
                    self.emit("<" + output_tag + attributes + ("/>" if output_tag in VOID else ">"))
                    if self_closing and output_tag not in VOID:
                        self.emit("</" + output_tag + ">")
                        self.boundary(output_tag)
        if pushes:
            self.stack.append((tag, output_tag, blocked))

    def close_frames(self, index):
        for _, output_tag, _ in reversed(self.stack[index:]):
            if output_tag:
                self.emit("</" + output_tag + ">")
                self.boundary(output_tag)
        del self.stack[index:]

    def handle_endtag(self, tag):
        self.count_tag()
        for index in range(len(self.stack) - 1, -1, -1):
            if self.stack[index][0] == tag:
                # An outer mismatched end tag must not escape a suppressed block.
                if any(frame[2] for frame in self.stack[index + 1:]) and not self.stack[index][2]:
                    return
                self.close_frames(index)
                return

    def handle_data(self, data):
        if self.blocked():
            return
        if any(not _valid_char(character) for character in data):
            raise ValueError("富文本含无效控制字符")
        self.emit(html.escape(data, quote=False))
        self.plain.append(data.replace("\xa0", " "))

    def handle_entityref(self, name):
        self.handle_data(html.unescape("&" + name + ";"))

    def handle_charref(self, name):
        self.handle_data(html.unescape("&#" + name + ";"))

    def result(self):
        self.close()
        self.close_frames(0)
        lines = [re.sub(r"[ \t]+", " ", line).strip() for line in "".join(self.plain).splitlines()]
        plain = "\n".join(line for line in lines if line)
        if not plain:
            raise ValueError("富文本正文不能为空")
        if len(plain) > MAX_PLAIN:
            raise ValueError("正文纯文本不超过 60000 字符")
        return "".join(self.output), plain


def sanitize_html(value, validate_url):
    """Return safe, balanced HTML and its readable plain text, or raise ValueError."""
    if not isinstance(value, str) or len(value) > MAX_HTML:
        raise ValueError("富文本正文须为不超过 120000 字符的文本")
    if any(not _valid_char(character) for character in value):
        raise ValueError("富文本含无效控制字符")
    # HTMLParser decodes attribute references itself; reject forbidden numeric
    # characters before that decoding can silently replace or discard them.
    for match in re.finditer(r"&#([xX][0-9a-fA-F]+|[0-9]+);?", value):
        number = match.group(1)
        try:
            hexadecimal = number[0] in "xX"
            digits = (number[1:] if hexadecimal else number).lstrip("0") or "0"
            if len(digits) > (6 if hexadecimal else 7):
                raise ValueError("Character reference out of range")
            code = int(digits, 16 if hexadecimal else 10)
            valid = _valid_char(chr(code))
        except (ValueError, OverflowError):
            valid = False
        if not valid:
            raise ValueError("富文本含无效字符实体")
    sanitizer = _Sanitizer(validate_url)
    sanitizer.feed(value)
    return sanitizer.result()
