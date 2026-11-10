#!/usr/bin/env python3
"""Read-only comparison of confirmed ERP events with an Azure Blob archive.

This detects missing/different objects visible at inspection time. It does not
repair data, provide a cross-service snapshot, or prove a recovery objective.
"""

import argparse
import hashlib
import hmac
import json
import logging
import os
import re
import sys
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path

import psycopg
from azure.core import MatchConditions
from azure.core.exceptions import ResourceNotFoundError
from azure.identity import DefaultAzureCredential, ManagedIdentityCredential
from azure.storage.blob import BlobServiceClient
from psycopg.rows import dict_row

MAX_EVENT_BYTES = 256 * 1024


class AuditError(Exception):
    pass


def canonical_event(row):
    try:
        event_id = str(uuid.UUID(row["id"]))
        created = row["created_at"]
        if event_id != row["id"] or not isinstance(created, datetime) or created.tzinfo is not None:
            raise ValueError("Unexpected event identifier or timestamp")
        event = {
            "id": event_id,
            "event_type": row["event_type"],
            "occurred_at": created.replace(tzinfo=timezone.utc).isoformat(),
            "source": "andeslog-erp",
            "aggregate_type": row["aggregate_type"],
            "aggregate_id": row["aggregate_id"],
            "payload": row["payload"],
        }
        if not all(isinstance(event[key], str) and event[key] for key in ("event_type", "aggregate_type", "aggregate_id")):
            raise ValueError("Invalid event fields")
        if not isinstance(event["payload"], dict):
            raise ValueError("Invalid event payload")
        body = json.dumps(event, ensure_ascii=False, separators=(",", ":"), sort_keys=True).encode("utf-8")
        if len(body) > MAX_EVENT_BYTES:
            raise ValueError("Event exceeds ingress size")
        return event_id, body
    except (KeyError, TypeError, ValueError, AttributeError):
        raise AuditError("Stored event cannot be serialized safely") from None


def audit_rows(rows, container, *, limit, deadline, clock=time.monotonic):
    if not 1 <= limit <= 10000:
        raise ValueError("Invalid event limit")
    result = {"checked": 0, "matching": 0, "missing": 0, "different": 0, "truncated": False}
    issues = []
    for row in rows:
        if clock() >= deadline:
            raise TimeoutError("Archive audit exceeded the cooperative deadline")
        if result["checked"] == limit:
            result["truncated"] = True
            break
        event_id, expected_body = canonical_event(row)
        blob = container.get_blob_client(f"{event_id}.json")
        try:
            properties = blob.get_blob_properties()
            if not properties.etag or properties.size is None or properties.size < 0:
                raise AuditError("Blob properties are incomplete")
            if properties.size > MAX_EVENT_BYTES:
                classification = "different"
            else:
                actual = blob.download_blob(etag=properties.etag, match_condition=MatchConditions.IfNotModified,
                                            decompress=False).readall()
                if len(actual) != properties.size:
                    raise AuditError("Blob length changed during inspection")
                classification = ("matching" if hmac.compare_digest(hashlib.sha256(actual).digest(),
                                                                   hashlib.sha256(expected_body).digest()) else "different")
        except ResourceNotFoundError as exc:
            if str(getattr(exc, "error_code", "")) != "BlobNotFound":
                raise AuditError("Archive or container could not be found") from None
            classification = "missing"
        if clock() >= deadline:
            raise TimeoutError("Archive audit exceeded the cooperative deadline")
        result["checked"] += 1
        result[classification] += 1
        if classification != "matching":
            issues.append({"event_id": event_id, "status": classification})
    return result, issues


def audit_failback_rows(rows, secondary, primary, *, limit, deadline, clock=time.monotonic):
    """Read both copies against PostgreSQL; never change either archive."""
    if not 1 <= limit <= 10000:
        raise ValueError("Invalid event limit")
    result = {"checked": 0, "already_present": 0, "needs_copy": 0,
              "source_problem": 0, "conflict": 0, "truncated": False}
    issues = []
    for row in rows:
        if clock() >= deadline:
            raise TimeoutError("Archive audit exceeded the cooperative deadline")
        if result["checked"] == limit:
            result["truncated"] = True
            break
        event_id, _ = canonical_event(row)
        source, _ = audit_rows([row], secondary, limit=1, deadline=deadline, clock=clock)
        if source["matching"] != 1:
            status = "source_problem"
            detail = "missing" if source["missing"] else "different"
        else:
            target, _ = audit_rows([row], primary, limit=1, deadline=deadline, clock=clock)
            status = "already_present" if target["matching"] else "needs_copy" if target["missing"] else "conflict"
            detail = None
        result["checked"] += 1
        result[status] += 1
        if status != "already_present":
            issue = {"event_id": event_id, "status": status}
            if detail:
                issue["source_status"] = detail
            issues.append(issue)
    return result, issues


def write_report(path, result, issues):
    """Create a new report; do not overwrite an existing file."""
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as stream:
        json.dump({"summary": result, "issues": issues}, stream, ensure_ascii=False, sort_keys=True)
        stream.write("\n")
        stream.flush()
        os.fsync(stream.fileno())


def audit_database(connection, container, *, limit, deadline, delivery_source="primary", comparison_container=None):
    if connection.autocommit:
        raise AuditError("The database audit requires a transaction")
    if delivery_source not in ("primary", "secondary"):
        raise AuditError("Invalid delivery source")
    if comparison_container is not None and delivery_source != "secondary":
        raise AuditError("Failback comparison requires secondary deliveries")
    connection.read_only = True
    connection.isolation_level = psycopg.IsolationLevel.REPEATABLE_READ
    with connection.cursor() as cursor:
        cursor.execute("SELECT pg_is_in_recovery() AS is_replica")
        replica = cursor.fetchone()["is_replica"]
        cursor.execute("SELECT count(*) AS invalid_count FROM public.outbox_event "
                       "WHERE status = 'delivered' AND delivered_destination IS NOT NULL "
                       "AND delivered_destination NOT IN ('primary', 'secondary')")
        if cursor.fetchone()["invalid_count"]:
            raise AuditError("Unexpected recorded delivery destination")
    with connection.cursor(name="andeslog_archive_audit") as cursor:
        cursor.itersize = 100
        cursor.execute("SELECT id, event_type, aggregate_type, aggregate_id, payload, created_at "
                       "FROM public.outbox_event WHERE status = 'delivered' "
                       "AND COALESCE(delivered_destination, 'primary') = %s ORDER BY created_at, id LIMIT %s",
                       (delivery_source, limit + 1))
        if comparison_container is None:
            result, issues = audit_rows(cursor, container, limit=limit, deadline=deadline)
        else:
            result, issues = audit_failback_rows(cursor, container, comparison_container, limit=limit, deadline=deadline)
            result["comparison_mode"] = "failback_preview"
    result["database_is_replica"] = replica
    result["delivery_source"] = delivery_source
    return result, issues


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--service", required=True, help="libpq service name")
    parser.add_argument("--ca-bundle", required=True, type=Path)
    parser.add_argument("--storage-account", required=True)
    parser.add_argument("--delivery-source", choices=("primary", "secondary"), default="primary")
    parser.add_argument("--container", help="archive container; defaults according to delivery source")
    parser.add_argument("--compare-primary-account", help="read-only failback preview against primary erp-events")
    parser.add_argument("--managed-identity-client-id")
    parser.add_argument("--max-events", type=int, default=1000)
    parser.add_argument("--timeout-seconds", type=int, default=60)
    parser.add_argument("--report", type=Path, help="optional new local file containing event IDs with issues")
    args = parser.parse_args()
    if args.container is None:
        args.container = "erp-events-replica" if args.delivery_source == "primary" else "erp-events-failover"
    if args.compare_primary_account and (args.delivery_source != "secondary" or args.container != "erp-events-failover"
                                         or args.compare_primary_account == args.storage_account
                                         or not re.fullmatch(r"[a-z0-9]{3,24}", args.compare_primary_account)):
        parser.error("Failback preview requires secondary delivery, the failover container and a distinct primary account")
    if (not re.fullmatch(r"[A-Za-z0-9_-]{1,64}", args.service)
            or not re.fullmatch(r"[a-z0-9]{3,24}", args.storage_account)
            or not re.fullmatch(r"[a-z0-9](?:[a-z0-9-]{1,61}[a-z0-9])", args.container)
            or "--" in args.container or not args.ca_bundle.is_file()
            or not 1 <= args.max_events <= 10000 or not 1 <= args.timeout_seconds <= 300):
        parser.error("Invalid service, account, container, CA or audit limits")
    if args.managed_identity_client_id:
        try:
            if str(uuid.UUID(args.managed_identity_client_id)) != args.managed_identity_client_id:
                raise ValueError()
        except ValueError:
            parser.error("Invalid managed identity client ID")
    logging.getLogger("azure").setLevel(logging.WARNING)
    credential = None
    service = None
    primary_service = None
    try:
        credential = (ManagedIdentityCredential(client_id=args.managed_identity_client_id)
                      if args.managed_identity_client_id else DefaultAzureCredential(exclude_interactive_browser_credential=True))
        service = BlobServiceClient(account_url=f"https://{args.storage_account}.blob.core.windows.net", credential=credential,
                                    connection_timeout=5, read_timeout=10)
        container = service.get_container_client(args.container)
        comparison_container = None
        if args.compare_primary_account:
            primary_service = BlobServiceClient(account_url=f"https://{args.compare_primary_account}.blob.core.windows.net",
                                                credential=credential, connection_timeout=5, read_timeout=10)
            comparison_container = primary_service.get_container_client("erp-events")
        deadline = time.monotonic() + args.timeout_seconds
        with psycopg.connect(service=args.service, sslmode="verify-full", sslrootcert=str(args.ca_bundle),
                             connect_timeout=5, autocommit=False, row_factory=dict_row,
                             options="-c statement_timeout=10000") as connection:
            result, issues = audit_database(connection, container, limit=args.max_events, deadline=deadline,
                                            delivery_source=args.delivery_source, comparison_container=comparison_container)
        if args.report:
            write_report(args.report, result, issues)
        print(json.dumps(result, sort_keys=True))
        if comparison_container is not None:
            incomplete = result["needs_copy"] or result["source_problem"] or result["conflict"] or result["truncated"]
        else:
            incomplete = result["missing"] or result["different"] or result["truncated"]
        return 0 if result["checked"] > 0 and not incomplete else 2
    except Exception:
        # Azure and PostgreSQL errors can contain URLs, file names, or secrets.
        print("Archive audit failed; check identity, private network, database, limits and report path.", file=sys.stderr)
        return 1
    finally:
        if primary_service is not None:
            try:
                primary_service.close()
            except Exception:
                pass
        if service is not None:
            try:
                service.close()
            except Exception:
                pass
        if credential is not None:
            try:
                credential.close()
            except Exception:
                pass


if __name__ == "__main__":
    raise SystemExit(main())
