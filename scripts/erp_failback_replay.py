"""Experimental failback primitive. No CLI, credentials, or automatic deployment.

The caller must supply rows read from an authoritative database snapshot and a
sender that authenticates to the primary Function, rejects redirects and validates
the Function receipt. This primitive alone does not establish a safe failback.
"""
from __future__ import annotations

import importlib.util
import time
from itertools import islice
from pathlib import Path

_spec = importlib.util.spec_from_file_location("andeslog_archive_audit", Path(__file__).with_name("reconcile-erp-archive.py"))
audit = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(audit)


def replay_batch(rows, secondary, primary, send, *, limit, deadline, clock=time.monotonic):
    """Verify the entire bounded batch, then restore missing events through send.

    Each row must have a committed secondary delivery. A failed run can be
    partial; a subsequent run must repeat the full preflight. No database row is
    updated. The sender returns the validated JSON receipt, never an HTTP redirect.
    """
    if not 1 <= limit <= 10000:
        raise audit.AuditError("Invalid failback batch limit")
    rows = list(islice(rows, limit + 1))
    if len(rows) > limit:
        raise audit.AuditError("Failback batch is too large")
    if not rows:
        raise audit.AuditError("An empty batch does not establish recoverability")
    ids = set()
    for row in rows:
        if row.get("status") != "delivered" or row.get("delivered_destination") != "secondary":
            raise audit.AuditError("Batch contains an unconfirmed secondary delivery")
        event_id, _ = audit.canonical_event(row)
        if event_id in ids:
            raise audit.AuditError("Batch contains duplicate event identifiers")
        ids.add(event_id)

    preview, issues = audit.audit_failback_rows(rows, secondary, primary, limit=limit, deadline=deadline, clock=clock)
    if preview["truncated"] or preview["source_problem"] or preview["conflict"]:
        raise audit.AuditError("Failback preflight detected missing or conflicting data")
    needed = {issue["event_id"] for issue in issues if issue["status"] == "needs_copy"}
    counts = {"checked": len(rows), "restored": 0, "already_present": 0}
    for row in rows:
        event_id, body = audit.canonical_event(row)
        if event_id not in needed:
            counts["already_present"] += 1
            continue
        # Recheck immediately before sending: the preflight is not a lock.
        current, _ = audit.audit_failback_rows([row], secondary, primary, limit=1, deadline=deadline, clock=clock)
        if current["source_problem"] or current["conflict"]:
            raise audit.AuditError("Failback data changed after preflight")
        if current["already_present"]:
            counts["already_present"] += 1
            continue
        if clock() >= deadline:
            raise TimeoutError("Failback exceeded the cooperative deadline")
        receipt = send(event_id, body)
        if (not isinstance(receipt, dict) or receipt.get("id") != event_id
                or not isinstance(receipt.get("status"), str) or receipt["status"] not in {"stored", "duplicate"}):
            raise audit.AuditError("Failback sender returned an invalid receipt")
        if clock() >= deadline:
            raise TimeoutError("Failback exceeded the cooperative deadline")
        after, _ = audit.audit_failback_rows([row], secondary, primary, limit=1, deadline=deadline, clock=clock)
        if after["already_present"] != 1:
            raise audit.AuditError("Failback write could not be verified")
        counts["restored"] += 1
    final, _ = audit.audit_failback_rows(rows, secondary, primary, limit=limit, deadline=deadline, clock=clock)
    if final["already_present"] != len(rows) or final["truncated"]:
        raise audit.AuditError("Final failback batch verification failed")
    return counts
