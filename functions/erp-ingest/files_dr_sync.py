"""Keyless, incremental Azure Files mirror using OAuth over FileREST."""

import hashlib
import json
import logging
import os
import re
import time
from datetime import datetime, timezone
from typing import Callable, Optional


_STORAGE_ACCOUNT = re.compile(r"^[a-z0-9]{3,24}$")
_SHARE_NAME = re.compile(r"^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$")
_CLIENT_ID = re.compile(r"^[0-9a-fA-F]{8}-(?:[0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$")
_FINGERPRINT_METADATA_KEY = "andeslogsourcefingerprint"
_CONTENT_HASH_METADATA_KEY = "andeslogcontenthash"
_ACL_HASH_METADATA_KEY = "andeslogaclhash"
_RANGE_BYTES = 4 * 1024 * 1024


def _validate_names(primary_account: str, secondary_account: str, share_name: str) -> None:
    if not _STORAGE_ACCOUNT.fullmatch(primary_account):
        raise ValueError("Invalid primary Azure Storage account name.")
    if not _STORAGE_ACCOUNT.fullmatch(secondary_account):
        raise ValueError("Invalid secondary Azure Storage account name.")
    if primary_account == secondary_account:
        raise ValueError("Primary and secondary Azure Storage accounts must be different.")
    if not _SHARE_NAME.fullmatch(share_name):
        raise ValueError("Invalid Azure Files share name.")


def _azure_share_client(account_name: str, share_name: str, client_id: str):
    from azure.identity import ManagedIdentityCredential
    from azure.storage.fileshare import ShareClient

    credential = ManagedIdentityCredential(client_id=client_id)
    client = ShareClient(
        account_url=f"https://{account_name}.file.core.windows.net",
        share_name=share_name,
        credential=credential,
        token_intent="backup",
    )
    return client, credential


def _source_fingerprint(properties) -> str:
    etag = str(getattr(properties, "etag", ""))
    size = int(getattr(properties, "size", 0))
    permission_key = getattr(properties, "permission_key", None)
    if not etag:
        raise RuntimeError("Azure Files did not return an ETag for a source file.")
    if not permission_key:
        raise RuntimeError("Azure Files source did not return its security descriptor key.")
    # Versioning forces old content-only mirrors to be recopied with file ACLs.
    return hashlib.sha256(f"v3:{etag}:{size}:{permission_key}".encode("utf-8")).hexdigest()


def _get_destination_properties(file_client):
    try:
        return file_client.get_file_properties()
    except Exception as error:
        if getattr(error, "status_code", None) == 404:
            return None
        raise


def _require_unchanged_source(source_file, fingerprint: str) -> None:
    if _source_fingerprint(source_file.get_file_properties()) != fingerprint:
        raise RuntimeError("Azure Files source changed during replication; retry required.")


def _permission_hash(permission_key) -> str:
    if not isinstance(permission_key, str) or not permission_key:
        raise RuntimeError("Azure Files destination has no permission key; reconciliation required.")
    return hashlib.sha256(permission_key.encode("utf-8")).hexdigest()


def _require_same_destination(destination_file, expected_etag) -> None:
    current = _get_destination_properties(destination_file)
    if expected_etag is None:
        if current is not None:
            raise RuntimeError("Azure Files destination appeared during replication; reconciliation required.")
    elif current is None or getattr(current, "etag", None) != expected_etag:
        raise RuntimeError("Azure Files destination changed during replication; reconciliation required.")


def _translate_permission(source_share, destination_share, source_key: str, permission_cache: dict) -> str:
    if source_key in permission_cache:
        return permission_cache[source_key]
    descriptor = source_share.get_permission_for_share(source_key)
    if not descriptor:
        raise RuntimeError("Azure Files source security descriptor is empty.")
    destination_key = destination_share.create_permission_for_share(descriptor)
    if not destination_key:
        raise RuntimeError("Azure Files destination did not return a security descriptor key.")
    permission_cache[source_key] = destination_key
    return destination_key


def _sync_file(source_file, destination_file, counters: dict,
               source_share, destination_share, destination_path: str, permission_cache=None,
               check_budget=lambda: None) -> None:
    check_budget()
    source_properties = source_file.get_file_properties()
    size = int(source_properties.size)
    fingerprint = _source_fingerprint(source_properties)
    destination_properties = _get_destination_properties(destination_file)
    permission_key = source_properties.permission_key
    destination_permission_key = _translate_permission(
        source_share, destination_share, permission_key, permission_cache if permission_cache is not None else {}
    )
    check_budget()

    if destination_properties is not None:
        metadata = {
            str(key).lower(): str(value)
            for key, value in (getattr(destination_properties, "metadata", None) or {}).items()
        }
        destination_etag = getattr(destination_properties, "etag", None)
        if not destination_etag:
            raise RuntimeError("Azure Files destination ETag is missing; reconciliation required.")
        if not re.fullmatch(r"[0-9a-f]{64}", metadata.get(_CONTENT_HASH_METADATA_KEY, "")):
            raise RuntimeError("Azure Files destination content hash is missing; reconciliation required.")
        if not re.fullmatch(r"[0-9a-f]{64}", metadata.get(_ACL_HASH_METADATA_KEY, "")):
            raise RuntimeError("Azure Files destination ACL hash is missing; reconciliation required.")
        if metadata[_ACL_HASH_METADATA_KEY] != _permission_hash(getattr(destination_properties, "permission_key", None)):
            raise RuntimeError("Azure Files destination ACL changed; reconciliation required.")
        destination_hash = hashlib.sha256()
        for chunk in destination_file.download_file(decompress=False).chunks():
            check_budget()
            destination_hash.update(chunk)
        check_budget()
        _require_same_destination(destination_file, destination_etag)
        if destination_hash.hexdigest() != metadata[_CONTENT_HASH_METADATA_KEY]:
            raise RuntimeError("Azure Files destination content changed; reconciliation required.")
        if (int(destination_properties.size) == size and metadata.get(_FINGERPRINT_METADATA_KEY) == fingerprint
                and getattr(destination_properties, "permission_key", None) == destination_permission_key):
            _require_unchanged_source(source_file, fingerprint)
            check_budget()
            counters["skipped"] += 1
            return
    else:
        destination_etag = None

    temporary_name = f".andeslog-dr-{os.urandom(16).hex()}.tmp"
    parent = destination_path.rpartition("/")[0]
    temporary_path = f"{parent}/{temporary_name}" if parent else temporary_name
    temporary_file = destination_share.get_file_client(temporary_path)
    temporary_created = False
    try:
        # Stream directly to an isolated temporary destination. The live copy is
        # not replaced until the full source and its ACL have been verified.
        _require_unchanged_source(source_file, fingerprint)
        check_budget()
        temporary_file.create_file(size=size, permission_key=destination_permission_key)
        temporary_created = True
        # File creation may apply inherited ACLs. Set the descriptor again
        # using update semantics and verify the key before publishing the copy.
        from azure.storage.fileshare import ContentSettings
        temporary_file.set_http_headers(ContentSettings(), permission_key=destination_permission_key)
        if getattr(temporary_file.get_file_properties(), "permission_key", None) != destination_permission_key:
            raise RuntimeError("Azure Files temporary file ACL could not be preserved.")
        check_budget()

        source_hash = hashlib.sha256()
        offset = 0
        for downloaded_chunk in source_file.download_file(decompress=False).chunks():
            check_budget()
            if offset + len(downloaded_chunk) > size:
                raise RuntimeError("Azure Files download exceeded the source size.")
            for index in range(0, len(downloaded_chunk), _RANGE_BYTES):
                check_budget()
                chunk = downloaded_chunk[index:index + _RANGE_BYTES]
                source_hash.update(chunk)
                temporary_file.upload_range(
                    data=chunk,
                    offset=offset,
                    length=len(chunk),
                    validate_content="md5",
                )
                offset += len(chunk)
                check_budget()
        check_budget()
        if offset != size:
            raise RuntimeError("Azure Files download length did not match the source size.")

        final_properties = temporary_file.get_file_properties()
        if int(final_properties.size) != size:
            raise RuntimeError("Azure Files destination size did not match the source size.")
        # Never replace the last complete destination if the source changed.
        _require_unchanged_source(source_file, fingerprint)
        _require_same_destination(destination_file, destination_etag)
        check_budget()
        rename_options = {
            "overwrite": destination_etag is not None,
            "file_permission": "preserve",
            "metadata": {_FINGERPRINT_METADATA_KEY: fingerprint, _CONTENT_HASH_METADATA_KEY: source_hash.hexdigest(),
                         _ACL_HASH_METADATA_KEY: _permission_hash(destination_permission_key)},
        }
        for source_name, option_name in (
            ("file_attributes", "file_attributes"),
            ("creation_time", "file_creation_time"),
            ("last_write_time", "file_last_write_time"),
        ):
            value = getattr(source_properties, source_name, None)
            if value is not None:
                rename_options[option_name] = value
        temporary_file.rename_file(destination_path, **rename_options)
        temporary_created = False
        check_budget()
        counters["copied"] += 1
        counters["bytes_copied"] += size
    finally:
        if temporary_created:
            try:
                temporary_file.delete_file()
            except Exception:
                logging.warning("Could not remove a temporary Azure Files recovery copy.")


def _sync_directory_security(source_share, destination_share, relative_path: str, permission_cache=None) -> None:
    source_dir = source_share.get_directory_client(relative_path)
    destination_dir = destination_share.get_directory_client(relative_path)
    properties = source_dir.get_directory_properties()
    source_key = getattr(properties, "permission_key", None)
    if not source_key:
        raise RuntimeError("Azure Files source directory did not return its security descriptor key.")
    destination_key = _translate_permission(
        source_share, destination_share, source_key, permission_cache if permission_cache is not None else {}
    )

    # Create new directories with their ACL already set; do not expose an
    # inherited-permission window before copying child entries.
    if relative_path and not destination_dir.exists():
        destination_dir.create_directory(file_permission_key=destination_key)
    if getattr(destination_dir.get_directory_properties(), "permission_key", None) != destination_key:
        destination_dir.set_http_headers(permission_key=destination_key)
    if getattr(destination_dir.get_directory_properties(), "permission_key", None) != destination_key:
        raise RuntimeError("Azure Files destination directory ACL could not be preserved.")

    if getattr(source_dir.get_directory_properties(), "permission_key", None) != source_key:
        raise RuntimeError("Azure Files source directory permissions changed during replication; retry required.")


def _sync_directory(source_share, destination_share, relative_path: str, counters: dict,
                    permission_cache: dict, check_budget=lambda: None, progress=None):
    check_budget()
    source_directory = source_share if not relative_path else source_share.get_directory_client(relative_path)
    _sync_directory_security(source_share, destination_share, relative_path, permission_cache)
    check_budget()
    if progress is not None:
        progress.directory_done(relative_path)
        check_budget()

    for entry in source_directory.list_directories_and_files():
        check_budget()
        child_path = f"{relative_path}/{entry.name}" if relative_path else entry.name
        if getattr(entry, "is_directory", False):
            if progress is not None and not progress.should_enter_directory(child_path):
                continue
            counters["directories"] += 1
            _sync_directory(source_share, destination_share, child_path, counters, permission_cache, check_budget, progress)
            continue

        if progress is not None and not progress.should_copy_file(child_path):
            continue
        _sync_file(
            source_share.get_file_client(child_path),
            destination_share.get_file_client(child_path),
            counters,
            source_share,
            destination_share,
            child_path,
            permission_cache,
            check_budget,
        )
        if progress is not None:
            check_budget()
            progress.file_done(child_path)
            check_budget()
    check_budget()


def sync_share(
    primary_account: str,
    secondary_account: str,
    share_name: str,
    identity_client_id: str,
    client_factory: Optional[Callable] = None,
    timeout_seconds: int = 600,
    clock: Optional[Callable] = None,
    checkpoint_store=None,
):
    """Copy primary files to secondary without deleting destination-only content.

    Azure Files OAuth over FileREST needs the explicit backup token intent. The
    Azure SDK adds that request intent and uses the selected user-assigned
    managed identity. Client-side streaming prevents server-side copy from
    trying to access either private endpoint on behalf of the Storage service.
    """
    if isinstance(timeout_seconds, bool) or not isinstance(timeout_seconds, (int, float)) or not 0 < timeout_seconds <= 3600:
        raise ValueError("The cooperative scan budget must be between 0 and 3600 seconds.")
    _validate_names(primary_account, secondary_account, share_name)
    if not _CLIENT_ID.fullmatch(identity_client_id or ""):
        raise ValueError("A managed identity Client ID in GUID format is required.")

    started_utc = datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")
    clock = clock or time.monotonic
    started = clock()
    deadline = started + timeout_seconds

    def check_budget():
        if clock() >= deadline:
            raise TimeoutError("Azure Files replication exceeded its cooperative scan budget.")
        if checkpoint_store is not None:
            checkpoint_store.ensure_lease()

    progress = None
    if checkpoint_store is not None:
        from files_dr_checkpoint import ScanProgress

        check_budget()
        progress = ScanProgress(checkpoint_store, started_utc)
        check_budget()

    factory = client_factory or _azure_share_client
    counters = {"copied": 0, "skipped": 0, "directories": 0, "bytes_copied": 0}
    credentials = []

    # Azure SDK INFO logs include full FileREST URLs, which contain customer
    # file and directory names. Keep those paths out of Application Insights.
    logging.getLogger("azure").setLevel(logging.WARNING)
    logging.getLogger("azure.core.pipeline.policies.http_logging_policy").setLevel(logging.WARNING)

    try:
        primary, primary_credential = factory(primary_account, share_name, identity_client_id)
        credentials.append(primary_credential)
        check_budget()
        secondary, secondary_credential = factory(secondary_account, share_name, identity_client_id)
        credentials.append(secondary_credential)
        check_budget()
        _sync_directory(primary, secondary, "", counters, {}, check_budget, progress)
    finally:
        for credential in credentials:
            close = getattr(credential, "close", None)
            if callable(close):
                close()

    completed = clock()
    if completed >= deadline:
        raise TimeoutError("Azure Files replication exceeded its cooperative scan budget.")

    scan_started_utc = progress.finish() if progress is not None else started_utc
    completed = clock()
    if completed >= deadline:
        raise TimeoutError("Azure Files replication exceeded its cooperative scan budget.")

    import subprocess

    result = subprocess.CompletedProcess(
        args=["azure-files-sdk-sync"],
        returncode=0,
        stdout=json.dumps(counters, sort_keys=True),
        stderr="",
    )
    result.started_utc = scan_started_utc
    result.duration_ms = round((completed - started) * 1000)
    return result
