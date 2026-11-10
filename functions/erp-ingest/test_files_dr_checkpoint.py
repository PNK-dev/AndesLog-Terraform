import json
from types import SimpleNamespace

import pytest
from azure.core.exceptions import ResourceExistsError

from files_dr_checkpoint import BlobCheckpoint, MAX_CHECKPOINT_BYTES, checkpoint_blob_name


VALID_STATE = {
    "version": 1,
    "scan_id": "a643b47d-8470-4c52-b489-7b621782df69",
    "started_utc": "2026-11-10T12:00:00Z",
    "last_file": "carpeta/archivo.txt",
}


class FakeLease:
    def __init__(self, blob):
        self.blob = blob
        self.renewals = 0
        self.released = False
        self.fail_renew = False

    def renew(self):
        if self.fail_renew:
            raise RuntimeError("lease lost")
        self.renewals += 1

    def release(self):
        self.released = True
        self.blob.active_lease = None


class FakeBlob:
    def __init__(self, content=None):
        self.content = content
        self.active_lease = None

    def upload_blob(self, data, *, overwrite, lease=None):
        if not overwrite and self.content is not None:
            raise ResourceExistsError(message="exists")
        if overwrite and (not lease or lease is not self.active_lease):
            raise RuntimeError("missing active lease")
        self.content = bytes(data)

    def acquire_lease(self, *, lease_duration):
        assert lease_duration == 60
        if self.active_lease:
            raise RuntimeError("checkpoint already leased")
        self.active_lease = FakeLease(self)
        return self.active_lease

    def download_blob(self, *, lease):
        if not lease or lease is not self.active_lease:
            raise RuntimeError("missing active lease")
        return SimpleNamespace(chunks=lambda: [self.content])


def test_private_checkpoint_survives_a_new_client_session():
    blob = FakeBlob()
    with BlobCheckpoint(blob) as store:
        assert store.load() is None
        store.save(VALID_STATE)
    assert blob.active_lease is None
    with BlobCheckpoint(blob) as store:
        assert store.load() == VALID_STATE
    assert checkpoint_blob_name("primaryaccount", "secondaryaccount", "andeslog").startswith("files-dr/")
    assert "primaryaccount" not in checkpoint_blob_name("primaryaccount", "secondaryaccount", "andeslog")


def test_competing_worker_cannot_take_lease_or_overwrite_progress():
    blob = FakeBlob()
    first = BlobCheckpoint(blob).acquire()
    try:
        first.save(VALID_STATE)
        with pytest.raises(RuntimeError, match="already leased"):
            BlobCheckpoint(blob).acquire()
        assert first.load() == VALID_STATE
    finally:
        first.close()


def test_renewal_failure_prevents_a_checkpoint_write():
    current_time = SimpleNamespace(value=0.0)
    blob = FakeBlob()
    with BlobCheckpoint(blob, clock=lambda: current_time.value) as store:
        store.save(VALID_STATE)
        blob.active_lease.fail_renew = True
        current_time.value = 21.0
        with pytest.raises(RuntimeError, match="lease lost"):
            store.save(dict(VALID_STATE, last_file="another.txt"))
        assert json.loads(blob.content)["last_file"] == "carpeta/archivo.txt"


@pytest.mark.parametrize("content", [b"not-json", b"x" * (MAX_CHECKPOINT_BYTES + 1), b'{"version":99}'], ids=["invalid-json", "too-large", "invalid-schema"])
def test_corrupt_or_oversized_checkpoint_is_rejected(content):
    with BlobCheckpoint(FakeBlob(content)) as store:
        with pytest.raises(ValueError):
            store.load()


def test_checkpoint_rejects_invalid_state_without_replacing_last_good_value():
    blob = FakeBlob()
    with BlobCheckpoint(blob) as store:
        store.save(VALID_STATE)
        with pytest.raises(ValueError):
            store.save(dict(VALID_STATE, last_file="bad\0path"))
        with pytest.raises(ValueError):
            store.save(dict(VALID_STATE, started_utc="2026-11-10T12:00:00"))
        assert store.load() == VALID_STATE
