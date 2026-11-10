import http.server
import json
import sys
import threading
from pathlib import Path
from urllib.error import HTTPError

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import erp_failback_execute as execute


@pytest.mark.parametrize("value", [
    "http://good.azurewebsites.net/api/erp/events",
    "https://user@good.azurewebsites.net/api/erp/events",
    "https://good.azurewebsites.net:443/api/erp/events",
    "https://good.azurewebsites.net/api/erp/events?secret=x",
    "https://good.azurewebsites.net/api/erp/events#fragment",
    "https://good.azurewebsites.net/api/erp/\nevents",
    "https://good.azurewebsites.net.evil.example/api/erp/events",
    "https://good.azurewebsites.net/other",
])
def test_url_validation_rejects_unsafe_destinations(value):
    with pytest.raises(ValueError):
        execute.validate_primary_url(value)


def test_url_validation_accepts_azure_https():
    execute.validate_primary_url("https://andeslog-primary.azurewebsites.net/api/erp/events")


def test_sender_never_follows_redirect():
    class Sink(http.server.BaseHTTPRequestHandler):
        calls = 0
        def do_POST(self):
            Sink.calls += 1
            self.send_response(200)
            self.end_headers()
        def log_message(self, *_):
            pass
    sink = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Sink)
    class Redirect(http.server.BaseHTTPRequestHandler):
        def do_POST(self):
            self.send_response(302)
            self.send_header("Location", f"http://127.0.0.1:{sink.server_port}/elsewhere")
            self.end_headers()
        def log_message(self, *_):
            pass
    redirect = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Redirect)
    threads = [threading.Thread(target=server.serve_forever, daemon=True) for server in (sink, redirect)]
    for thread in threads:
        thread.start()
    try:
        with pytest.raises(HTTPError):
            execute.send_receipt(f"http://127.0.0.1:{redirect.server_port}/api/erp/events", "secret", "id", b"{}")
        assert Sink.calls == 0
    finally:
        for server in (sink, redirect):
            server.shutdown()
            server.server_close()
        for thread in threads:
            thread.join(timeout=5)


@pytest.mark.parametrize("receipt", [{"id": "other", "status": "stored"}, {"id": "id", "status": []},
                                      {"id": "id", "status": "ok"}, "not-json"])
def test_sender_rejects_untrusted_receipt(receipt):
    class Response:
        status = 200
        def __enter__(self):
            return self
        def __exit__(self, *_):
            pass
        def read(self, _):
            return receipt.encode() if isinstance(receipt, str) else json.dumps(receipt).encode()
    class Opener:
        def open(self, request, timeout):
            assert request.headers["X-andeslog-signature"].startswith("sha256=")
            assert timeout == 10
            return Response()
    with pytest.raises(ValueError):
        execute.send_receipt("https://example.test", "secret", "id", b"{}", opener=Opener())


def test_preview_never_sends_and_closes_clients(monkeypatch, tmp_path, capsys):
    ca = tmp_path / "ca.pem"
    ca.write_text("test-only", encoding="utf-8")
    closed = []
    class Credential:
        def close(self):
            closed.append("identity")
    class Service:
        def __init__(self, *, account_url, **_):
            self.account_url = account_url
        def get_container_client(self, name):
            return (self.account_url, name)
        def close(self):
            closed.append(self.account_url)
    class Connection:
        def __enter__(self):
            return self
        def __exit__(self, *_):
            pass
    monkeypatch.setattr(execute, "DefaultAzureCredential", lambda **_: Credential())
    monkeypatch.setattr(execute, "BlobServiceClient", Service)
    monkeypatch.setattr(execute.psycopg, "connect", lambda **_: Connection())
    monkeypatch.setattr(execute, "read_confirmed_batch", lambda *_, **__: [{"id": "synthetic"}])
    monkeypatch.setattr(execute.replay.audit, "audit_failback_rows", lambda *_, **__: (
        {"checked": 1, "already_present": 0, "needs_copy": 1, "source_problem": 0, "conflict": 0, "truncated": False}, []))
    monkeypatch.setattr(execute, "send_receipt", lambda *_: pytest.fail("preview sent an event"))
    args = ["--service", "lab", "--expected-db-host", "db.example", "--ca-bundle", str(ca),
            "--secondary-account", "secondary123", "--primary-account", "primary123",
            "--primary-url", "https://example.azurewebsites.net/api/erp/events"]
    assert execute.main(args) == 2
    assert json.loads(capsys.readouterr().out)["mode"] == "preview"
    assert len(closed) == 3


def test_execution_requires_secret_before_opening_clients(monkeypatch, tmp_path):
    ca = tmp_path / "ca.pem"
    ca.write_text("test-only", encoding="utf-8")
    monkeypatch.delenv("ERP_FAILBACK_HMAC_SECRET", raising=False)
    monkeypatch.setattr(execute, "DefaultAzureCredential", lambda **_: pytest.fail("unexpected credential access"))
    with pytest.raises(SystemExit) as error:
        execute.main(["--service", "lab", "--expected-db-host", "db.example", "--ca-bundle", str(ca),
                      "--secondary-account", "secondary123", "--primary-account", "primary123",
                      "--primary-url", "https://example.azurewebsites.net/api/erp/events", "--execute"])
    assert error.value.code == 2
