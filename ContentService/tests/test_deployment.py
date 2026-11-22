import http.client
import importlib
import json
import os
import re
import select
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from ContentService.server import check_password, password_hash


class DeploymentTests(unittest.TestCase):
    def test_container_bind_serves_public_content_with_secure_admin_cookie(self):
        with tempfile.TemporaryDirectory() as directory:
            environment = dict(os.environ, QINGKONG_ADMIN_USERNAME="deployment-test",
                               QINGKONG_ADMIN_PASSWORD_HASH=password_hash("Deployment test password!"),
                               QINGKONG_SESSION_SECRET="isolated-deployment-test-secret-2026",
                               QINGKONG_SECURE_COOKIES="1", PYTHONDONTWRITEBYTECODE="1")
            process = subprocess.Popen(
                [sys.executable, "-u", "-m", "ContentService.server", "--host", "0.0.0.0",
                 "--port", "0", "--db", str(Path(directory) / "content.sqlite3")],
                env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            try:
                ready, _, _ = select.select([process.stdout], [], [], 5)
                self.assertTrue(ready, "service must report its listening address")
                line = process.stdout.readline()
                address = re.search(r"http://0\.0\.0\.0:(\d+)/admin/login", line)
                self.assertIsNotNone(address, "container bind must start successfully: " + line)
                connection = http.client.HTTPConnection("127.0.0.1", int(address[1]), timeout=3)
                try:
                    connection.request("GET", "/api/v1/snapshot", headers={"Host": "xqk.geckoai.cn"})
                    response = connection.getresponse()
                    snapshot = json.loads(response.read())
                    self.assertEqual(response.status, 200)
                    self.assertEqual((snapshot["articles"], snapshot["albums"], snapshot["tracks"]), ([], [], []))
                    connection.request("GET", "/admin/login", headers={"Host": "xqk.geckoai.cn"})
                    response = connection.getresponse()
                    response.read()
                    self.assertIn("; Secure", response.getheader("Set-Cookie"))
                finally:
                    connection.close()
            finally:
                process.terminate()
                try:
                    process.communicate(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.communicate()

    def configure(self):
        try:
            return importlib.import_module("ContentService.configure")
        except ModuleNotFoundError:
            self.fail("deployment credential generator is not implemented")

    def test_generated_environment_keeps_password_hash_literal_and_file_private(self):
        configure = self.configure()
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / ".env"
            configure.write_environment(path, "editor", "Deployment test password!")
            content = path.read_text()
            self.assertIn("QINGKONG_ADMIN_USERNAME='editor'\n", content)
            encoded = re.search(r"^QINGKONG_ADMIN_PASSWORD_HASH='([^']+)'$", content, re.MULTILINE)[1]
            self.assertTrue(check_password("Deployment test password!", encoded))
            secret = re.search(r"^QINGKONG_SESSION_SECRET='([^']+)'$", content, re.MULTILINE)[1]
            self.assertGreaterEqual(len(secret), 32)
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)

    def test_existing_environment_is_not_replaced(self):
        configure = self.configure()
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / ".env"
            path.write_text("existing credentials\n")
            with self.assertRaises(FileExistsError):
                configure.write_environment(path, "editor", "Deployment test password!")
            self.assertEqual(path.read_text(), "existing credentials\n")

    def test_invalid_credentials_do_not_create_environment_file(self):
        configure = self.configure()
        with tempfile.TemporaryDirectory() as directory:
            for username, password in [("editor\nOTHER=value", "Deployment test password!"), ("editor", "short")]:
                path = Path(directory) / ".env"
                with self.assertRaises(ValueError):
                    configure.write_environment(path, username, password)
                self.assertFalse(path.exists())


if __name__ == "__main__":
    unittest.main()
