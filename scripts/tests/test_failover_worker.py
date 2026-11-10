"""Local-only test of readiness probes during a blocking fault request."""

import http.server
import subprocess
import threading
from pathlib import Path


def test_worker_continues_to_sample_during_blocking_operation():
    class Handler(http.server.BaseHTTPRequestHandler):
        calls = 0

        def do_GET(self):
            type(self).calls += 1
            ok = type(self).calls == 1 or type(self).calls >= 6
            body = b'{"status":"ready","database":"ok"}' if ok else b'unavailable'
            self.send_response(200 if ok else 503)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *_):
            pass

    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        script = Path(__file__).with_name("test-failover-worker.ps1")
        url = f"http://127.0.0.1:{server.server_port}/ready"
        result = subprocess.run(["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(script), "-Url", url],
                                capture_output=True, text=True, timeout=30)
        assert result.returncode == 0, result.stdout + result.stderr
        assert "sondas durante la llamada" in result.stdout
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)
