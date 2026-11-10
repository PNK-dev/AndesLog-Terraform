#!/usr/bin/env python3
"""Compare selected ERP tables with a trusted pre-restore reference.

Uses bounded, read-only PostgreSQL snapshots. It does not establish backup
provenance, database completeness, credentials, RPO or safe failback.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

import psycopg
from psycopg import sql

TABLES = {
    "users": ("user", ("id", "username", "role", "created_at")),
    "warehouses": ("warehouse", ("id", "code", "name", "city", "active")),
    "products": ("product", ("id", "sku", "name", "unit", "active")),
    "customers": ("customer", ("id", "tax_id", "business_name", "email", "contact_name", "active")),
    "inventory": ("inventory_balances", ("id", "warehouse_id", "product_id", "quantity")),
    "movements": ("stock_movement", ("id", "operation_id", "warehouse_id", "product_id", "user_id", "movement_type", "quantity", "reason", "created_at")),
    "orders": ("sales_order", ("id", "number", "customer_id", "status", "created_by_id", "created_at")),
    "order_lines": ("order_line", ("id", "order_id", "product_id", "quantity")),
    "vehicles": ("vehicle", ("id", "plate", "vehicle_type", "capacity_kg", "active")),
    "drivers": ("driver", ("id", "name", "license_number", "phone", "active")),
    "trips": ("trip", ("id", "code", "origin", "destination", "vehicle_id", "driver_id", "order_id", "status", "departure_at")),
    "outbox": ("outbox_event", ("id", "event_type", "aggregate_type", "aggregate_id", "payload", "status", "created_at", "delivered_destination")),
}
MAX_MANIFEST_BYTES = 64 * 1024
MAX_ROW_BYTES = 2 * 1024 * 1024


class VerificationError(Exception):
    pass


def snapshot(connection, *, expected_host, max_rows, deadline, clock=time.monotonic):
    if connection.autocommit or connection.info.host != expected_host or not 1 <= max_rows <= 100000:
        raise VerificationError("Invalid connection or row limit")
    connection.read_only = True
    connection.isolation_level = psycopg.IsolationLevel.REPEATABLE_READ
    with connection.cursor() as cursor:
        cursor.execute("SET LOCAL TIME ZONE 'UTC'")
        cursor.execute("SELECT pg_is_in_recovery(), current_database(), current_setting('server_version_num')::integer")
        in_recovery, database, server_version = cursor.fetchone()
        if in_recovery is not False or not database or server_version < 100000:
            raise VerificationError("Expected a PostgreSQL server not in recovery")
        cursor.execute("SELECT version_num FROM public.alembic_version ORDER BY version_num LIMIT 2")
        revisions = cursor.fetchall()
        if len(revisions) != 1 or not re.fullmatch(r"[A-Za-z0-9_-]{1,64}", revisions[0][0]):
            raise VerificationError("Expected one valid schema revision")
        revision = revisions[0][0]
    results = {}
    for label, (table, columns) in TABLES.items():
        if clock() >= deadline:
            raise TimeoutError("Verification budget exceeded")
        statement = sql.SQL("SELECT to_jsonb(src)::text FROM (SELECT {} FROM {}.{} ORDER BY id LIMIT %s) AS src ORDER BY src.id").format(
            sql.SQL(", ").join(map(sql.Identifier, columns)), sql.Identifier("public"), sql.Identifier(table))
        digest, count = hashlib.sha256(), 0
        with connection.cursor(name=f"andeslog_verify_{label}") as cursor:
            cursor.itersize = 100
            cursor.execute(statement, (max_rows + 1,))
            for row in cursor:
                if clock() >= deadline:
                    raise TimeoutError("Verification budget exceeded")
                count += 1
                if count > max_rows:
                    raise VerificationError("A table exceeds the configured verification limit")
                encoded = row[0].encode("utf-8")
                if len(encoded) > MAX_ROW_BYTES:
                    raise VerificationError("A record exceeds the verification size limit")
                digest.update(len(encoded).to_bytes(8, "big"))
                digest.update(encoded)
        results[label] = {"rows": count, "sha256": digest.hexdigest()}
    if not results["users"]["rows"]:
        raise VerificationError("A reference without users is not a useful ERP verification")
    if clock() >= deadline:
        raise TimeoutError("Verification budget exceeded")
    return {"version": 1, "created_utc": datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z"),
            "database": {"host": connection.info.host, "port": connection.info.port, "name": database,
                         "postgres_major": server_version // 10000},
            "migration_revision": revision, "tables": results}


def validate_manifest(value):
    if (not isinstance(value, dict) or set(value) != {"version", "created_utc", "database", "migration_revision", "tables"}
            or type(value["version"]) is not int or value["version"] != 1):
        raise VerificationError("Invalid reference structure")
    database = value["database"]
    if (not isinstance(database, dict) or set(database) != {"host", "port", "name", "postgres_major"}
            or not isinstance(database["host"], str) or not database["host"]
            or type(database["port"]) is not int or not 1 <= database["port"] <= 65535
            or not isinstance(database["name"], str) or not database["name"]
            or type(database["postgres_major"]) is not int or database["postgres_major"] < 10
            or not isinstance(value["created_utc"], str)
            or not isinstance(value["migration_revision"], str)
            or not re.fullmatch(r"[A-Za-z0-9_-]{1,64}", value["migration_revision"])):
        raise VerificationError("Invalid reference metadata")
    tables = value["tables"]
    if not isinstance(tables, dict) or set(tables) != set(TABLES):
        raise VerificationError("Invalid reference tables")
    for entry in tables.values():
        if (not isinstance(entry, dict) or set(entry) != {"rows", "sha256"} or type(entry["rows"]) is not int
                or not 0 <= entry["rows"] <= 100000 or not isinstance(entry["sha256"], str)
                or not re.fullmatch(r"[0-9a-f]{64}", entry["sha256"])):
            raise VerificationError("Invalid reference table digest")
    if not tables["users"]["rows"]:
        raise VerificationError("Empty user reference")
    return value


def compare(reference, actual):
    reference, actual = validate_manifest(reference), validate_manifest(actual)
    if (reference["database"]["host"].casefold(), reference["database"]["port"], reference["database"]["name"]) == (
            actual["database"]["host"].casefold(), actual["database"]["port"], actual["database"]["name"]):
        raise VerificationError("Reference and target identify the same database")
    if reference["database"]["postgres_major"] != actual["database"]["postgres_major"]:
        raise VerificationError("PostgreSQL major versions differ; canonical representation must be reviewed")
    mismatches = [name for name in TABLES if reference["tables"][name] != actual["tables"][name]]
    return {"matching": not mismatches and reference["migration_revision"] == actual["migration_revision"],
            "schema_matches": reference["migration_revision"] == actual["migration_revision"],
            "tables_checked": len(TABLES), "different_tables": mismatches}


def read_manifest(path):
    with path.open("rb") as stream:
        raw = stream.read(MAX_MANIFEST_BYTES + 1)
    if len(raw) > MAX_MANIFEST_BYTES:
        raise VerificationError("Reference is too large")
    try:
        return validate_manifest(json.loads(raw))
    except (ValueError, UnicodeDecodeError):
        raise VerificationError("Invalid reference data") from None


def write_manifest(path, manifest):
    data = (json.dumps(validate_manifest(manifest), ensure_ascii=False, sort_keys=True) + "\n").encode("utf-8")
    if len(data) > MAX_MANIFEST_BYTES:
        raise VerificationError("Reference is too large")
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "wb") as stream:
        stream.write(data)
        stream.flush()
        os.fsync(stream.fileno())


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("capture", "verify"))
    parser.add_argument("--service", required=True)
    parser.add_argument("--expected-host", required=True)
    parser.add_argument("--ca-bundle", required=True, type=Path)
    parser.add_argument("--manifest", required=True, type=Path)
    parser.add_argument("--max-rows-per-table", type=int, default=10000)
    parser.add_argument("--timeout-seconds", type=int, default=60)
    args = parser.parse_args(argv)
    if (not re.fullmatch(r"[A-Za-z0-9_-]{1,64}", args.service)
            or not re.fullmatch(r"[A-Za-z0-9.-]{1,253}", args.expected_host) or not args.ca_bundle.is_file()
            or not 1 <= args.max_rows_per_table <= 100000 or not 1 <= args.timeout_seconds <= 300):
        parser.error("Invalid service, host, CA or verification limits")
    try:
        reference = read_manifest(args.manifest) if args.action == "verify" else None
        deadline = time.monotonic() + args.timeout_seconds
        with psycopg.connect(service=args.service, sslmode="verify-full", sslrootcert=str(args.ca_bundle),
                             connect_timeout=5, autocommit=False, options="-c statement_timeout=10000") as connection:
            actual = snapshot(connection, expected_host=args.expected_host, max_rows=args.max_rows_per_table, deadline=deadline)
        if args.action == "capture":
            write_manifest(args.manifest, actual)
            print(json.dumps({"status": "reference_created", "tables": len(TABLES)}))
            return 0
        result = compare(reference, actual)
        print(json.dumps(result, sort_keys=True))
        return 0 if result["matching"] else 2
    except Exception:
        print("ERP restore verification stopped; check reference, database, permissions, TLS and limits.", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
