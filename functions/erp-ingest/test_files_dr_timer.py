import logging
import json
from contextlib import contextmanager
from pathlib import Path
from types import SimpleNamespace

import pytest


@pytest.fixture
def timer_function(monkeypatch):
    function_app = pytest.importorskip("function_app")
    monkeypatch.setenv("FILES_DR_SYNC_ENABLED", "true")
    monkeypatch.setenv("FILES_DR_PRIMARY_ACCOUNT", "andeslogsource")
    monkeypatch.setenv("FILES_DR_SECONDARY_ACCOUNT", "andeslogdr")
    monkeypatch.setenv("FILES_DR_SHARE_NAME", "andeslog")
    monkeypatch.setenv("FILES_DR_SYNC_IDENTITY_CLIENT_ID", "00000000-0000-0000-0000-000000000001")
    return function_app, function_app.azure_files_disaster_recovery_sync._function.get_user_function()


def test_success_marker_reports_scan_start_and_duration(timer_function, monkeypatch, caplog):
    function_app, timer = timer_function
    monkeypatch.setattr(function_app, "sync_share", lambda **_: SimpleNamespace(
        stdout='{"copied": 1}', started_utc="2026-11-10T12:30:45.123Z", duration_ms=2134
    ))
    with caplog.at_level(logging.INFO):
        timer(None)
    assert "FILES_DR_SYNC_SUCCESS" in caplog.text
    assert "started_utc=2026-11-10T12:30:45.123Z" in caplog.text
    assert "duration_ms=2134" in caplog.text


def test_expired_scan_does_not_emit_success_marker(timer_function, monkeypatch, caplog):
    function_app, timer = timer_function

    def timed_out(**_):
        raise TimeoutError("scan exceeded deadline")

    monkeypatch.setattr(function_app, "sync_share", timed_out)
    with caplog.at_level(logging.INFO), pytest.raises(RuntimeError, match="sync failed"):
        timer(None)
    assert "FILES_DR_SYNC_FAILURE" in caplog.text
    assert "FILES_DR_SYNC_SUCCESS" not in caplog.text


@pytest.mark.parametrize("message,reason", [
    ("Azure Files source directory did not return its security descriptor key.", "source_directory_acl_missing"),
    ("secret path should not appear in logs", "unknown"),
])
def test_failure_diagnostic_only_reports_whitelisted_reasons(timer_function, monkeypatch, caplog, message, reason):
    function_app, timer = timer_function

    def fail(**_):
        raise RuntimeError(message)

    monkeypatch.setattr(function_app, "sync_share", fail)
    with caplog.at_level(logging.ERROR), pytest.raises(RuntimeError, match="sync failed"):
        timer(None)
    assert f"reason={reason}" in caplog.text
    assert message not in caplog.text


@pytest.mark.parametrize("fail", [False, True])
def test_checkpoint_lifetime_wraps_sync_and_releases_on_failure(timer_function, monkeypatch, caplog, fail):
    function_app, timer = timer_function
    monkeypatch.setenv("FILES_DR_CHECKPOINT_ENABLED", "true")
    state = {"opened": False, "closed": False}
    checkpoint = object()

    @contextmanager
    def fake_checkpoint(*_):
        state["opened"] = True
        try:
            yield checkpoint
        finally:
            state["closed"] = True

    def sync(**kwargs):
        assert state["opened"] and not state["closed"]
        assert kwargs["checkpoint_store"] is checkpoint
        if fail:
            raise TimeoutError("interrupted")
        return SimpleNamespace(stdout="", started_utc="2026-11-10T12:30:45Z", duration_ms=1)

    monkeypatch.setattr(function_app, "files_dr_checkpoint", fake_checkpoint)
    monkeypatch.setattr(function_app, "sync_share", sync)
    with caplog.at_level(logging.INFO):
        if fail:
            with pytest.raises(RuntimeError, match="sync failed"):
                timer(None)
        else:
            timer(None)
    assert state["closed"]
    assert ("FILES_DR_SYNC_SUCCESS" in caplog.text) is not fail


def test_monitoring_does_not_sample_heartbeat_and_exception_types():
    host = json.loads((Path(__file__).parent / "host.json").read_text(encoding="utf-8"))
    excluded = set(host["logging"]["applicationInsights"]["samplingSettings"]["excludedTypes"].split(";"))
    assert {"Trace", "Exception"}.issubset(excluded)
