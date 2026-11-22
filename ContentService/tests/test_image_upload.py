"""Actual HTTP coverage for authenticated, bounded article image uploads."""
import hashlib
import http.client
import io
import json
import os
import re
import tempfile
import threading
import unittest
from pathlib import Path

from PIL import Image

from ContentService.server import AppServer, Store, password_hash


def picture(format='PNG', size=(32, 16), **options):
    output = io.BytesIO()
    Image.new('RGB', size, '#abc123').save(output, format=format, **options)
    return output.getvalue()


class ImageUploadTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.password = 'A local image endpoint test password!'
        cls.encoded = password_hash(cls.password)

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.store = Store(str(Path(self.directory.name) / 'content.sqlite3'))
        self.server = AppServer(('127.0.0.1', 0), self.store, 'editor', self.encoded, 'image-secret-' * 4)
        self.addCleanup(self.server.server_close)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.addCleanup(self.stop)
        self.cookie = None
        self.csrf = None

    def stop(self):
        self.server.shutdown()
        self.thread.join(timeout=5)

    def request(self, method, path, body=None, headers=None):
        actual = {'Host': 'images.example.org'}
        if self.cookie:
            actual['Cookie'] = self.cookie
        actual.update(headers or {})
        connection = http.client.HTTPConnection('127.0.0.1', self.server.server_port, timeout=8)
        try:
            connection.request(method, path, body, actual)
            response = connection.getresponse()
            raw = response.read()
            result_headers = dict(response.getheaders())
            if result_headers.get('Content-Type', '').startswith('application/json'):
                raw = json.loads(raw)
            return response.status, raw, result_headers
        finally:
            connection.close()

    def login(self):
        status, page, headers = self.request('GET', '/admin/login')
        self.assertEqual(status, 200)
        self.cookie = headers['Set-Cookie'].split(';', 1)[0]
        token = re.search(rb'name="csrf" value="([^\"]+)"', page)[1].decode()
        status, _, headers = self.request('POST', '/admin/login', json.dumps({
            'username': 'editor', 'password': self.password, 'csrf': token}),
            {'Content-Type': 'application/json'})
        self.assertEqual(status, 303)
        self.cookie = headers['Set-Cookie'].split(';', 1)[0]
        self.csrf = self.request('GET', '/admin/api/session')[1]['csrfToken']

    def upload(self, body=None, mime='image/png', **overrides):
        headers = {'Content-Type': mime, 'Origin': 'http://images.example.org', 'X-CSRF-Token': self.csrf or ''}
        headers.update(overrides)
        return self.request('POST', '/admin/api/images', picture() if body is None else body, headers)

    def test_authentication_and_csrf_rejected_before_body_read(self):
        # Only send headers claiming a large body: a response must arrive without the body.
        for authenticated, csrf, origin, expected in ((False, '', 'http://images.example.org', 401),
                    (True, '', 'http://images.example.org', 403),
                    (True, 'valid', 'https://evil.example.org', 403),
                    (True, 'valid', None, 403)):
            with self.subTest(expected=expected, origin=origin):
                if authenticated and not self.cookie:
                    self.login()
                headers = {'Host': 'images.example.org', 'Content-Type': 'image/png', 'Content-Length': str(10 * 1024 * 1024)}
                if authenticated:
                    headers['Cookie'] = self.cookie
                headers['X-CSRF-Token'] = self.csrf if csrf else ''
                if origin is not None:
                    headers['Origin'] = origin
                connection = http.client.HTTPConnection('127.0.0.1', self.server.server_port, timeout=2)
                try:
                    connection.putrequest('POST', '/admin/api/images', skip_host=True)
                    for name, value in headers.items():
                        connection.putheader(name, value)
                    connection.endheaders()
                    response = connection.getresponse()
                    self.assertEqual(response.status, expected)
                    response.read()
                finally:
                    connection.close()

    def test_png_upload_public_read_and_dedup_do_not_change_revision(self):
        self.login()
        revision = self.store.snapshot()['revision']
        before = self.request('GET', '/admin/api/content')[1]
        status, result, headers = self.upload()
        self.assertEqual(status, 201)
        self.assertEqual(set(result), {'url', 'width', 'height', 'byteSize'})
        self.assertEqual((result['width'], result['height']), (32, 16))
        self.assertRegex(result['url'], r'^https://images\.example\.org/api/v1/images/[0-9a-f]{64}\.png$')
        self.assertEqual(headers['Cache-Control'], 'no-store')
        self.cookie = None
        status, raw, headers = self.request('GET', result['url'].split('images.example.org')[1])
        self.assertEqual(status, 200)
        self.assertEqual(headers['Content-Type'], 'image/png')
        self.assertEqual(headers['X-Content-Type-Options'], 'nosniff')
        self.assertIn('immutable', headers['Cache-Control'])
        self.assertEqual(len(raw), result['byteSize'])
        filename = result['url'].rsplit('/', 1)[1]
        self.assertEqual(filename, hashlib.sha256(raw).hexdigest() + '.png')
        self.assertEqual((Path(self.directory.name) / 'uploads' / filename).read_bytes(), raw)
        self.assertEqual(self.store.snapshot()['revision'], revision)
        self.login()
        self.assertEqual(self.request('GET', '/admin/api/content')[1], before)
        self.assertEqual(self.upload()[1], result)
        self.assertEqual(len(list((Path(self.directory.name) / 'uploads').iterdir())), 1)

    def test_jpeg_orientation_resize_and_metadata_removed(self):
        self.login()
        exif = Image.Exif()
        exif[274], exif[270] = 6, 'private description'
        status, result, _ = self.upload(picture('JPEG', (3000, 1000), exif=exif), mime='image/jpeg')
        self.assertEqual(status, 201)
        self.assertEqual((result['width'], result['height']), (853, 2560))
        _, raw, _ = self.request('GET', result['url'].split('images.example.org')[1])
        with Image.open(io.BytesIO(raw)) as image:
            self.assertEqual(image.format, 'JPEG')
            self.assertFalse(image.getexif())
            self.assertNotIn('exif', image.info)

    def test_webp_becomes_png_and_unsafe_formats_or_fake_mime_are_rejected(self):
        self.login()
        status, result, _ = self.upload(picture('WEBP'), mime='image/webp')
        self.assertEqual(status, 201)
        self.assertTrue(result['url'].endswith('.png'))
        for body, mime in ((picture('PNG'), 'image/jpeg'), (b'fake PNG', 'image/png'),
                           (b'<svg/>', 'image/svg+xml'), (picture('GIF'), 'image/gif')):
            with self.subTest(mime=mime):
                self.assertEqual(self.upload(body, mime=mime)[0], 400)

    def test_large_transparent_png_is_reduced_to_mobile_byte_limit(self):
        self.login()
        output = io.BytesIO()
        Image.frombytes('RGBA', (1500, 1500), os.urandom(1500 * 1500 * 4)).save(output, format='PNG')
        self.assertGreater(len(output.getvalue()), 8 * 1024 * 1024)
        self.assertLess(len(output.getvalue()), 10 * 1024 * 1024)
        status, result, _ = self.upload(output.getvalue())
        self.assertEqual(status, 201)
        self.assertLessEqual(result['byteSize'], 8 * 1024 * 1024)
        self.assertLess(result['width'], 1500)
        _, raw, _ = self.request('GET', result['url'].split('images.example.org')[1])
        with Image.open(io.BytesIO(raw)) as image:
            self.assertEqual(image.mode, 'RGBA')

    def test_byte_dimension_and_pixel_limits(self):
        self.login()
        for body in (picture('PNG', (10001, 1)), picture('PNG', (5000, 4001)), b''):
            with self.subTest(length=len(body)):
                self.assertEqual(self.upload(body)[0], 400)
        self.assertEqual(self.upload(b'', **{'Content-Length': str(10 * 1024 * 1024 + 1)})[0], 400)

    def test_public_image_paths_are_strict_and_do_not_follow_symlinks(self):
        uploads = Path(self.directory.name) / 'uploads'
        uploads.mkdir(exist_ok=True)
        secret = Path(self.directory.name) / 'private.txt'
        secret.write_text('private')
        (uploads / ('a' * 64 + '.png')).symlink_to(secret)
        for path in ('../private.txt', '%2e%2e/private.txt', 'bad.png', 'a' * 64 + '.svg',
                     'a' * 64 + '.png', 'a' * 64 + '.jpg/extra'):
            with self.subTest(path=path):
                self.assertEqual(self.request('GET', '/api/v1/images/' + path)[0], 404)


if __name__ == '__main__':
    unittest.main()
