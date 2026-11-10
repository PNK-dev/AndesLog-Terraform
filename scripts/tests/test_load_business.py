import importlib.util
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

spec = importlib.util.spec_from_file_location("load_test_business", Path(__file__).parents[1] / "load-test-business.py")
business = importlib.util.module_from_spec(spec)
spec.loader.exec_module(business)


class Handler(BaseHTTPRequestHandler):
    login_location = "/"

    def log_message(self, *_args):
        pass

    def do_GET(self):
        if self.path == "/login":
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b'<input type="hidden" name="csrf_token" value="example">')
        else:
            self.send_response(302)
            self.send_header("Location", "https://example.invalid/collect")
            self.end_headers()

    def do_POST(self):
        self.send_response(302)
        self.send_header("Location", self.login_location)
        self.end_headers()


class LoadBusinessSafetyTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()
        cls.base = f"http://127.0.0.1:{cls.server.server_port}"

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()
        cls.thread.join()

    def test_remote_http_requires_explicit_opt_in(self):
        with self.assertRaises(ValueError):
            business.base_url("http://erp.example", False)
        self.assertEqual(business.base_url("http://erp.example", True), "http://erp.example")

    def test_redirect_does_not_send_login_to_another_host(self):
        Handler.login_location = "https://example.invalid/collect"
        with self.assertRaises(RuntimeError):
            business.login(self.base, "test", "fake-test-password", 2)

    def test_redirect_from_authenticated_endpoint_is_failure(self):
        Handler.login_location = "/"
        with self.assertRaises(RuntimeError):
            business.login(self.base, "test", "fake-test-password", 2)


if __name__ == "__main__":
    unittest.main()
