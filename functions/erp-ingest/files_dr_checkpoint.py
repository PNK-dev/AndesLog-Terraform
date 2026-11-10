"""Private checkpoint storage and file-boundary progress for a Files scan.

A blob lease protects checkpoint writes; it does not fence concurrent Azure
Files data operations. A live share is not a point-in-time snapshot.
"""

import hashlib
import json
import time
import uuid
from datetime import datetime, timezone

from azure.core.exceptions import ResourceExistsError


MAX_CHECKPOINT_BYTES = 64 * 1024
LEASE_SECONDS = 60
RENEW_AFTER_SECONDS = 20


def checkpoint_blob_name(primary_account: str, secondary_account: str, share_name: str) -> str:
    """Keep account/share identifiers and filenames out of the blob name."""
    identity = json.dumps([primary_account, secondary_account, share_name], separators=(",", ":"))
    return "files-dr/" + hashlib.sha256(identity.encode("utf-8")).hexdigest() + ".json"


def _validate_state(state):
    if not isinstance(state, dict) or set(state) != {"version", "scan_id", "started_utc", "last_file"}:
        raise ValueError("Invalid checkpoint structure")
    if type(state["version"]) is not int or state["version"] != 1:
        raise ValueError("Unsupported checkpoint version")
    try:
        parsed_id = uuid.UUID(state["scan_id"])
        started = datetime.fromisoformat(state["started_utc"].replace("Z", "+00:00"))
    except (ValueError, TypeError, AttributeError):
        raise ValueError("Invalid checkpoint identity or timestamp") from None
    if str(parsed_id) != state["scan_id"] or started.utcoffset() != timezone.utc.utcoffset(started):
        raise ValueError("Checkpoint identity or timestamp is not canonical")
    path = state["last_file"]
    if path is not None and (not isinstance(path, str) or not path or len(path) > 8192 or "\0" in path):
        raise ValueError("Invalid checkpoint cursor")
    return state


class BlobCheckpoint:
    """Lease and read/write one bounded JSON checkpoint with a managed identity."""

    def __init__(self, blob_client, *, clock=time.monotonic):
        self._blob = blob_client
        self._clock = clock
        self._lease = None
        self._renewed_at = None

    def acquire(self):
        if self._lease is not None:
            raise RuntimeError("Checkpoint lease is already held")
        try:
            self._blob.upload_blob(b"null", overwrite=False)
        except ResourceExistsError:
            pass
        self._lease = self._blob.acquire_lease(lease_duration=LEASE_SECONDS)
        self._renewed_at = self._clock()
        return self

    def ensure_lease(self):
        if self._lease is None:
            raise RuntimeError("Checkpoint lease is not held")
        if self._clock() - self._renewed_at >= RENEW_AFTER_SECONDS:
            self._lease.renew()
            self._renewed_at = self._clock()

    def load(self):
        self.ensure_lease()
        chunks = []
        length = 0
        for chunk in self._blob.download_blob(lease=self._lease).chunks():
            self.ensure_lease()
            length += len(chunk)
            if length > MAX_CHECKPOINT_BYTES:
                raise ValueError("Checkpoint exceeds the maximum size")
            chunks.append(chunk)
        try:
            state = json.loads(b"".join(chunks).decode("utf-8"))
        except (ValueError, UnicodeDecodeError):
            raise ValueError("Checkpoint is not valid UTF-8 JSON") from None
        return None if state is None else _validate_state(state)

    def save(self, state):
        self.ensure_lease()
        if state is not None:
            _validate_state(state)
        data = json.dumps(state, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        if len(data) > MAX_CHECKPOINT_BYTES:
            raise ValueError("Checkpoint exceeds the maximum size")
        self._blob.upload_blob(data, overwrite=True, lease=self._lease)

    def close(self):
        if self._lease is not None:
            lease, self._lease = self._lease, None
            self._renewed_at = None
            lease.release()

    def __enter__(self):
        return self.acquire()

    def __exit__(self, _type, _value, _traceback):
        self.close()


class CursorMissingError(RuntimeError):
    """The prior cursor disappeared; a new full scan is needed."""


class ScanProgress:
    """Resume after a completed file or a completed directory ACL update."""

    def __init__(self, store, started_utc):
        self.store = store
        state = store.load()
        if state is None:
            state = {"version": 1, "scan_id": str(uuid.uuid4()), "started_utc": started_utc, "last_file": None}
            store.save(state)
        self.state = _validate_state(state)
        self.resume_after = self.state["last_file"]
        self.found_cursor = self.resume_after is None

    def _advance(self, marker):
        updated = dict(self.state, last_file=marker)
        self.store.save(updated)
        self.state = updated

    def directory_done(self, relative_path):
        if not relative_path:
            return
        marker = relative_path + "/"
        if not self.found_cursor:
            if marker == self.resume_after:
                self.found_cursor = True
            return
        self._advance(marker)

    def should_copy_file(self, relative_path):
        if not self.found_cursor:
            if relative_path == self.resume_after:
                self.found_cursor = True
            return False
        return True

    def should_enter_directory(self, relative_path):
        """Avoid descending into unrelated trees while seeking a saved cursor."""
        if self.found_cursor:
            return True
        # Compare complete path components, not textual prefixes such as a/a2.
        return self.resume_after.startswith(relative_path + "/")

    def file_done(self, relative_path):
        if not self.found_cursor:
            raise RuntimeError("Cannot advance before the saved cursor is found")
        self._advance(relative_path)

    def finish(self):
        if not self.found_cursor:
            self.store.save(None)
            raise CursorMissingError("Saved Files scan cursor no longer exists; restart a full scan")
        started_utc = self.state["started_utc"]
        self.store.save(None)
        return started_utc
