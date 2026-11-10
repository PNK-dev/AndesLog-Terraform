"""Experimental, bounded replay of confirmed secondary ERP events.

Dry-run by default. --execute sends to the authenticated primary Function but
does not fence writers, switch traffic, or prove a complete regional failback.
"""
from __future__ import annotations

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
from pathlib import Path
from urllib.parse import urlsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener

import psycopg
from psycopg.rows import dict_row
from azure.identity import DefaultAzureCredential, ManagedIdentityCredential
from azure.storage.blob import BlobServiceClient

import erp_failback_replay as replay


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def validate_primary_url(value):
    if any(ord(char) <= 32 or ord(char) == 127 for char in value):
        raise ValueError("Invalid primary Function URL")
    parsed = urlsplit(value)
    try:
        port = parsed.port
    except ValueError:
        raise ValueError("Invalid primary Function URL") from None
    if (parsed.scheme != "https" or not parsed.hostname or parsed.username is not None or parsed.password is not None
            or port is not None or parsed.path != "/api/erp/events" or parsed.query or parsed.fragment
            or not re.fullmatch(r"[a-z0-9](?:[a-z0-9-]{0,58}[a-z0-9])?\.azurewebsites\.net", parsed.hostname)):
        raise ValueError("Invalid primary Function URL")


def send_receipt(url, secret, event_id, body, *, opener=None):
    signature = "sha256=" + hmac.new(secret.encode("utf-8"), body, hashlib.sha256).hexdigest()
    request = Request(url, data=body, method="POST", headers={"Content-Type": "application/json",
                      "User-Agent": "AndesLog-Failback/1.0", "X-AndesLog-Signature": signature})
    with (opener or build_opener(NoRedirect())).open(request, timeout=10) as response:
        if not 200 <= response.status < 300:
            raise ValueError("Primary Function did not accept event")
        raw = response.read(4097)
        if len(raw) > 4096:
            raise ValueError("Oversized Function receipt")
        try:
            receipt = json.loads(raw)
        except (ValueError, UnicodeDecodeError):
            raise ValueError("Invalid Function receipt") from None
        if (not isinstance(receipt, dict) or receipt.get("id") != event_id
                or not isinstance(receipt.get("status"), str) or receipt["status"] not in {"stored", "duplicate"}):
            raise ValueError("Unrecognized Function receipt")
        return receipt


def read_confirmed_batch(connection, *, expected_host, limit):
    if connection.autocommit or connection.info.host != expected_host:
        raise replay.audit.AuditError("Database host or transaction mode does not match")
    connection.read_only = True
    connection.isolation_level = psycopg.IsolationLevel.REPEATABLE_READ
    with connection.cursor() as cursor:
        cursor.execute("SELECT pg_is_in_recovery() AS is_replica")
        if cursor.fetchone()["is_replica"]:
            raise replay.audit.AuditError("The selected database is a replica")
        cursor.execute("SELECT count(*) AS invalid_count FROM public.outbox_event "
                       "WHERE status = 'delivered' AND delivered_destination IS NOT NULL "
                       "AND delivered_destination NOT IN ('primary', 'secondary')")
        if cursor.fetchone()["invalid_count"]:
            raise replay.audit.AuditError("Unexpected delivery destination")
        cursor.execute("SELECT id, event_type, aggregate_type, aggregate_id, payload, created_at, status, delivered_destination "
                       "FROM public.outbox_event WHERE status = 'delivered' AND delivered_destination = 'secondary' "
                       "ORDER BY created_at, id LIMIT %s", (limit + 1,))
        rows = cursor.fetchall()
    if len(rows) > limit:
        raise replay.audit.AuditError("Batch exceeds limit; paging has not been implemented")
    return rows


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--service", required=True)
    parser.add_argument("--expected-db-host", required=True)
    parser.add_argument("--ca-bundle", required=True, type=Path)
    parser.add_argument("--secondary-account", required=True)
    parser.add_argument("--primary-account", required=True)
    parser.add_argument("--primary-url", required=True)
    parser.add_argument("--managed-identity-client-id")
    parser.add_argument("--max-events", type=int, default=1000)
    parser.add_argument("--timeout-seconds", type=int, default=60)
    parser.add_argument("--execute", action="store_true", help="send missing events; requires ERP_FAILBACK_HMAC_SECRET")
    args = parser.parse_args(argv)
    try:
        validate_primary_url(args.primary_url)
        if (not re.fullmatch(r"[A-Za-z0-9_-]{1,64}", args.service)
                or not re.fullmatch(r"[A-Za-z0-9.-]{1,253}", args.expected_db_host)
                or not re.fullmatch(r"[a-z0-9]{3,24}", args.secondary_account)
                or not re.fullmatch(r"[a-z0-9]{3,24}", args.primary_account)
                or args.secondary_account == args.primary_account or not args.ca_bundle.is_file()
                or not 1 <= args.max_events <= 10000 or not 1 <= args.timeout_seconds <= 300):
            raise ValueError()
        if args.managed_identity_client_id and str(uuid.UUID(args.managed_identity_client_id)) != args.managed_identity_client_id:
            raise ValueError()
        secret = os.environ.get("ERP_FAILBACK_HMAC_SECRET", "") if args.execute else ""
        if args.execute and len(secret) < 32:
            raise ValueError()
    except ValueError:
        parser.error("Invalid URL, accounts, database host, CA, identity, limits or HMAC configuration")

    logging.getLogger("azure").setLevel(logging.WARNING)
    credential = secondary_service = primary_service = None
    try:
        credential = (ManagedIdentityCredential(client_id=args.managed_identity_client_id)
                      if args.managed_identity_client_id else DefaultAzureCredential(exclude_interactive_browser_credential=True))
        secondary_service = BlobServiceClient(account_url=f"https://{args.secondary_account}.blob.core.windows.net", credential=credential,
                                              connection_timeout=5, read_timeout=10)
        primary_service = BlobServiceClient(account_url=f"https://{args.primary_account}.blob.core.windows.net", credential=credential,
                                            connection_timeout=5, read_timeout=10)
        secondary = secondary_service.get_container_client("erp-events-failover")
        primary = primary_service.get_container_client("erp-events")
        deadline = time.monotonic() + args.timeout_seconds
        with psycopg.connect(service=args.service, sslmode="verify-full", sslrootcert=str(args.ca_bundle), connect_timeout=5,
                             autocommit=False, row_factory=dict_row, options="-c statement_timeout=10000") as connection:
            rows = read_confirmed_batch(connection, expected_host=args.expected_db_host, limit=args.max_events)
        if not rows:
            print(json.dumps({"checked": 0, "mode": "empty"}))
            return 2
        if args.execute:
            result = replay.replay_batch(rows, secondary, primary,
                lambda event_id, body: send_receipt(args.primary_url, secret, event_id, body),
                limit=args.max_events, deadline=deadline)
            result["mode"] = "execute"
            code = 0
        else:
            result, _ = replay.audit.audit_failback_rows(rows, secondary, primary, limit=args.max_events, deadline=deadline)
            result["mode"] = "preview"
            code = 2 if result["needs_copy"] or result["source_problem"] or result["conflict"] or result["truncated"] else 0
        print(json.dumps(result, sort_keys=True))
        return code
    except Exception:
        print("Failback stopped; check the database, private network, authorization, archives and Function. A partial run may have occurred.", file=sys.stderr)
        return 1
    finally:
        for resource in (primary_service, secondary_service, credential):
            if resource is not None:
                try:
                    resource.close()
                except Exception:
                    pass


if __name__ == "__main__":
    raise SystemExit(main())
