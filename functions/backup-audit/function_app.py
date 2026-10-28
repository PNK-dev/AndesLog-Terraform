"""Audit a newly uploaded PostgreSQL backup in Azure Blob Storage."""

import hashlib
import json
import logging
import os
from datetime import datetime, timezone
from urllib.parse import unquote, urlparse

import azure.functions as func
from azure.identity import DefaultAzureCredential
from azure.storage.blob import BlobServiceClient, ContentSettings


app = func.FunctionApp()


@app.function_name(name="BackupAudit")
@app.event_grid_trigger(arg_name="event")
def backup_audit(event: func.EventGridEvent) -> None:
    if event.event_type != "Microsoft.Storage.BlobCreated":
        return

    account = os.environ["BACKUP_ACCOUNT_NAME"]
    container = os.environ["BACKUP_CONTAINER"]
    audit_container = os.environ["AUDIT_CONTAINER"]
    max_bytes = int(os.environ["MAX_BACKUP_BYTES"])
    url = event.get_json()["url"]
    parsed = urlparse(url)
    prefix = f"/{container}/backups/"
    if parsed.scheme != "https" or parsed.hostname != f"{account}.blob.core.windows.net":
        raise ValueError("The event does not refer to the configured storage account")
    if not unquote(parsed.path).startswith(prefix):
        raise ValueError("The event does not refer to a backup blob")

    blob_name = unquote(parsed.path)[len(f"/{container}/") :]
    credential = DefaultAzureCredential(
        managed_identity_client_id=os.environ["AZURE_CLIENT_ID"],
        exclude_interactive_browser_credential=True,
    )
    service = BlobServiceClient(
        account_url=f"https://{account}.blob.core.windows.net", credential=credential
    )
    blob = service.get_blob_client(container=container, blob=blob_name)
    properties = blob.get_blob_properties()
    reported_size = properties.size
    status = "ok"
    digest = None
    bytes_read = 0

    if reported_size == 0:
        status = "empty"
    elif reported_size > max_bytes:
        status = "oversize"
    else:
        hasher = hashlib.sha256()
        for chunk in blob.download_blob().chunks():
            hasher.update(chunk)
            bytes_read += len(chunk)
        if bytes_read != reported_size:
            status = "size_mismatch"
        else:
            digest = hasher.hexdigest()

    result = {
        "blob_name": blob_name,
        "blob_etag": properties.etag,
        "event_id": event.id,
        "checked_at_utc": datetime.now(timezone.utc).isoformat(),
        "size_bytes": reported_size,
        "bytes_read": bytes_read,
        "max_bytes": max_bytes,
        "sha256": digest,
        "status": status,
    }
    record_name = hashlib.sha256(blob_name.encode("utf-8")).hexdigest() + ".json"
    service.get_blob_client(container=audit_container, blob=record_name).upload_blob(
        json.dumps(result, sort_keys=True).encode("utf-8"),
        overwrite=True,
        content_settings=ContentSettings(content_type="application/json"),
    )
    logging.info("Backup audit %s: %s (%s bytes)", status, blob_name, reported_size)
