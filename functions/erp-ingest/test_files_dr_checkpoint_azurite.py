"""Optional Blob lease integration test; only accepts a loopback Azurite URL."""

import os
import uuid
from types import SimpleNamespace
from urllib.parse import urlparse

import pytest

from files_dr_checkpoint import BlobCheckpoint


@pytest.fixture
def local_blob():
    connection = os.environ.get("ANDESLOG_AZURITE_CONNECTION_STRING", "")
    if not connection:
        pytest.skip("No local Azurite endpoint was supplied")
    parts = dict(part.split("=", 1) for part in connection.split(";") if "=" in part)
    endpoint = urlparse(parts.get("BlobEndpoint", ""))
    if endpoint.scheme != "http" or endpoint.hostname != "127.0.0.1" or not endpoint.port:
        raise ValueError("The integration test accepts only a loopback Azurite endpoint")
    from azure.storage.blob import BlobServiceClient

    service = BlobServiceClient.from_connection_string(connection, api_version="2023-11-03")
    container = service.get_container_client("andeslog-test-" + uuid.uuid4().hex)
    container.create_container()
    try:
        yield container.get_blob_client("checkpoint.json")
    finally:
        container.delete_container()
        service.close()


def test_lease_serializes_workers_and_preserves_state(local_blob):
    from azure.core.exceptions import HttpResponseError

    state = {
        "version": 1,
        "scan_id": "a643b47d-8470-4c52-b489-7b621782df69",
        "started_utc": "2026-11-10T12:00:00Z",
        "last_file": "docs/file.txt",
    }
    with BlobCheckpoint(local_blob) as first:
        assert first.load() is None
        first.save(state)
        with pytest.raises(HttpResponseError):
            BlobCheckpoint(local_blob).acquire()
        assert first.load() == state
    with BlobCheckpoint(local_blob) as second:
        assert second.load() == state


def test_broken_lease_cannot_write_checkpoint(local_blob):
    from azure.core.exceptions import HttpResponseError

    store = BlobCheckpoint(local_blob).acquire()
    store._lease.break_lease(lease_break_period=0)
    replacement = local_blob.acquire_lease(lease_duration=60)
    try:
        with pytest.raises(HttpResponseError):
            store.save(None)
        with pytest.raises(HttpResponseError):
            store.close()
    finally:
        replacement.release()


def test_resume_with_real_blob_lease_and_simulated_files(local_blob):
    from files_dr_sync import sync_share
    from test_files_dr_sync import CLIENT_ID, FakeCredential, FakeFile, FakeShare

    clock = SimpleNamespace(value=0.0)
    source = FakeShare(files={"a.txt": FakeFile(b"one"), "b.txt": FakeFile(b"two")})
    destination = FakeShare()
    factory = lambda account, *_: (source if account == "andeslogsource" else destination, FakeCredential())

    class StopAfterFirstFile(BlobCheckpoint):
        def save(self, state):
            super().save(state)
            if state and state["last_file"] == "a.txt":
                clock.value = 6.0

    with StopAfterFirstFile(local_blob) as checkpoint:
        with pytest.raises(TimeoutError):
            sync_share("andeslogsource", "andeslogdr", "andeslog", CLIENT_ID,
                       client_factory=factory, timeout_seconds=5, clock=lambda: clock.value,
                       checkpoint_store=checkpoint)
        assert checkpoint.load()["last_file"] == "a.txt"
    clock.value = 0.0
    with BlobCheckpoint(local_blob) as checkpoint:
        sync_share("andeslogsource", "andeslogdr", "andeslog", CLIENT_ID,
                   client_factory=factory, timeout_seconds=5, clock=lambda: clock.value,
                   checkpoint_store=checkpoint)
        assert checkpoint.load() is None
    assert source.files["a.txt"].download_count == 1
    assert bytes(destination.files["b.txt"].data) == b"two"
