import copy
from types import SimpleNamespace

import pytest

from files_dr_checkpoint import CursorMissingError, ScanProgress
from files_dr_sync import sync_share
from test_files_dr_sync import CLIENT_ID, FakeCredential, FakeFile, FakeShare


class MemoryCheckpoint:
    def __init__(self, state=None, on_save=None):
        self.state = copy.deepcopy(state)
        self.on_save = on_save
        self.lost = False

    def load(self):
        return copy.deepcopy(self.state)

    def save(self, state):
        if self.lost:
            raise RuntimeError("lease lost")
        self.state = copy.deepcopy(state)
        if self.on_save:
            self.on_save(self.state)

    def ensure_lease(self):
        if self.lost:
            raise RuntimeError("lease lost")


def factory_for(primary, secondary):
    return lambda account, *_: (primary if account == "andeslogsource" else secondary, FakeCredential())


def test_timeout_resumes_after_last_complete_file_without_recopied_prefix():
    clock = SimpleNamespace(value=0.0)
    primary = FakeShare(files={"a.txt": FakeFile(b"one"), "b.txt": FakeFile(b"two")})
    secondary = FakeShare()

    def expire_after_first(state):
        if state and state["last_file"] == "a.txt":
            clock.value = 6.0

    checkpoint = MemoryCheckpoint(on_save=expire_after_first)
    with pytest.raises(TimeoutError):
        sync_share("andeslogsource", "andeslogdr", "andeslog", CLIENT_ID,
                   client_factory=factory_for(primary, secondary), timeout_seconds=5,
                   clock=lambda: clock.value, checkpoint_store=checkpoint)
    assert checkpoint.state["last_file"] == "a.txt"
    scan_started = checkpoint.state["started_utc"]
    assert bytes(secondary.files["a.txt"].data) == b"one"
    assert "b.txt" not in secondary.files

    clock.value = 0.0
    checkpoint.on_save = None
    result = sync_share("andeslogsource", "andeslogdr", "andeslog", CLIENT_ID,
                        client_factory=factory_for(primary, secondary), timeout_seconds=5,
                        clock=lambda: clock.value, checkpoint_store=checkpoint)
    assert bytes(secondary.files["b.txt"].data) == b"two"
    assert primary.files["a.txt"].download_count == 1
    assert primary.files["b.txt"].download_count == 1
    assert result.started_utc == scan_started
    assert checkpoint.state is None


def test_directory_marker_resumes_inside_directory():
    clock = SimpleNamespace(value=0.0)
    primary = FakeShare(files={"docs/file.txt": FakeFile(b"content")}, directories={"", "docs"})
    secondary = FakeShare()
    checkpoint = MemoryCheckpoint(on_save=lambda state: setattr(clock, "value", 6.0)
                                  if state and state["last_file"] == "docs/" else None)
    with pytest.raises(TimeoutError):
        sync_share("andeslogsource", "andeslogdr", "andeslog", CLIENT_ID,
                   client_factory=factory_for(primary, secondary), timeout_seconds=5,
                   clock=lambda: clock.value, checkpoint_store=checkpoint)
    assert checkpoint.state["last_file"] == "docs/"
    assert "docs/file.txt" not in secondary.files
    clock.value = 0.0
    checkpoint.on_save = None
    sync_share("andeslogsource", "andeslogdr", "andeslog", CLIENT_ID,
               client_factory=factory_for(primary, secondary), timeout_seconds=5,
               clock=lambda: clock.value, checkpoint_store=checkpoint)
    assert bytes(secondary.files["docs/file.txt"].data) == b"content"
    assert checkpoint.state is None


def test_missing_cursor_resets_without_signalling_a_complete_scan():
    state = {"version": 1, "scan_id": "a643b47d-8470-4c52-b489-7b621782df69",
             "started_utc": "2026-11-10T12:00:00Z", "last_file": "deleted.txt"}
    checkpoint = MemoryCheckpoint(state)
    primary = FakeShare(files={"new.txt": FakeFile(b"new")})
    secondary = FakeShare()
    with pytest.raises(CursorMissingError):
        sync_share("andeslogsource", "andeslogdr", "andeslog", CLIENT_ID,
                   client_factory=factory_for(primary, secondary), checkpoint_store=checkpoint)
    assert checkpoint.state is None
    assert "new.txt" not in secondary.files
    sync_share("andeslogsource", "andeslogdr", "andeslog", CLIENT_ID,
               client_factory=factory_for(primary, secondary), checkpoint_store=checkpoint)
    assert bytes(secondary.files["new.txt"].data) == b"new"


def test_lost_lease_stops_processing_after_last_durable_checkpoint():
    primary = FakeShare(files={"a.txt": FakeFile(b"one"), "b.txt": FakeFile(b"two")})
    secondary = FakeShare()
    checkpoint = MemoryCheckpoint()
    checkpoint.on_save = lambda state: setattr(checkpoint, "lost", True) if state and state["last_file"] == "a.txt" else None
    with pytest.raises(RuntimeError, match="lease lost"):
        sync_share("andeslogsource", "andeslogdr", "andeslog", CLIENT_ID,
                   client_factory=factory_for(primary, secondary), checkpoint_store=checkpoint)
    assert checkpoint.state["last_file"] == "a.txt"
    assert "b.txt" not in secondary.files


def test_new_file_before_cursor_waits_for_next_complete_scan():
    state = {"version": 1, "scan_id": "a643b47d-8470-4c52-b489-7b621782df69",
             "started_utc": "2026-11-10T12:00:00Z", "last_file": "b.txt"}
    checkpoint = MemoryCheckpoint(state)
    primary = FakeShare(files={"a.txt": FakeFile(b"new"), "b.txt": FakeFile(b"previous"), "c.txt": FakeFile(b"next")})
    secondary = FakeShare()
    sync_share("andeslogsource", "andeslogdr", "andeslog", CLIENT_ID,
               client_factory=factory_for(primary, secondary), checkpoint_store=checkpoint)
    assert "a.txt" not in secondary.files
    assert bytes(secondary.files["c.txt"].data) == b"next"
    sync_share("andeslogsource", "andeslogdr", "andeslog", CLIENT_ID,
               client_factory=factory_for(primary, secondary), checkpoint_store=checkpoint)
    assert bytes(secondary.files["a.txt"].data) == b"new"


def test_resume_skips_completed_subtrees_but_scans_them_next_cycle():
    class TrackedShare(FakeShare):
        def __init__(self, *args, **kwargs):
            self.visited = []
            super().__init__(*args, **kwargs)
        def get_directory_client(self, path):
            self.visited.append(path.strip("/"))
            return super().get_directory_client(path)

    state = {"version": 1, "scan_id": "a643b47d-8470-4c52-b489-7b621782df69",
             "started_utc": "2026-11-10T12:00:00Z", "last_file": "b/n2.txt"}
    checkpoint = MemoryCheckpoint(state)
    primary = TrackedShare(files={"a/deep/file.txt": FakeFile(b"earlier"), "b/n1.txt": FakeFile(b"previous"),
                                  "b/n2.txt": FakeFile(b"cursor"), "b/n3.txt": FakeFile(b"next"),
                                  "c/last.txt": FakeFile(b"later")}, directories={"", "a", "a/deep", "b", "c"})
    secondary = FakeShare()
    sync_share("andeslogsource", "andeslogdr", "andeslog", CLIENT_ID,
               client_factory=factory_for(primary, secondary), checkpoint_store=checkpoint)
    assert "a" not in primary.visited and "a/deep" not in primary.visited
    assert "b" in primary.visited and "c" in primary.visited
    assert "a/deep/file.txt" not in secondary.files and "b/n1.txt" not in secondary.files
    assert bytes(secondary.files["b/n3.txt"].data) == b"next"
    assert bytes(secondary.files["c/last.txt"].data) == b"later"
    assert checkpoint.state is None
    sync_share("andeslogsource", "andeslogdr", "andeslog", CLIENT_ID,
               client_factory=factory_for(primary, secondary), checkpoint_store=checkpoint)
    assert bytes(secondary.files["a/deep/file.txt"].data) == b"earlier"


def test_resume_missing_nested_cursor_resets_and_never_reports_success():
    state = {"version": 1, "scan_id": "a643b47d-8470-4c52-b489-7b621782df69",
             "started_utc": "2026-11-10T12:00:00Z", "last_file": "b/deleted.txt"}
    checkpoint = MemoryCheckpoint(state)
    primary = FakeShare(files={"a/f.txt": FakeFile(b"first"), "b/current.txt": FakeFile(b"next")},
                        directories={"", "a", "b"})
    secondary = FakeShare()
    with pytest.raises(CursorMissingError):
        sync_share("andeslogsource", "andeslogdr", "andeslog", CLIENT_ID,
                   client_factory=factory_for(primary, secondary), checkpoint_store=checkpoint)
    assert checkpoint.state is None
    assert not secondary.files


def test_cursor_matching_requires_complete_path_components():
    state = {"version": 1, "scan_id": "a643b47d-8470-4c52-b489-7b621782df69",
             "started_utc": "2026-11-10T12:00:00Z", "last_file": "a2/nested/f.txt"}
    progress = ScanProgress(MemoryCheckpoint(state), "2026-11-10T12:01:00Z")
    assert not progress.should_enter_directory("a")
    assert progress.should_enter_directory("a2")
    assert not progress.should_enter_directory("a2/other")
    assert progress.should_enter_directory("a2/nested")
    assert not progress.should_copy_file("a2/nested/f.txt")
    assert progress.should_enter_directory("a")
