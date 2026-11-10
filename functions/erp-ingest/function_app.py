"""Authenticated HTTPS ingress from the AndesLog ERP into private Azure Blob."""

import hashlib
import hmac
import json
import logging
import os
import re
from contextlib import contextmanager

import azure.functions as func
from azure.identity import DefaultAzureCredential, ManagedIdentityCredential
from azure.storage.blob import BlobServiceClient, ContentSettings
from azure.core.exceptions import ResourceExistsError

from handler import InvalidEvent, verify_and_parse
from files_dr_sync import sync_share
from files_dr_checkpoint import BlobCheckpoint, checkpoint_blob_name

app = func.FunctionApp()


@contextmanager
def files_dr_checkpoint(primary_account, secondary_account, share_name, identity_client_id):
    """Open the private checkpoint using the sync identity, never account keys."""
    account = os.environ.get("FILES_DR_CHECKPOINT_ACCOUNT", "")
    container = os.environ.get("FILES_DR_CHECKPOINT_CONTAINER", "")
    if not re.fullmatch(r"[a-z0-9]{3,24}", account):
        raise ValueError("Invalid checkpoint account")
    if (not re.fullmatch(r"[a-z0-9](?:[a-z0-9-]{1,61}[a-z0-9])", container)
            or "--" in container):
        raise ValueError("Invalid checkpoint container")
    credential = ManagedIdentityCredential(client_id=identity_client_id)
    service = None
    try:
        service = BlobServiceClient(account_url=f"https://{account}.blob.core.windows.net", credential=credential)
        blob = service.get_blob_client(container=container, blob=checkpoint_blob_name(primary_account, secondary_account, share_name))
        with BlobCheckpoint(blob) as checkpoint:
            yield checkpoint
    finally:
        if service is not None:
            service.close()
        credential.close()


@app.function_name(name="ErpEventIngest")
@app.route(route="erp/events", methods=["POST"], auth_level=func.AuthLevel.ANONYMOUS)
def erp_event_ingest(req: func.HttpRequest) -> func.HttpResponse:
    body = req.get_body()
    try:
        event, digest = verify_and_parse(
            body,
            os.environ.get("ERP_INGEST_HMAC_SECRET", ""),
            req.headers.get("X-AndesLog-Signature", ""),
        )
    except InvalidEvent as exc:
        logging.info("Rejected ERP event: %s", str(exc))
        return func.HttpResponse("Invalid event", status_code=401 if "signature" in str(exc).lower() else 400)

    account = os.environ["ERP_EVENTS_ACCOUNT_NAME"]
    container = os.environ["ERP_EVENTS_CONTAINER"]
    credential = DefaultAzureCredential(exclude_interactive_browser_credential=True)
    service = BlobServiceClient(account_url=f"https://{account}.blob.core.windows.net", credential=credential)
    blob = service.get_blob_client(container=container, blob=f"{event['id']}.json")
    metadata = {"event_id": event["id"], "sha256": digest, "event_type": event["event_type"][:100]}
    try:
        blob.upload_blob(
            body,
            overwrite=False,
            metadata=metadata,
            content_settings=ContentSettings(content_type="application/json"),
        )
    except ResourceExistsError:
        existing = blob.download_blob().readall()
        existing_digest = hashlib.sha256(existing).hexdigest()
        if not hmac.compare_digest(existing_digest, digest):
            return func.HttpResponse("Event ID conflict", status_code=409)
        return func.HttpResponse(json.dumps({"status": "duplicate", "id": event["id"]}), status_code=200,
                                 mimetype="application/json")
    except Exception:
        logging.exception("Azure Blob write failed for ERP event %s", event["id"])
        return func.HttpResponse("Temporary storage error", status_code=503)

    logging.info("Stored ERP event %s (%s)", event["id"], event["event_type"])
    return func.HttpResponse(json.dumps({"status": "stored", "id": event["id"]}), status_code=202,
                             mimetype="application/json")


@app.function_name(name="AzureFilesDisasterRecoverySync")
@app.timer_trigger(
    schedule=os.environ.get("FILES_DR_SYNC_CRON", "0 0 0 1 1 *"),
    arg_name="timer",
    use_monitor=True,
    run_on_startup=False,
)
def azure_files_disaster_recovery_sync(timer: func.TimerRequest) -> None:
    """Mirror the private Chile share to Mexico with one monitored execution at a time."""
    if os.environ.get("FILES_DR_SYNC_ENABLED", "false").lower() != "true":
        logging.info("FILES_DR_SYNC_DISABLED")
        return

    primary_account = os.environ["FILES_DR_PRIMARY_ACCOUNT"]
    secondary_account = os.environ["FILES_DR_SECONDARY_ACCOUNT"]
    share_name = os.environ.get("FILES_DR_SHARE_NAME", "andeslog")
    identity_client_id = os.environ["FILES_DR_SYNC_IDENTITY_CLIENT_ID"]

    try:
        sync_args = dict(primary_account=primary_account, secondary_account=secondary_account,
                         share_name=share_name, identity_client_id=identity_client_id)
        if os.environ.get("FILES_DR_CHECKPOINT_ENABLED", "false").lower() == "true":
            with files_dr_checkpoint(primary_account, secondary_account, share_name, identity_client_id) as checkpoint:
                result = sync_share(**sync_args, checkpoint_store=checkpoint)
        else:
            result = sync_share(**sync_args)
    except Exception as exc:
        error_code = getattr(exc, "error_code", None)
        status_code = getattr(exc, "status_code", None)
        # Only log explicitly known, constant diagnostics; arbitrary exception
        # messages may contain user paths or credentials.
        known_errors = {
            "Azure Files did not return an ETag for a source file.": "source_etag_missing",
            "Azure Files source did not return its security descriptor key.": "source_acl_missing",
            "Azure Files source changed during replication; retry required.": "source_changed",
            "Azure Files destination has no permission key; reconciliation required.": "destination_acl_missing",
            "Azure Files destination appeared during replication; reconciliation required.": "destination_appeared",
            "Azure Files destination changed during replication; reconciliation required.": "destination_changed",
            "Azure Files source security descriptor is empty.": "source_descriptor_empty",
            "Azure Files destination did not return a security descriptor key.": "destination_descriptor_missing",
            "Azure Files destination is untracked or its permissions changed; reconciliation required.": "destination_untracked_or_acl_changed",
            "Azure Files destination ETag is missing; reconciliation required.": "destination_etag_missing",
            "Azure Files destination content hash is missing; reconciliation required.": "destination_content_hash_missing",
            "Azure Files destination ACL hash is missing; reconciliation required.": "destination_acl_hash_missing",
            "Azure Files destination ACL changed; reconciliation required.": "destination_acl_changed",
            "Azure Files temporary file ACL could not be preserved.": "temporary_acl_mismatch",
            "Azure Files destination directory ACL could not be preserved.": "directory_acl_mismatch",
            "Azure Files destination content changed; reconciliation required.": "destination_content_changed",
            "Azure Files download exceeded the source size.": "source_size_exceeded",
            "Azure Files download length did not match the source size.": "source_size_mismatch",
            "Azure Files destination size did not match the source size.": "destination_size_mismatch",
            "Azure Files source directory did not return its security descriptor key.": "source_directory_acl_missing",
            "Azure Files source directory permissions changed during replication; retry required.": "source_directory_acl_changed",
        }
        known_error = known_errors.get(str(exc), "unknown") if type(exc) is RuntimeError else "unknown"
        safe_code = "".join(char for char in str(error_code or "") if char.isalnum() or char in "-_.")[:100]
        logging.error(
            "FILES_DR_SYNC_FAILURE primary=%s secondary=%s error_type=%s status=%s error_code=%s reason=%s",
            primary_account,
            secondary_account,
            type(exc).__name__,
            status_code or "unknown",
            safe_code or "unknown",
            known_error,
        )
        raise RuntimeError("Azure Files DR sync failed; inspect the sanitized execution diagnostics.") from None

    summary = (result.stdout or "").strip()
    if summary:
        logging.info("Azure Files replica summary: %s", summary[-1000:])
    logging.info(
        "FILES_DR_SYNC_SUCCESS primary=%s secondary=%s share=%s started_utc=%s duration_ms=%d",
        primary_account,
        secondary_account,
        share_name,
        result.started_utc,
        result.duration_ms,
    )
