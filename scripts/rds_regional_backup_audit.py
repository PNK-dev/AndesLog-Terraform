#!/usr/bin/env python3
"""Inspect one exact cross-region RDS automated backup; preview by default.

The optional delete is irreversible. It refuses active replication, a changed
identity, wrong account/region/source and ambiguous results. It does not stop
replication, inspect other backups, or prove a zero-cost AWS account.
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
import time

ARN = re.compile(r"^arn:aws:rds:([a-z0-9-]+):([0-9]{12}):auto-backup:(ab-[A-Za-z0-9]+)$")
SOURCE_ARN = re.compile(r"^arn:aws:rds:([a-z0-9-]+):([0-9]{12}):db:([a-zA-Z0-9-]+)$")
DBI = re.compile(r"^db-[A-Za-z0-9]+$")


class BackupError(Exception):
    pass


def aws_json(arguments, *, run=subprocess.run):
    result = run(["aws", *arguments, "--output", "json", "--no-cli-pager"], capture_output=True, text=True, timeout=30)
    if result.returncode != 0:
        raise BackupError("AWS CLI call failed")
    try:
        value = json.loads(result.stdout)
    except (ValueError, TypeError):
        raise BackupError("AWS CLI returned invalid JSON") from None
    if not isinstance(value, dict):
        raise BackupError("AWS CLI returned an unexpected response")
    return value


def validate_identity(account, backup_arn, source_arn, dbi):
    backup, source = ARN.fullmatch(backup_arn), SOURCE_ARN.fullmatch(source_arn)
    if (not re.fullmatch(r"[0-9]{12}", account) or not backup or not source or not DBI.fullmatch(dbi)
            or backup.group(2) != account or source.group(2) != account or backup.group(1) == source.group(1)):
        raise BackupError("Invalid account, source, backup ARN or region")
    return backup.group(1)


def find_exact(region, account, backup_arn, source_arn, dbi, *, query=aws_json):
    identity = query(["sts", "get-caller-identity", "--region", region])
    if identity.get("Account") != account:
        raise BackupError("AWS identity does not match expected account")
    response = query(["rds", "describe-db-instance-automated-backups", "--region", region,
                      "--filters", f"Name=dbi-resource-id,Values={dbi}"])
    records = response.get("DBInstanceAutomatedBackups")
    if not isinstance(records, list):
        raise BackupError("AWS backup list is incomplete")
    if any(not isinstance(entry, dict) or not isinstance(entry.get("DBInstanceAutomatedBackupsArn"), str) for entry in records):
        raise BackupError("AWS backup list contains incomplete records")
    matches = [entry for entry in records if entry["DBInstanceAutomatedBackupsArn"] == backup_arn]
    if len(matches) > 1:
        raise BackupError("AWS returned duplicate backup identifiers")
    if not matches:
        return None
    item = matches[0]
    if item.get("DbiResourceId") != dbi or item.get("DBInstanceArn") != source_arn:
        raise BackupError("Backup source does not match")
    status = item.get("Status")
    if not isinstance(status, str) or not status:
        raise BackupError("Backup status is missing")
    return item


def inspect_or_delete(account, backup_arn, source_arn, dbi, *, execute=False, wait_seconds=120,
                      query=aws_json, clock=time.monotonic, sleep=time.sleep):
    region = validate_identity(account, backup_arn, source_arn, dbi)
    if not 1 <= wait_seconds <= 300:
        raise BackupError("Invalid wait limit")
    backup = find_exact(region, account, backup_arn, source_arn, dbi, query=query)
    if backup is None:
        return {"status": "not_found", "backup_arn": backup_arn, "region": region}, 2
    summary = {"status": backup["Status"], "backup_arn": backup_arn, "region": region,
               "source_dbi_resource_id": dbi, "source_arn": source_arn,
               "retention_days": backup.get("BackupRetentionPeriod"), "restore_window": backup.get("RestoreWindow")}
    if not execute:
        summary["mode"] = "preview"
        return summary, 0
    if backup["Status"].lower() != "retained":
        raise BackupError("Only retained backups may be deleted")
    # Revalidate immediately before deletion, including STS identity.
    current = find_exact(region, account, backup_arn, source_arn, dbi, query=query)
    if current is None or current["Status"].lower() != "retained":
        raise BackupError("Backup changed before deletion")
    query(["rds", "delete-db-instance-automated-backup", "--region", region,
           "--db-instance-automated-backups-arn", backup_arn])
    deadline = clock() + wait_seconds
    consecutive_absences = 0
    while clock() < deadline:
        remaining = find_exact(region, account, backup_arn, source_arn, dbi, query=query)
        if remaining is None:
            consecutive_absences += 1
            if consecutive_absences >= 2:
                summary.update(mode="delete", status="not_found_after_delete")
                return summary, 0
        else:
            consecutive_absences = 0
        sleep(min(5, max(0, deadline - clock())))
    summary.update(mode="delete", status="deletion_unconfirmed")
    return summary, 2


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--account", required=True, help="12-digit expected AWS account")
    parser.add_argument("--backup-arn", required=True, help="exact destination auto-backup ARN")
    parser.add_argument("--source-arn", required=True, help="exact source DB instance ARN")
    parser.add_argument("--source-dbi-resource-id", required=True, help="immutable source DB resource ID")
    parser.add_argument("--execute", action="store_true", help="irreversibly delete this retained backup")
    parser.add_argument("--wait-seconds", type=int, default=120)
    args = parser.parse_args(argv)
    try:
        result, code = inspect_or_delete(args.account, args.backup_arn, args.source_arn, args.source_dbi_resource_id,
                                         execute=args.execute, wait_seconds=args.wait_seconds)
        print(json.dumps(result, sort_keys=True, default=str))
        return code
    except (BackupError, OSError, subprocess.SubprocessError, ValueError):
        # CLI diagnostics may contain sensitive details. A failed delete request
        # can have an unknown outcome; never retry it automatically.
        print("Backup check stopped. Verify account, identity, region, permissions and status; if deletion was requested, its outcome may be unknown.", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
