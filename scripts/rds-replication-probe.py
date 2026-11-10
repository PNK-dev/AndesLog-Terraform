#!/usr/bin/env python3
"""Measure one committed marker's visibility on a PostgreSQL read replica.

The marker table must be installed beforehand by an administrator. This is a
controlled write, not a continuous RPO guarantee or a failover mechanism.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import time
import uuid
from pathlib import Path

import psycopg


class ProbeError(Exception):
    """An unsafe database role or a failed observation."""


def _in_recovery(connection) -> bool:
    with connection.cursor() as cursor:
        cursor.execute("SELECT pg_is_in_recovery()")
        row = cursor.fetchone()
    if not row or not isinstance(row[0], bool):
        raise ProbeError("Database role could not be verified")
    return row[0]


def probe(primary, replica, timeout: float, interval: float = 1.0, *, clock=time.monotonic, sleep=time.sleep) -> dict:
    if not (1 <= timeout <= 300 and 0 < interval <= timeout):
        raise ValueError("Invalid observation interval")
    if not primary.autocommit or not replica.autocommit:
        raise ProbeError("Probe connections require autocommit")
    if _in_recovery(primary) or not _in_recovery(replica):
        raise ProbeError("Expected a writable primary and a read-only replica")
    probe_id = str(uuid.uuid4())
    started = clock()
    with primary.transaction():
        with primary.cursor() as cursor:
            cursor.execute("INSERT INTO public.andeslog_replication_probes (probe_id) VALUES (%s)", (probe_id,))
    committed_at = clock()
    deadline = committed_at + timeout
    while True:
        with replica.cursor() as cursor:
            cursor.execute(
                "SELECT pg_is_in_recovery(), EXISTS (SELECT 1 FROM public.andeslog_replication_probes WHERE probe_id = %s)",
                (probe_id,),
            )
            row = cursor.fetchone()
        if not row or row[0] is not True:
            raise ProbeError("Replica role changed during the observation")
        now = clock()
        if row[1] is True:
            return {
                "probe_id": probe_id,
                "observed": True,
                "within_timeout": now <= deadline,
                "commit_to_observation_seconds": round(now - committed_at, 3),
                "total_seconds": round(now - started, 3),
            }
        remaining = deadline - now
        if remaining <= 0:
            return {
                "probe_id": probe_id,
                "observed": False,
                "within_timeout": False,
                "commit_to_observation_seconds": None,
                "total_seconds": round(now - started, 3),
            }
        sleep(min(interval, remaining))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--primary-service", required=True, help="libpq service name for the primary")
    parser.add_argument("--replica-service", required=True, help="libpq service name for the read replica")
    parser.add_argument("--ca-bundle", required=True, type=Path)
    parser.add_argument("--timeout-seconds", default=300, type=int)
    parser.add_argument("--execute", action="store_true", help="explicitly allow one probe write")
    args = parser.parse_args()
    if not args.execute:
        parser.error("--execute is required because the probe writes a marker")
    if not all(re.fullmatch(r"[A-Za-z0-9_-]{1,64}", name) for name in (args.primary_service, args.replica_service)):
        parser.error("service names may contain only letters, digits, underscores and hyphens")
    if args.primary_service == args.replica_service or not args.ca_bundle.is_file() or not 1 <= args.timeout_seconds <= 300:
        parser.error("use different services, an existing CA file and a timeout between 1 and 300 seconds")
    try:
        options = {"sslmode": "verify-full", "sslrootcert": str(args.ca_bundle), "connect_timeout": 5, "autocommit": True}
        with psycopg.connect(service=args.primary_service, **options) as primary:
            with psycopg.connect(service=args.replica_service, **options) as replica:
                result = probe(primary, replica, float(args.timeout_seconds))
        print(json.dumps(result, sort_keys=True))
        return 0 if result["within_timeout"] else 2
    except Exception:
        # Driver errors may include database URLs or credentials; do not print them.
        print("Replication probe failed; check connectivity, permissions and database roles.", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
