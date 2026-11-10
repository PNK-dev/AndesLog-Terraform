import importlib.util
import json
from datetime import datetime
from pathlib import Path
from types import SimpleNamespace
from uuid import uuid4

import pytest
from azure.core import MatchConditions
from azure.core.exceptions import HttpResponseError, ResourceNotFoundError


module_path = Path(__file__).resolve().parents[1] / "reconcile-erp-archive.py"
spec = importlib.util.spec_from_file_location("reconcile_erp_archive", module_path)
audit = importlib.util.module_from_spec(spec)
spec.loader.exec_module(audit)
replay_spec = importlib.util.spec_from_file_location("erp_failback_replay", module_path.with_name("erp_failback_replay.py"))
replay = importlib.util.module_from_spec(replay_spec)
replay_spec.loader.exec_module(replay)


def event():
    return {"id": str(uuid4()), "event_type": "erp.order.created", "aggregate_type": "order",
            "aggregate_id": "17", "created_at": datetime(2026, 11, 10, 12, 30, 1, 100),
            "payload": {"ciudad": "Lima", "número": "01"}}


class Blob:
    def __init__(self, body=None, error_code="BlobNotFound"):
        self.body = body
        self.error_code = error_code

    def get_blob_properties(self):
        if self.body is None:
            error = ResourceNotFoundError(message="not found")
            error.error_code = self.error_code
            raise error
        return SimpleNamespace(etag='"etag-1"', size=len(self.body))

    def download_blob(self, **kwargs):
        assert kwargs == {"etag": '"etag-1"', "match_condition": MatchConditions.IfNotModified, "decompress": False}
        return SimpleNamespace(readall=lambda: self.body)


class Container:
    def __init__(self, blobs):
        self.blobs = blobs

    def get_blob_client(self, name):
        return self.blobs.get(name, Blob())


def test_matching_missing_and_different_are_separate():
    matching, missing, different = event(), event(), event()
    match_id, body = audit.canonical_event(matching)
    blobs = {f"{match_id}.json": Blob(body), f"{different['id']}.json": Blob(b"different")}
    result, issues = audit.audit_rows([matching, missing, different], Container(blobs), limit=10, deadline=100, clock=lambda: 0)
    assert result == {"checked": 3, "matching": 1, "missing": 1, "different": 1, "truncated": False}
    assert issues == [{"event_id": missing["id"], "status": "missing"}, {"event_id": different["id"], "status": "different"}]


def test_missing_container_is_not_reported_as_missing_event():
    row = event()
    container = Container({f"{row['id']}.json": Blob(None, "ContainerNotFound")})
    with pytest.raises(audit.AuditError, match="container"):
        audit.audit_rows([row], container, limit=10, deadline=100, clock=lambda: 0)


def test_authorization_failure_is_not_reported_as_missing_event():
    class Forbidden(Blob):
        def get_blob_properties(self):
            raise HttpResponseError(message="forbidden")

    row = event()
    with pytest.raises(HttpResponseError):
        audit.audit_rows([row], Container({f"{row['id']}.json": Forbidden()}), limit=10, deadline=100, clock=lambda: 0)


def test_truncation_and_deadline_are_not_full_comparison():
    first, second = event(), event()
    result, _ = audit.audit_rows([first, second], Container({}), limit=1, deadline=100, clock=lambda: 0)
    assert result["checked"] == 1 and result["truncated"]
    with pytest.raises(TimeoutError):
        audit.audit_rows([first], Container({}), limit=1, deadline=1, clock=lambda: 1)


def test_report_never_overwrites_existing_file(tmp_path):
    path = tmp_path / "report.json"
    audit.write_report(path, {"checked": 1}, [{"event_id": "test-id", "status": "missing"}])
    assert json.loads(path.read_text(encoding="utf-8"))["summary"] == {"checked": 1}
    with pytest.raises(FileExistsError):
        audit.write_report(path, {}, [])


def test_bad_database_event_fails_closed():
    row = event()
    row["id"] = "not-a-uuid"
    with pytest.raises(audit.AuditError):
        audit.canonical_event(row)


def test_failback_preview_distinguishes_copy_conflicts_and_bad_source():
    present, to_copy, conflict, missing_source, corrupt_source = [event() for _ in range(5)]
    source_blobs = {}
    primary_blobs = {}
    for row in (present, to_copy, conflict):
        _, body = audit.canonical_event(row)
        source_blobs[f"{row['id']}.json"] = Blob(body)
    _, present_body = audit.canonical_event(present)
    primary_blobs[f"{present['id']}.json"] = Blob(present_body)
    primary_blobs[f"{conflict['id']}.json"] = Blob(b"different")
    source_blobs[f"{corrupt_source['id']}.json"] = Blob(b"different")
    result, issues = audit.audit_failback_rows([present, to_copy, conflict, missing_source, corrupt_source],
                                              Container(source_blobs), Container(primary_blobs),
                                              limit=10, deadline=100, clock=lambda: 0)
    assert result == {"checked": 5, "already_present": 1, "needs_copy": 1,
                      "source_problem": 2, "conflict": 1, "truncated": False}
    assert issues == [{"event_id": to_copy["id"], "status": "needs_copy"},
                      {"event_id": conflict["id"], "status": "conflict"},
                      {"event_id": missing_source["id"], "status": "source_problem", "source_status": "missing"},
                      {"event_id": corrupt_source["id"], "status": "source_problem", "source_status": "different"}]


def test_failback_preview_stops_on_inaccessible_target_and_reports_truncation():
    class Forbidden(Blob):
        def get_blob_properties(self):
            raise HttpResponseError(message="forbidden")

    first, second = event(), event()
    _, body = audit.canonical_event(first)
    source = Container({f"{first['id']}.json": Blob(body)})
    with pytest.raises(HttpResponseError):
        audit.audit_failback_rows([first], source, Container({f"{first['id']}.json": Forbidden()}),
                                 limit=1, deadline=100, clock=lambda: 0)
    result, _ = audit.audit_failback_rows([first, second], source, Container({}), limit=1, deadline=100, clock=lambda: 0)
    assert result["checked"] == 1 and result["needs_copy"] == 1 and result["truncated"]
    with pytest.raises(TimeoutError):
        audit.audit_failback_rows([first], source, Container({}), limit=1, deadline=1, clock=lambda: 1)


def delivered_event():
    return dict(event(), status="delivered", delivered_destination="secondary")


def test_replay_recovers_lost_response_idempotently():
    row = delivered_event()
    _, body = audit.canonical_event(row)
    source = Container({f"{row['id']}.json": Blob(body)})
    primary = Container({})
    calls = []

    def lost_response(event_id, sent):
        calls.append(event_id)
        primary.blobs[f"{event_id}.json"] = Blob(sent)
        raise TimeoutError("lost response")

    with pytest.raises(TimeoutError):
        replay.replay_batch([row], source, primary, lost_response, limit=10, deadline=100, clock=lambda: 0)
    result = replay.replay_batch([row], source, primary, lost_response, limit=10, deadline=100, clock=lambda: 0)
    assert result == {"checked": 1, "restored": 0, "already_present": 1}
    assert calls == [row["id"]]


def test_replay_blocks_whole_batch_before_any_send_on_conflict_or_unconfirmed():
    one, two = delivered_event(), delivered_event()
    source = Container({f"{row['id']}.json": Blob(audit.canonical_event(row)[1]) for row in (one, two)})
    primary = Container({f"{two['id']}.json": Blob(b"wrong")})
    calls = []
    with pytest.raises(replay.audit.AuditError, match="preflight"):
        replay.replay_batch([one, two], source, primary, lambda *x: calls.append(x), limit=10, deadline=100, clock=lambda: 0)
    assert not calls
    with pytest.raises(replay.audit.AuditError, match="unconfirmed"):
        replay.replay_batch([dict(one, status="pending")], source, primary, lambda *x: calls.append(x),
                            limit=10, deadline=100, clock=lambda: 0)
    with pytest.raises(replay.audit.AuditError, match="too large"):
        replay.replay_batch(iter([one, two]), source, primary, lambda *x: calls.append(x), limit=1, deadline=100, clock=lambda: 0)
    assert not calls


def test_replay_requires_receipt_and_verified_primary_copy():
    row = delivered_event()
    _, body = audit.canonical_event(row)
    source = Container({f"{row['id']}.json": Blob(body)})
    primary = Container({})
    with pytest.raises(replay.audit.AuditError, match="invalid receipt"):
        replay.replay_batch([row], source, primary, lambda *_: {"id": "wrong", "status": "stored"},
                            limit=10, deadline=100, clock=lambda: 0)
    with pytest.raises(replay.audit.AuditError, match="could not be verified"):
        replay.replay_batch([row], source, primary, lambda event_id, _: {"id": event_id, "status": "stored"},
                            limit=10, deadline=100, clock=lambda: 0)


def test_replay_counts_restored_and_does_not_repeat_present_event():
    row = delivered_event()
    _, body = audit.canonical_event(row)
    source = Container({f"{row['id']}.json": Blob(body)})
    primary = Container({})
    calls = []
    def send(event_id, sent):
        calls.append(event_id)
        primary.blobs[f"{event_id}.json"] = Blob(sent)
        return {"id": event_id, "status": "stored"}
    assert replay.replay_batch([row], source, primary, send, limit=10, deadline=100, clock=lambda: 0) == {
        "checked": 1, "restored": 1, "already_present": 0}
    assert replay.replay_batch([row], source, primary, send, limit=10, deadline=100, clock=lambda: 0)["already_present"] == 1
    assert calls == [row["id"]]


def test_replay_final_verification_detects_changes_to_previously_present_event():
    present, missing = delivered_event(), delivered_event()
    source = Container({f"{row['id']}.json": Blob(audit.canonical_event(row)[1]) for row in (present, missing)})
    primary = Container({f"{present['id']}.json": Blob(audit.canonical_event(present)[1])})
    def send(event_id, body):
        primary.blobs[f"{event_id}.json"] = Blob(body)
        primary.blobs[f"{present['id']}.json"] = Blob(b"changed concurrently")
        return {"id": event_id, "status": "stored"}
    with pytest.raises(replay.audit.AuditError, match="Final"):
        replay.replay_batch([present, missing], source, primary, send, limit=10, deadline=100, clock=lambda: 0)
