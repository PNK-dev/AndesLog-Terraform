import sys
import hashlib
import base64
import gzip
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from datetime import datetime
from types import ModuleType, SimpleNamespace

import pytest

from files_dr_sync import _azure_share_client, _sync_directory_security, _sync_file, sync_share


CLIENT_ID = "00000000-0000-0000-0000-000000000001"


class FakeCredential:
    def __init__(self):
        self.closed = False

    def close(self):
        self.closed = True


class FakeDownloader:
    def __init__(self, data):
        self.data = data

    def chunks(self):
        yield bytes(self.data)


class NotFound(Exception):
    status_code = 404


class FakeFile:
    def __init__(self, source_data=None, etag='"source-etag"'):
        self.source_data = source_data
        self.etag = etag
        self.data = bytearray()
        self.metadata = {}
        self.download_count = 0

    def get_file_properties(self):
        if self.source_data is None and not self.created:
            raise NotFound()
        data = self.source_data if self.source_data is not None else self.data
        return SimpleNamespace(size=len(data), etag=self.etag, metadata=dict(self.metadata),
                               permission_key=getattr(self, "permission_key", None) or "source-key")

    @property
    def created(self):
        return hasattr(self, "_created") and self._created

    def download_file(self, *, decompress):
        assert decompress is False
        self.download_count += 1
        return FakeDownloader(self.source_data if self.source_data is not None else self.data)

    def create_file(self, size, **kwargs):
        self._created = True
        self.data = bytearray(size)
        # Model Azure Files' New semantics, which may inherit parent ACLs.
        self.permission_key = "inherited-key" if kwargs.get("permission_key") else None

    def set_http_headers(self, content_settings, permission_key):
        self.permission_key = permission_key

    def resize_file(self, size):
        self.data = self.data[:size] + bytearray(max(0, size - len(self.data)))

    def upload_range(self, data, offset, length, validate_content):
        assert validate_content == "md5"
        assert length == len(data)
        self.data[offset:offset + length] = data

    def set_file_metadata(self, metadata):
        self.metadata = dict(metadata)

    def rename_file(self, new_name, **kwargs):
        existing = self.share.get_file_client(new_name)
        if existing.created and not kwargs["overwrite"]:
            raise RuntimeError("destination exists")
        assert kwargs["file_permission"] == "preserve"
        assert self.permission_key == "destination-key"
        target = self.share.get_file_client(new_name)
        target._created = True
        target.data = self.data
        target.permission_key = self.permission_key
        target.metadata = kwargs["metadata"]
        del self.share.files[self.path]
        return target

    def delete_file(self):
        del self.share.files[self.path]


class FakeEntry:
    def __init__(self, name, is_directory=False):
        self.name = name
        self.is_directory = is_directory


def mark_tracked(file):
    file.metadata.update({
        "andeslogcontenthash": hashlib.sha256(bytes(file.data)).hexdigest(),
        "andeslogaclhash": hashlib.sha256((getattr(file, "permission_key", None) or "source-key").encode()).hexdigest(),
    })


class FakeDirectory:
    def __init__(self, share, path):
        self.share = share
        self.path = path

    def list_directories_and_files(self):
        prefix = f"{self.path}/" if self.path else ""
        entries = {}
        for path in self.share.files:
            if not path.startswith(prefix):
                continue
            remainder = path[len(prefix):]
            if not remainder:
                continue
            head, separator, _tail = remainder.partition("/")
            if separator:
                entries[head] = True
            else:
                entries.setdefault(head, False)
        for path in self.share.directories:
            if not path.startswith(prefix) or path == self.path:
                continue
            remainder = path[len(prefix):]
            if remainder:
                entries[remainder.split("/", 1)[0]] = True
        return [FakeEntry(name, is_directory) for name, is_directory in sorted(entries.items())]

    def get_directory_client(self, path):
        return self.share.get_directory_client(f"{self.path}/{path}".strip("/"))

    def get_file_client(self, path):
        return self.share.get_file_client(f"{self.path}/{path}".strip("/"))

    def exists(self):
        return self.path in self.share.directories

    def get_directory_properties(self):
        if not self.exists():
            raise NotFound()
        return SimpleNamespace(permission_key=self.share.directory_permissions.get(self.path, "source-key"))

    def set_http_headers(self, permission_key):
        self.share.directory_permissions[self.path] = permission_key

    def create_directory(self, file_permission_key):
        self.share.directories.add(self.path)
        self.share.directory_permissions[self.path] = file_permission_key


class FakeShare(FakeDirectory):
    def __init__(self, files=None, directories=None):
        self.files = files or {}
        self.directories = set(directories or {""})
        self.directory_permissions = {}
        super().__init__(self, "")

    def get_directory_client(self, path):
        return FakeDirectory(self, path.strip("/"))

    def get_file_client(self, path):
        path = path.strip("/")
        file = self.files.setdefault(path, FakeFile())
        file.share = self
        file.path = path
        return file

    def get_permission_for_share(self, key):
        assert key == "source-key"
        return "O:SYG:SYD:(A;;FA;;;SY)"

    def create_permission_for_share(self, descriptor):
        assert descriptor == "O:SYG:SYD:(A;;FA;;;SY)"
        return "destination-key"


def test_sdk_factory_explicitly_sets_backup_intent_and_selected_identity(monkeypatch):
    captured = {}

    class Identity:
        def __init__(self, **kwargs):
            captured["identity"] = kwargs

    class ShareClient:
        def __init__(self, **kwargs):
            captured["share"] = kwargs

    azure = ModuleType("azure")
    azure.__path__ = []
    identity_module = ModuleType("azure.identity")
    identity_module.ManagedIdentityCredential = Identity
    storage_module = ModuleType("azure.storage")
    storage_module.__path__ = []
    fileshare_module = ModuleType("azure.storage.fileshare")
    fileshare_module.ShareClient = ShareClient
    azure.identity = identity_module
    azure.storage = storage_module
    storage_module.fileshare = fileshare_module
    monkeypatch.setitem(sys.modules, "azure", azure)
    monkeypatch.setitem(sys.modules, "azure.identity", identity_module)
    monkeypatch.setitem(sys.modules, "azure.storage", storage_module)
    monkeypatch.setitem(sys.modules, "azure.storage.fileshare", fileshare_module)

    client, _credential = _azure_share_client("andeslogsource", "andeslog", CLIENT_ID)

    assert isinstance(client, ShareClient)
    assert captured["identity"] == {"client_id": CLIENT_ID}
    assert captured["share"]["token_intent"] == "backup"
    assert captured["share"]["account_url"] == "https://andeslogsource.file.core.windows.net"


def test_sync_copies_nested_files_incrementally_and_never_deletes_destination_only_data(tmp_path):
    primary = FakeShare(
        files={
            "root.txt": FakeFile(b"root data"),
            "docs/handbook.pdf": FakeFile(b"pdf data", '"pdf-etag"'),
        },
        directories={"", "docs", "empty-folder"},
    )
    secondary = FakeShare(
        files={"old-only.txt": FakeFile()},
        directories={""},
    )
    secondary.files["old-only.txt"].create_file(size=7)
    secondary.files["old-only.txt"].data[:] = b"keep me"
    credentials = []

    def factory(account, share, client_id):
        assert share == "andeslog"
        assert client_id == CLIENT_ID
        credentials.append(FakeCredential())
        return (primary if account == "andeslogsource" else secondary), credentials[-1]

    result = sync_share(
        "andeslogsource", "andeslogdr", "andeslog", CLIENT_ID,
        client_factory=factory,
    )

    assert secondary.files["root.txt"].data == b"root data"
    assert secondary.files["docs/handbook.pdf"].data == b"pdf data"
    assert secondary.files["old-only.txt"].data == b"keep me"
    assert "empty-folder" in secondary.directories
    assert secondary.directory_permissions == {"": "destination-key", "docs": "destination-key", "empty-folder": "destination-key"}
    assert json_payload(result.stdout) == {
        "bytes_copied": 17,
        "copied": 2,
        "directories": 2,
        "skipped": 0,
    }
    assert all(credential.closed for credential in credentials)
    assert datetime.fromisoformat(result.started_utc.replace("Z", "+00:00")).utcoffset().total_seconds() == 0
    assert isinstance(result.duration_ms, int) and result.duration_ms >= 0

    second_result = sync_share(
        "andeslogsource", "andeslogdr", "andeslog", CLIENT_ID,
        client_factory=factory,
    )
    assert json_payload(second_result.stdout)["skipped"] == 2
    assert primary.files["root.txt"].download_count == 1


def json_payload(value):
    import json
    return json.loads(value)


def test_existing_directory_acl_is_updated_before_processing_children():
    source = FakeShare(directories={"", "docs"})
    destination = FakeShare(directories={"", "docs"})
    destination.directory_permissions["docs"] = "previous-key"
    _sync_directory_security(source, destination, "docs")
    assert destination.directory_permissions["docs"] == "destination-key"


def test_directory_missing_acl_fails_before_creating_destination():
    source = FakeShare(directories={"", "docs"})
    source.directory_permissions["docs"] = None
    destination = FakeShare()
    with pytest.raises(RuntimeError, match="directory did not return"):
        _sync_directory_security(source, destination, "docs")
    assert "docs" not in destination.directories


def test_directory_acl_change_during_sync_is_reported():
    source = FakeShare(directories={"", "docs"})
    destination = FakeShare(directories={"", "docs"})
    original_get = source.get_directory_client
    calls = []

    def changing_directory(path):
        client = original_get(path)
        original_properties = client.get_directory_properties

        def changing_properties():
            calls.append(1)
            if len(calls) == 2:
                source.directory_permissions[path] = "changed-key"
            return original_properties()

        client.get_directory_properties = changing_properties
        return client

    source.get_directory_client = changing_directory
    with pytest.raises(RuntimeError, match="permissions changed"):
        _sync_directory_security(source, destination, "docs")


def test_destination_permission_failure_does_not_create_directory():
    source = FakeShare(directories={"", "docs"})
    destination = FakeShare()
    destination.create_permission_for_share = lambda descriptor: None
    with pytest.raises(RuntimeError, match="destination did not return"):
        _sync_directory_security(source, destination, "docs")
    assert "docs" not in destination.directories


def test_primary_credential_is_closed_if_destination_client_creation_fails():
    credential = FakeCredential()

    def factory(account, _share, _identity):
        if account == "andeslogsource":
            return FakeShare(), credential
        raise RuntimeError("destination unavailable")

    with pytest.raises(RuntimeError, match="destination unavailable"):
        sync_share("andeslogsource", "andeslogdr", "andeslog", CLIENT_ID, client_factory=factory)
    assert credential.closed


def test_permission_descriptors_are_reused_within_one_sync():
    source = FakeShare(files={"docs/file.txt": FakeFile(b"data")}, directories={"", "docs"})
    destination = FakeShare()
    calls = {"get": 0, "create": 0}
    get_permission = source.get_permission_for_share
    create_permission = destination.create_permission_for_share

    def get(key):
        calls["get"] += 1
        return get_permission(key)

    def create(descriptor):
        calls["create"] += 1
        return create_permission(descriptor)

    source.get_permission_for_share = get
    destination.create_permission_for_share = create
    sync_share("andeslogsource", "andeslogdr", "andeslog", CLIENT_ID,
               client_factory=lambda account, *_: (source if account == "andeslogsource" else destination,
                                                   FakeCredential()))
    assert calls == {"get": 1, "create": 1}
    assert destination.files["docs/file.txt"].data == b"data"


def test_installed_azure_sdk_serializes_directory_permission_key(monkeypatch):
    fileshare = pytest.importorskip("azure.storage.fileshare")
    client = fileshare.ShareDirectoryClient(
        account_url="https://andeslogdr.file.core.windows.net",
        share_name="andeslog", directory_path="docs", credential="example-key",
    )
    calls = {}
    monkeypatch.setattr(client._client.directory, "create", lambda **kwargs: calls.setdefault("create", kwargs))
    monkeypatch.setattr(client._client.directory, "set_properties", lambda **kwargs: calls.setdefault("set", kwargs))
    client.create_directory(file_permission_key="acl-key")
    client.set_http_headers(permission_key="acl-key")
    assert calls["create"]["file_permission_key"] == "acl-key"
    assert calls["set"]["file_permission_key"] == "acl-key"


def test_installed_azure_sdk_accepts_raw_download_option(monkeypatch):
    fileshare = pytest.importorskip("azure.storage.fileshare")
    from azure.storage.fileshare import _file_client

    captured = {}

    class Downloader:
        def __init__(self, **kwargs):
            captured.update(kwargs)

    monkeypatch.setattr(_file_client, "StorageStreamDownloader", Downloader)
    client = fileshare.ShareFileClient(
        account_url="https://andeslogdr.file.core.windows.net",
        share_name="andeslog", file_path="data.gz", credential="example-key",
    )
    assert isinstance(client.download_file(decompress=False), Downloader)
    assert captured["decompress"] is False


def test_sdk_keeps_compressed_bytes_and_sends_range_md5_over_loopback():
    fileshare = pytest.importorskip("azure.storage.fileshare")
    compressed = gzip.compress(b"sample compressed payload")
    observed = {}

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_args):
            pass

        def do_GET(self):
            self.send_response(206)
            self.send_header("Content-Length", str(len(compressed)))
            self.send_header("Content-Range", f"bytes 0-{len(compressed) - 1}/{len(compressed)}")
            self.send_header("Content-Encoding", "gzip")
            self.send_header("ETag", '"fixture-etag"')
            self.send_header("Last-Modified", "Tue, 10 Nov 2026 12:00:00 GMT")
            self.end_headers()
            self.wfile.write(compressed)

        def do_PUT(self):
            observed["md5"] = self.headers.get("Content-MD5")
            observed["body"] = self.rfile.read(int(self.headers["Content-Length"]))
            self.send_response(201)
            self.send_header("Content-Length", "0")
            self.send_header("ETag", '"fixture-etag"')
            self.send_header("Last-Modified", "Tue, 10 Nov 2026 12:00:00 GMT")
            self.end_headers()

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    credential = base64.b64encode(b"local-test-key-only").decode("ascii")
    client = fileshare.ShareFileClient(
        account_url=f"http://127.0.0.1:{server.server_port}/testaccount",
        share_name="andeslog", file_path="data.gz", credential=credential,
    )
    try:
        assert b"".join(client.download_file(decompress=False).chunks()) == compressed
        client.upload_range(data=b"payload", offset=0, length=7, validate_content="md5")
        assert observed["body"] == b"payload"
        assert observed["md5"] == base64.b64encode(hashlib.md5(b"payload").digest()).decode("ascii")
    finally:
        client.close()
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)


def test_sync_updates_existing_file_when_source_etag_changes():
    primary = FakeShare(files={"data.csv": FakeFile(b"updated", '"etag-new"')})
    destination_file = FakeFile()
    destination_file.create_file(size=3)
    destination_file.data[:] = b"old"
    destination_file.metadata = {"andeslogsourcefingerprint": "old-fingerprint"}
    mark_tracked(destination_file)
    secondary = FakeShare(files={"data.csv": destination_file})

    sync_share(
        "andeslogsource", "andeslogdr", "andeslog", CLIENT_ID,
        client_factory=lambda account, _share, _identity: (
            primary if account == "andeslogsource" else secondary, FakeCredential()
        ),
    )

    assert secondary.files["data.csv"].data == b"updated"
    assert secondary.files["data.csv"].metadata["andeslogsourcefingerprint"]


@pytest.mark.parametrize("alteration", ["content", "permissions", "missing_etag"])
def test_sync_stops_on_destination_drift(alteration):
    primary = FakeShare(files={"data.csv": FakeFile(b"valid")})
    secondary = FakeShare()
    factory = lambda account, *_: (primary if account == "andeslogsource" else secondary, FakeCredential())
    sync_share("andeslogsource", "andeslogdr", "andeslog", CLIENT_ID, client_factory=factory)
    target = secondary.files["data.csv"]
    if alteration == "content":
        target.data[:] = b"wrong"
    elif alteration == "permissions":
        target.permission_key = "tampered-key"
    else:
        target.etag = None
    with pytest.raises(RuntimeError, match="reconciliation required"):
        sync_share("andeslogsource", "andeslogdr", "andeslog", CLIENT_ID, client_factory=factory)
    assert bytes(target.data) == (b"wrong" if alteration == "content" else b"valid")


def test_destination_modified_during_hash_is_preserved():
    primary = FakeShare(files={"data.csv": FakeFile(b"valid")})
    secondary = FakeShare()
    factory = lambda account, *_: (primary if account == "andeslogsource" else secondary, FakeCredential())
    sync_share("andeslogsource", "andeslogdr", "andeslog", CLIENT_ID, client_factory=factory)
    target = secondary.files["data.csv"]

    class ChangingDownload(FakeDownloader):
        def chunks(self):
            yield bytes(self.data)
            target.data[:] = b"wrong"
            target.etag = '"changed"'

    target.download_file = lambda **_: ChangingDownload(target.data)
    with pytest.raises(RuntimeError, match="destination changed"):
        sync_share("andeslogsource", "andeslogdr", "andeslog", CLIENT_ID, client_factory=factory)
    assert bytes(target.data) == b"wrong"


def test_untracked_existing_destination_is_not_overwritten():
    primary = FakeShare(files={"data.csv": FakeFile(b"source")})
    target = FakeFile()
    target.create_file(size=6)
    target.data[:] = b"manual"
    secondary = FakeShare(files={"data.csv": target})
    with pytest.raises(RuntimeError, match="content hash is missing"):
        sync_share("andeslogsource", "andeslogdr", "andeslog", CLIENT_ID,
                   client_factory=lambda account, *_: (primary if account == "andeslogsource" else secondary, FakeCredential()))
    assert bytes(target.data) == b"manual"


@pytest.mark.parametrize("exists_before", [True, False])
def test_destination_modified_during_source_upload_is_preserved(exists_before):
    source = FakeFile(b"new data")
    target = FakeFile()
    if exists_before:
        target.create_file(size=3)
        target.data[:] = b"old"
        mark_tracked(target)
    secondary = FakeShare(files={"file.txt": target})
    original_get = secondary.get_file_client

    def get_file(path):
        file = original_get(path)
        if path.startswith(".andeslog-dr-"):
            original_upload = file.upload_range

            def modifying_upload(*args, **kwargs):
                original_upload(*args, **kwargs)
                target._created = True
                target.data = bytearray(b"user data")
                target.etag = '"user-edit"'

            file.upload_range = modifying_upload
        return file

    secondary.get_file_client = get_file
    with pytest.raises(RuntimeError, match="destination (changed|appeared)"):
        _sync_file(source, target, {"copied": 0, "skipped": 0, "bytes_copied": 0},
                   FakeShare(), secondary, "file.txt")
    assert bytes(target.data) == b"user data"
    assert not any(name.startswith(".andeslog-dr-") for name in secondary.files)


def test_source_change_during_download_preserves_existing_destination(tmp_path):
    source = FakeFile(b"new", '"before"')
    destination = FakeFile()
    destination.create_file(size=3)
    destination.data[:] = b"old"
    destination.metadata = {"andeslogsourcefingerprint": "old-marker"}
    mark_tracked(destination)
    original_metadata = dict(destination.metadata)

    class ChangingDownloader(FakeDownloader):
        def chunks(self):
            yield bytes(self.data)
            source.etag = '"after"'

    source.download_file = lambda **_: ChangingDownloader(source.source_data)
    counters = {"copied": 0, "skipped": 0, "bytes_copied": 0}
    with pytest.raises(RuntimeError, match="source changed"):
        _sync_file(source, destination, counters, FakeShare(), FakeShare(), "file.txt")
    assert bytes(destination.data) == b"old"
    assert destination.metadata == original_metadata
    assert counters["copied"] == 0


def test_large_stream_is_uploaded_in_bounded_ranges_without_losing_content():
    content = b"a" * (4 * 1024 * 1024) + b"tail"
    primary = FakeShare(files={"large.bin": FakeFile(content)})
    secondary = FakeShare()
    uploads = []
    original_get = secondary.get_file_client

    def get_file(path):
        file = original_get(path)
        if path.startswith(".andeslog-dr-"):
            original_upload = file.upload_range

            def recording_upload(data, offset, length, validate_content):
                uploads.append((offset, length))
                original_upload(data, offset, length, validate_content)

            file.upload_range = recording_upload
        return file

    secondary.get_file_client = get_file
    result = sync_share("andeslogsource", "andeslogdr", "andeslog", CLIENT_ID,
                        client_factory=lambda account, *_: (primary if account == "andeslogsource" else secondary, FakeCredential()))
    assert uploads == [(0, 4 * 1024 * 1024), (4 * 1024 * 1024, 4)]
    assert bytes(secondary.files["large.bin"].data) == content
    assert secondary.files["large.bin"].metadata["andeslogcontenthash"] == hashlib.sha256(content).hexdigest()
    assert json_payload(result.stdout)["bytes_copied"] == len(content)


def test_interrupted_source_stream_keeps_old_copy_and_removes_partial_destination():
    source = FakeFile(b"new content")

    class InterruptedDownloader(FakeDownloader):
        def chunks(self):
            yield bytes(self.data[:3])
            raise RuntimeError("source network interruption")

    source.download_file = lambda **_: InterruptedDownloader(source.source_data)
    primary = FakeShare(files={"file.txt": source})
    destination = FakeFile()
    destination.create_file(size=3)
    destination.data[:] = b"old"
    mark_tracked(destination)
    secondary = FakeShare(files={"file.txt": destination})
    with pytest.raises(RuntimeError, match="source network interruption"):
        sync_share("andeslogsource", "andeslogdr", "andeslog", CLIENT_ID,
                   client_factory=lambda account, *_: (primary if account == "andeslogsource" else secondary, FakeCredential()))
    assert bytes(destination.data) == b"old"
    assert set(secondary.files) == {"file.txt"}


def test_source_change_during_upload_keeps_previous_copy(tmp_path):
    source = FakeFile(b"new", '"before"')

    class ChangingTemporaryFile(FakeFile):
        def upload_range(self, *args, **kwargs):
            super().upload_range(*args, **kwargs)
            source.etag = '"after"'

    destination = FakeFile()
    destination.create_file(size=3)
    destination.data[:] = b"old"
    destination.metadata = {"andeslogsourcefingerprint": "old-marker"}
    mark_tracked(destination)
    original_metadata = dict(destination.metadata)
    secondary = FakeShare(files={"file.txt": destination})
    original_get = secondary.get_file_client

    def get_file(path):
        if path.startswith(".andeslog-dr-"):
            secondary.files[path] = ChangingTemporaryFile()
        return original_get(path)

    secondary.get_file_client = get_file
    counters = {"copied": 0, "skipped": 0, "bytes_copied": 0}
    with pytest.raises(RuntimeError, match="source changed"):
        _sync_file(source, destination, counters, FakeShare(), secondary, "file.txt")
    assert bytes(destination.data) == b"old"
    assert destination.metadata == original_metadata
    assert set(secondary.files) == {"file.txt"}
    assert counters["copied"] == 0


def test_failed_upload_keeps_previous_copy_and_removes_temporary_file(tmp_path):
    source = FakeFile(b"new", '"before"')
    destination = FakeFile()
    destination.create_file(size=3)
    destination.data[:] = b"old"
    destination.metadata = {"andeslogsourcefingerprint": "old-marker"}
    mark_tracked(destination)
    original_metadata = dict(destination.metadata)
    secondary = FakeShare(files={"file.txt": destination})
    original_get = secondary.get_file_client

    class FailedUpload(FakeFile):
        def upload_range(self, **kwargs):
            raise RuntimeError("simulated network interruption")

    def get_file(path):
        if path.startswith(".andeslog-dr-"):
            secondary.files[path] = FailedUpload()
        return original_get(path)

    secondary.get_file_client = get_file
    with pytest.raises(RuntimeError, match="simulated network interruption"):
        _sync_file(source, destination, {"copied": 0, "skipped": 0, "bytes_copied": 0},
                   FakeShare(), secondary, "file.txt")
    assert bytes(destination.data) == b"old"
    assert destination.metadata == original_metadata
    assert set(secondary.files) == {"file.txt"}


def test_cannot_copy_without_source_permission(tmp_path):
    source = FakeFile(b"new")
    source.get_file_properties = lambda: SimpleNamespace(size=3, etag='"tag"', permission_key=None)
    secondary = FakeShare(files={"file.txt": FakeFile()})
    with pytest.raises(RuntimeError, match="security descriptor"):
        _sync_file(source, secondary.get_file_client("file.txt"),
                   {"copied": 0, "skipped": 0, "bytes_copied": 0}, FakeShare(), secondary, "file.txt")
    assert set(secondary.files) == {"file.txt"}


def test_failed_rename_keeps_previous_copy(tmp_path):
    source = FakeFile(b"new")
    destination = FakeFile()
    destination.create_file(size=3)
    destination.data[:] = b"old"
    mark_tracked(destination)
    secondary = FakeShare(files={"file.txt": destination})
    original_get = secondary.get_file_client

    class BlockedRename(FakeFile):
        def rename_file(self, new_name, **kwargs):
            raise RuntimeError("destination is locked")

    def get_file(path):
        if path.startswith(".andeslog-dr-"):
            secondary.files[path] = BlockedRename()
        return original_get(path)

    secondary.get_file_client = get_file
    with pytest.raises(RuntimeError, match="destination is locked"):
        _sync_file(source, destination, {"copied": 0, "skipped": 0, "bytes_copied": 0},
                   FakeShare(), secondary, "file.txt")
    assert bytes(destination.data) == b"old"
    assert set(secondary.files) == {"file.txt"}


@pytest.mark.parametrize(
    "primary,secondary,share,identity",
    [
        ("Bad-Account", "andeslogdr", "andeslog", CLIENT_ID),
        ("andeslog", "Bad-Account", "andeslog", CLIENT_ID),
        ("andeslog", "andeslog", "andeslog", CLIENT_ID),
        ("andeslog", "andeslogdr", "a", CLIENT_ID),
        ("andeslog", "andeslogdr", "andeslog", "/subscriptions/not-a-client-id"),
    ],
)
def test_sync_rejects_invalid_input(primary, secondary, share, identity):
    with pytest.raises(ValueError):
        sync_share(primary, secondary, share, identity, client_factory=lambda *_: None)


def test_deadline_during_source_download_keeps_existing_destination_and_closes_credentials():
    clock = SimpleNamespace(value=0.0)
    source = FakeFile(b"new content")

    class SlowDownloader(FakeDownloader):
        def chunks(self):
            clock.value = 6.0
            yield bytes(self.data)

    source.download_file = lambda **_: SlowDownloader(source.source_data)
    destination = FakeFile()
    destination.create_file(size=3)
    destination.data[:] = b"old"
    mark_tracked(destination)
    primary = FakeShare(files={"file.txt": source})
    secondary = FakeShare(files={"file.txt": destination})
    credentials = []

    def factory(account, *_):
        credential = FakeCredential()
        credentials.append(credential)
        return (primary if account == "andeslogsource" else secondary, credential)

    with pytest.raises(TimeoutError, match="scan budget"):
        sync_share("andeslogsource", "andeslogdr", "andeslog", CLIENT_ID,
                   client_factory=factory, timeout_seconds=5, clock=lambda: clock.value)
    assert bytes(destination.data) == b"old"
    assert all(credential.closed for credential in credentials)
    assert not any(name.startswith(".andeslog-dr-") and file.created for name, file in secondary.files.items())


def test_deadline_during_upload_removes_partial_remote_copy():
    clock = SimpleNamespace(value=0.0)
    primary = FakeShare(files={"file.txt": FakeFile(b"new content")})
    destination = FakeFile()
    destination.create_file(size=3)
    destination.data[:] = b"old"
    mark_tracked(destination)
    secondary = FakeShare(files={"file.txt": destination})
    original_get_file = secondary.get_file_client

    def get_file(path):
        file = original_get_file(path)
        if path.startswith(".andeslog-dr-"):
            original_upload = file.upload_range

            def slow_upload(*args, **kwargs):
                original_upload(*args, **kwargs)
                clock.value = 6.0

            file.upload_range = slow_upload
        return file

    secondary.get_file_client = get_file
    with pytest.raises(TimeoutError, match="scan budget"):
        sync_share("andeslogsource", "andeslogdr", "andeslog", CLIENT_ID,
                   client_factory=lambda account, *_: (primary if account == "andeslogsource" else secondary, FakeCredential()),
                   timeout_seconds=5, clock=lambda: clock.value)
    assert bytes(destination.data) == b"old"
    assert not any(name.startswith(".andeslog-dr-") for name in secondary.files)


def test_deadline_during_cleanup_does_not_report_success():
    clock = SimpleNamespace(value=0.0)
    credentials = []

    class SlowCredential(FakeCredential):
        def close(self):
            super().close()
            clock.value = 6.0

    def factory(_account, *_):
        credential = SlowCredential()
        credentials.append(credential)
        return FakeShare(), credential

    with pytest.raises(TimeoutError, match="scan budget"):
        sync_share("andeslogsource", "andeslogdr", "andeslog", CLIENT_ID,
                   client_factory=factory, timeout_seconds=5, clock=lambda: clock.value)
    assert len(credentials) == 2 and all(credential.closed for credential in credentials)


@pytest.mark.parametrize("timeout", [0, -1, 3601, True, float("nan"), float("inf")])
def test_scan_budget_rejects_invalid_values(timeout):
    with pytest.raises(ValueError, match="scan budget"):
        sync_share("andeslogsource", "andeslogdr", "andeslog", CLIENT_ID,
                   client_factory=lambda *_: None, timeout_seconds=timeout)
