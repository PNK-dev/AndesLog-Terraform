"""Local end-to-end outbox, HTTP and Azurite test. Never contacts Azure."""

import http.server
import importlib.util
import json
import os
import socket
import sys
import threading
import time
import uuid
from pathlib import Path
from urllib.parse import urlparse
from urllib.error import HTTPError
from urllib.request import Request, urlopen

import pytest


@pytest.fixture
def local_archive():
    connection = os.environ.get("ANDESLOG_AZURITE_CONNECTION_STRING", "")
    if not connection:
        pytest.skip("A loopback Azurite instance is required")
    parts = dict(part.split("=", 1) for part in connection.split(";") if "=" in part)
    endpoint = urlparse(parts.get("BlobEndpoint", ""))
    if endpoint.scheme != "http" or endpoint.hostname != "127.0.0.1" or not endpoint.port:
        raise ValueError("Only loopback Azurite is permitted")
    from azure.storage.blob import BlobServiceClient

    service = BlobServiceClient.from_connection_string(connection, api_version="2023-11-03")
    container = service.get_container_client("andeslog-event-test-" + uuid.uuid4().hex)
    container.create_container()
    try:
        yield service, container
    finally:
        container.delete_container()
        service.close()


def test_lost_response_is_retried_and_stored_only_once(local_archive, tmp_path, monkeypatch):
    import azure.functions as func
    import function_app

    erp_root = Path(__file__).resolve().parents[3] / "ERP-APP"
    if not (erp_root / "app" / "outbox_worker.py").is_file():
        pytest.skip("ERP-APP sibling repository is required")
    monkeypatch.syspath_prepend(str(erp_root))
    from app import create_app
    from app.models import OutboxEvent, db, utcnow_naive
    from app.outbox import enqueue_event
    from app.outbox_worker import post_event, process_once

    service, container = local_archive
    secret = "local-test-hmac-secret-at-least-thirty-two-characters"
    monkeypatch.setenv("ERP_INGEST_HMAC_SECRET", secret)
    monkeypatch.setenv("ERP_EVENTS_ACCOUNT_NAME", "local-only")
    monkeypatch.setenv("ERP_EVENTS_CONTAINER", container.container_name)
    monkeypatch.setattr(function_app, "DefaultAzureCredential", lambda **_: object())
    monkeypatch.setattr(function_app, "BlobServiceClient", lambda **_: service)
    handler = function_app.erp_event_ingest._function.get_user_function()
    observations = []

    class Ingress(http.server.BaseHTTPRequestHandler):
        def do_POST(self):
            body = self.rfile.read(int(self.headers["Content-Length"]))
            request = func.HttpRequest(method="POST", url="http://localhost/api/erp/events",
                                       headers=dict(self.headers), body=body)
            response = handler(request)
            observations.append(response.status_code)
            if len(observations) == 1:
                # Azure accepted and stored the event, but the client sees no response.
                self.connection.shutdown(socket.SHUT_RDWR)
                self.connection.close()
                return
            payload = response.get_body()
            self.send_response(response.status_code)
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)

        def log_message(self, *_):
            pass

    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Ingress)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    app = create_app({"TESTING": True, "SECRET_KEY": "local-only",
                      "SQLALCHEMY_DATABASE_URI": f"sqlite:///{tmp_path / 'outbox.db'}",
                      "ERP_AZURE_INGEST_URL": f"http://127.0.0.1:{server.server_port}/api/erp/events",
                      "ERP_AZURE_INGEST_HMAC_SECRET": secret})
    try:
        with app.app_context():
            db.create_all()
            event = enqueue_event("erp.test", "test", "lost-response", {"demo": True})
            db.session.commit()
            event_id = event.id
        assert process_once(app, event_id=event_id)
        with app.app_context():
            event = db.session.get(OutboxEvent, event_id)
            assert event.status == "pending"
            assert event.attempts == 1
            event.available_at = utcnow_naive()
            db.session.commit()
        assert process_once(app, event_id=event_id)
        with app.app_context():
            event = db.session.get(OutboxEvent, event_id)
            assert event.status == "delivered"
            assert event.attempts == 2
            audit_row = {key: getattr(event, key) for key in
                         ("id", "event_type", "aggregate_type", "aggregate_id", "payload", "created_at")}
        assert observations == [202, 200]
        blobs = list(container.list_blobs())
        assert [blob.name for blob in blobs] == [f"{event_id}.json"]
        stored = json.loads(container.get_blob_client(f"{event_id}.json").download_blob().readall())
        assert stored["id"] == event_id and stored["payload"] == {"demo": True}
        altered = dict(stored, payload={"demo": False})
        altered_body = json.dumps(altered, ensure_ascii=False, separators=(",", ":"), sort_keys=True).encode()
        with pytest.raises(HTTPError) as conflict:
            post_event(f"http://127.0.0.1:{server.server_port}/api/erp/events", secret, altered_body)
        assert conflict.value.code == 409
        bad_signature = Request(f"http://127.0.0.1:{server.server_port}/api/erp/events", data=altered_body,
                                headers={"X-AndesLog-Signature": "sha256=invalid"}, method="POST")
        with pytest.raises(HTTPError) as unauthorized:
            urlopen(bad_signature, timeout=5)
        assert unauthorized.value.code == 401
        assert observations == [202, 200, 409, 401]
        assert json.loads(container.get_blob_client(f"{event_id}.json").download_blob().readall()) == stored

        # Compare actual SDK Blob downloads to the ERP's serialized event.
        audit_path = Path(__file__).resolve().parents[2] / "scripts" / "reconcile-erp-archive.py"
        spec = importlib.util.spec_from_file_location("reconcile_erp_archive", audit_path)
        audit = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(audit)
        missing = dict(audit_row, id=str(uuid.uuid4()))
        different = dict(audit_row, id=str(uuid.uuid4()))
        container.get_blob_client(f"{different['id']}.json").upload_blob(b"different")
        summary, issues = audit.audit_rows([audit_row, missing, different], container,
                                          limit=10, deadline=time.monotonic() + 20)
        assert summary == {"checked": 3, "matching": 1, "missing": 1, "different": 1, "truncated": False}
        assert {entry["status"] for entry in issues} == {"missing", "different"}
        primary = service.get_container_client("andeslog-primary-test-" + uuid.uuid4().hex)
        primary.create_container()
        try:
            summary, issues = audit.audit_failback_rows([audit_row], container, primary,
                                                      limit=10, deadline=time.monotonic() + 20)
            assert summary["needs_copy"] == 1 and issues[0]["event_id"] == event_id
            assert list(primary.list_blobs()) == []  # preview must never write
            primary.get_blob_client(f"{event_id}.json").upload_blob(altered_body)
            summary, _ = audit.audit_failback_rows([audit_row], container, primary,
                                                  limit=10, deadline=time.monotonic() + 20)
            assert summary["conflict"] == 1
            primary.get_blob_client(f"{event_id}.json").upload_blob(audit.canonical_event(audit_row)[1], overwrite=True)
            summary, issues = audit.audit_failback_rows([audit_row], container, primary,
                                                        limit=10, deadline=time.monotonic() + 20)
            assert summary["already_present"] == 1 and issues == []
        finally:
            primary.delete_container()
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)
        with app.app_context():
            db.session.remove()
            db.engine.dispose()


def test_regional_outage_routes_to_secondary_and_records_destination(local_archive, tmp_path, monkeypatch):
    import azure.functions as func
    import function_app

    erp_root = Path(__file__).resolve().parents[3] / "ERP-APP"
    if not (erp_root / "app" / "outbox_worker.py").is_file():
        pytest.skip("ERP-APP sibling repository is required")
    monkeypatch.syspath_prepend(str(erp_root))
    from app import create_app
    from app.models import OutboxEvent, db
    from app.outbox import enqueue_event
    from app.outbox_worker import post_event, process_once

    service, primary_container = local_archive
    secondary_container = service.get_container_client("andeslog-secondary-" + uuid.uuid4().hex)
    secondary_container.create_container()
    secrets = {"primary": "primary-local-hmac-secret-at-least-thirty-two-characters",
               "secondary": "secondary-local-hmac-secret-at-least-thirty-two-characters"}
    containers = {"primary": primary_container, "secondary": secondary_container}
    monkeypatch.setenv("ERP_INGEST_HMAC_SECRET", secrets["primary"])
    monkeypatch.setenv("ERP_EVENTS_ACCOUNT_NAME", "local-only")
    monkeypatch.setenv("ERP_EVENTS_CONTAINER", primary_container.container_name)
    monkeypatch.setattr(function_app, "DefaultAzureCredential", lambda **_: object())
    monkeypatch.setattr(function_app, "BlobServiceClient", lambda **_: service)
    handler = function_app.erp_event_ingest._function.get_user_function()
    state = {"primary_mode": "down", "seen": []}
    invocation_lock = threading.Lock()

    class RegionalIngress(http.server.BaseHTTPRequestHandler):
        def do_POST(self):
            role = self.server.role
            body = self.rfile.read(int(self.headers["Content-Length"]))
            if role == "primary" and state["primary_mode"] == "down":
                state["seen"].append((role, 503))
                self.send_response(503)
                self.end_headers()
                return
            with invocation_lock:
                os.environ["ERP_INGEST_HMAC_SECRET"] = secrets[role]
                os.environ["ERP_EVENTS_CONTAINER"] = containers[role].container_name
                req = func.HttpRequest(method="POST", url="http://localhost/api/erp/events",
                                       headers=dict(self.headers), body=body)
                response = handler(req)
            state["seen"].append((role, response.status_code))
            if role == "primary" and state["primary_mode"] == "drop":
                self.connection.shutdown(socket.SHUT_RDWR)
                self.connection.close()
                return
            payload = response.get_body()
            self.send_response(response.status_code)
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)

        def log_message(self, *_):
            pass

    servers = []
    threads = []
    for role in ("primary", "secondary"):
        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), RegionalIngress)
        server.role = role
        servers.append(server)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        threads.append(thread)
        thread.start()
    app = create_app({"TESTING": True, "SECRET_KEY": "local-only",
                      "SQLALCHEMY_DATABASE_URI": f"sqlite:///{tmp_path / 'regional-outbox.db'}",
                      "ERP_AZURE_INGEST_URL": f"http://127.0.0.1:{servers[0].server_port}/api/erp/events",
                      "ERP_AZURE_INGEST_FALLBACK_URL": f"http://127.0.0.1:{servers[1].server_port}/api/erp/events",
                      "ERP_AZURE_INGEST_HMAC_SECRET": secrets["primary"],
                      "ERP_AZURE_INGEST_FALLBACK_HMAC_SECRET": secrets["secondary"]})
    try:
        with app.app_context():
            db.create_all()
            event = enqueue_event("erp.test", "test", "regional-down", {"demo": True})
            db.session.commit()
            first_id = event.id
        assert process_once(app, first_id)
        with app.app_context():
            row = db.session.get(OutboxEvent, first_id)
            assert row.status == "delivered" and row.delivered_destination == "secondary"
            first_row = {key: getattr(row, key) for key in
                         ("id", "event_type", "aggregate_type", "aggregate_id", "payload", "created_at", "status", "delivered_destination")}
        assert state["seen"] == [("primary", 503), ("secondary", 202)]
        assert [item.name for item in secondary_container.list_blobs()] == [f"{first_id}.json"]
        assert not list(primary_container.list_blobs())

        # The primary saves the next event but loses its response; both regions
        # can store the same ID, and the ERP records the accepting secondary.
        state["primary_mode"] = "drop"
        with app.app_context():
            event = enqueue_event("erp.test", "test", "regional-lost-reply", {"demo": True})
            db.session.commit()
            second_id = event.id
        assert process_once(app, second_id)
        with app.app_context():
            row = db.session.get(OutboxEvent, second_id)
            assert row.status == "delivered" and row.delivered_destination == "secondary"
            second_row = {key: getattr(row, key) for key in
                          ("id", "event_type", "aggregate_type", "aggregate_id", "payload", "created_at", "status", "delivered_destination")}
        first = primary_container.get_blob_client(f"{second_id}.json").download_blob().readall()
        second = secondary_container.get_blob_client(f"{second_id}.json").download_blob().readall()
        assert first == second

        state["primary_mode"] = "live"
        with app.app_context():
            event = enqueue_event("erp.test", "test", "regional-recovery", {"demo": True})
            db.session.commit()
            third_id = event.id
        assert process_once(app, third_id)
        with app.app_context():
            row = db.session.get(OutboxEvent, third_id)
            assert row.status == "delivered" and row.delivered_destination == "primary"
        assert primary_container.get_blob_client(f"{third_id}.json").exists()

        # Replay through the real authenticated primary Function. A lost reply
        # after storage must be safe to retry without changing existing events.
        replay_path = Path(__file__).resolve().parents[2] / "scripts" / "erp_failback_replay.py"
        spec = importlib.util.spec_from_file_location("erp_failback_replay", replay_path)
        replay = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(replay)
        monkeypatch.syspath_prepend(str(replay_path.parent))
        from erp_failback_execute import send_receipt
        def send(event_id, body):
            return send_receipt(f"http://127.0.0.1:{servers[0].server_port}/api/erp/events", secrets["primary"], event_id, body)
        state["primary_mode"] = "drop"
        with pytest.raises(OSError):
            replay.replay_batch([first_row, second_row], secondary_container, primary_container, send,
                                limit=10, deadline=time.monotonic() + 20)
        state["primary_mode"] = "live"
        result = replay.replay_batch([first_row, second_row], secondary_container, primary_container, send,
                                     limit=10, deadline=time.monotonic() + 20)
        assert result == {"checked": 2, "restored": 0, "already_present": 2}
        assert primary_container.get_blob_client(f"{first_id}.json").download_blob().readall() == secondary_container.get_blob_client(f"{first_id}.json").download_blob().readall()
    finally:
        for server in servers:
            server.shutdown()
            server.server_close()
        for thread in threads:
            thread.join(timeout=5)
        with app.app_context():
            db.session.remove()
            db.engine.dispose()
        secondary_container.delete_container()
