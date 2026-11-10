#!/usr/bin/env python3
"""Journal synthetic committed markers and check their presence after failover.

The journal is local evidence, not a replicated database, and does not fence
writers or prove business-transaction durability. A lost commit response is
recorded as unknown, never as a confirmed success or failure.
"""

import argparse
import json
import os
import re
import sys
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path

import psycopg

MAX_ATTEMPTS = 1000


class WitnessError(Exception):
    pass


def write_event(stream, kind, marker=None):
    event = {"kind": kind, "at_utc": datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z"),
             "monotonic_ns": time.monotonic_ns()}
    if marker is not None:
        event["id"] = str(marker)
    stream.write(json.dumps(event, separators=(",", ":")) + "\n")
    stream.flush()
    os.fsync(stream.fileno())


def record(factory, path, count, interval, *, sleep=time.sleep):
    if not 1 <= count <= MAX_ATTEMPTS or not 0.1 <= interval <= 60:
        raise ValueError("Invalid write count or interval")
    # Exclusive creation prevents accidentally overwriting prior evidence.
    confirmed = uncertain = 0
    with open(path, "x", encoding="utf-8", newline="\n") as journal:
        write_event(journal, "start", uuid.uuid4())
        for index in range(count):
            marker = uuid.uuid4()
            write_event(journal, "intent", marker)
            connection = None
            acknowledged = False
            try:
                connection = factory()
                if not connection.autocommit:
                    raise WitnessError("Autocommit is required")
                row = connection.execute("SELECT pg_is_in_recovery()").fetchone()
                if not row or row[0] is not False:
                    raise WitnessError("Endpoint is not a primary")
                with connection.transaction():
                    connection.execute("INSERT INTO public.andeslog_replication_probes (probe_id) VALUES (%s)", (marker,))
                acknowledged = True
            except (psycopg.Error, WitnessError):
                # Any failed connection/commit is deliberately classified as
                # uncertain: the commit may have reached the server.
                pass
            finally:
                if connection is not None:
                    connection.close()
            write_event(journal, "ack" if acknowledged else "unknown", marker)
            if acknowledged:
                confirmed += 1
            else:
                uncertain += 1
            if index + 1 < count:
                sleep(interval)
        write_event(journal, "end")
    return {"confirmed": confirmed, "uncertain": uncertain}


def read_journal(path):
    events = []
    with open(path, encoding="utf-8") as stream:
        for line in stream:
            if len(line) > 1024 or len(events) >= 2 * MAX_ATTEMPTS + 2:
                raise WitnessError("Invalid journal size")
            try:
                event = json.loads(line)
            except (ValueError, UnicodeDecodeError):
                raise WitnessError("Invalid journal data") from None
            if not isinstance(event, dict) or event.get("kind") not in {"start", "intent", "ack", "unknown", "end"}:
                raise WitnessError("Invalid journal event")
            fields = {"kind", "at_utc", "monotonic_ns"}
            if event["kind"] != "end":
                fields.add("id")
            if set(event) != fields:
                raise WitnessError("Invalid journal fields")
            try:
                timestamp = datetime.fromisoformat(event["at_utc"].replace("Z", "+00:00"))
            except (ValueError, TypeError, AttributeError):
                raise WitnessError("Invalid journal time") from None
            if (timestamp.utcoffset() != timezone.utc.utcoffset(timestamp)
                    or type(event["monotonic_ns"]) is not int or event["monotonic_ns"] < 0
                    or (events and event["monotonic_ns"] < events[-1]["monotonic_ns"])):
                raise WitnessError("Invalid journal time")
            if "id" in event:
                try:
                    marker = uuid.UUID(event["id"])
                except (ValueError, TypeError, AttributeError):
                    raise WitnessError("Invalid journal identifier") from None
                if str(marker) != event["id"]:
                    raise WitnessError("Invalid journal identifier")
            events.append(event)
    if not events or events[0]["kind"] != "start":
        raise WitnessError("Missing journal start")
    markers, pending, closed = {}, None, False
    for event in events[1:]:
        kind = event["kind"]
        if closed:
            raise WitnessError("Unexpected data after journal end")
        if kind == "intent":
            if pending is not None or event["id"] in markers:
                raise WitnessError("Invalid journal sequence")
            pending = event["id"]
            markers[pending] = "unknown"
        elif kind in ("ack", "unknown"):
            if pending is None or event["id"] != pending:
                raise WitnessError("Invalid journal sequence")
            markers[pending] = kind
            pending = None
        elif kind == "end" and pending is None:
            closed = True
        else:
            raise WitnessError("Invalid journal sequence")
    return markers, closed


def verify(connection, path, expected_role):
    markers, closed = read_journal(path)
    if expected_role not in ("primary", "replica") or not connection.autocommit:
        raise WitnessError("Invalid verification role or connection")
    expected_recovery = expected_role == "replica"
    first = connection.execute("SELECT pg_is_in_recovery()").fetchone()
    if not first or first[0] is not expected_recovery:
        raise WitnessError("Unexpected verification database role")
    found = set()
    ids = list(markers)
    for offset in range(0, len(ids), 200):
        batch = [uuid.UUID(item) for item in ids[offset:offset + 200]]
        rows = connection.execute("SELECT probe_id FROM public.andeslog_replication_probes WHERE probe_id = ANY(%s::uuid[])", (batch,)).fetchall()
        found.update(str(row[0]) for row in rows)
    last = connection.execute("SELECT pg_is_in_recovery()").fetchone()
    if not last or last[0] is not expected_recovery:
        raise WitnessError("Verification database role changed")
    acknowledged = {key for key, value in markers.items() if value == "ack"}
    uncertain = set(markers) - acknowledged
    missing = acknowledged - found
    return {
        "journal_closed": closed,
        "confirmed": len(acknowledged),
        "confirmed_missing": len(missing),
        "uncertain_present": len(uncertain & found),
        "uncertain_absent": len(uncertain - found),
        "all_confirmed_present": bool(acknowledged) and not missing,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="action", required=True)
    for name in ("record", "verify"):
        command = sub.add_parser(name)
        command.add_argument("--service", required=True)
        command.add_argument("--ca-bundle", type=Path, required=True)
        command.add_argument("--journal", type=Path, required=True)
    sub.choices["record"].add_argument("--count", type=int, default=30)
    sub.choices["record"].add_argument("--interval", type=float, default=1.0)
    sub.choices["record"].add_argument("--execute", action="store_true")
    sub.choices["verify"].add_argument("--expect-role", choices=("primary", "replica"), required=True)
    args = parser.parse_args()
    if not re.fullmatch(r"[A-Za-z0-9_-]{1,64}", args.service) or not args.ca_bundle.is_file():
        parser.error("Invalid libpq service name or missing CA bundle")
    if args.action == "record" and not args.execute:
        parser.error("--execute is required to write synthetic database markers")
    options = dict(service=args.service, sslmode="verify-full", sslrootcert=str(args.ca_bundle),
                   connect_timeout=5, autocommit=True, options="-c statement_timeout=5000")
    try:
        if args.action == "record":
            result = record(lambda: psycopg.connect(**options), args.journal, args.count, args.interval)
            print(json.dumps(result, sort_keys=True))
            return 0 if result["confirmed"] and not result["uncertain"] else 2
        with psycopg.connect(**options) as connection:
            result = verify(connection, args.journal, args.expect_role)
        print(json.dumps(result, sort_keys=True))
        return 0 if (result["journal_closed"] and result["all_confirmed_present"]
                     and result["uncertain_present"] == 0 and result["uncertain_absent"] == 0) else 2
    except (OSError, ValueError, WitnessError, psycopg.Error):
        # Driver exceptions may expose connection details; do not print them.
        print("Witness failed; check journal, role, TLS, connectivity and permissions.", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
