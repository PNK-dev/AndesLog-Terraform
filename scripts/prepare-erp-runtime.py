#!/usr/bin/env python3
"""Render an ERP runtime secret locally, with an optional regional DB host.

The source is fetched by the instance role. Neither its value nor the rendered
environment is logged. A regional replica carries the primary DB hostname;
only the hostname is replaced so TLS verification and credentials remain intact.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from pathlib import Path
from urllib.parse import parse_qs, urlsplit, urlunsplit


def regional_database_url(value: str, hostname: str) -> str:
    if not re.fullmatch(r"[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?", hostname):
        raise ValueError("Invalid regional database hostname")
    try:
        parsed = urlsplit(value)
        port = parsed.port
        current_host = parsed.hostname
    except ValueError:
        raise ValueError("Invalid database URL") from None
    if (parsed.scheme not in {"postgresql", "postgresql+psycopg"} or not current_host or
            parse_qs(parsed.query).get("sslmode") != ["verify-full"]):
        raise ValueError("Invalid database URL")
    userinfo, separator, _ = parsed.netloc.rpartition("@")
    authority = (userinfo + separator if separator else "") + hostname
    if port is not None:
        authority += f":{port}"
    return urlunsplit((parsed.scheme, authority, parsed.path, parsed.query, parsed.fragment))


def prepare_runtime(source: Path, destination: Path, database_host: str = "") -> None:
    with source.open(encoding="utf-8") as handle:
        values = json.load(handle)
    if not isinstance(values, dict) or not values:
        raise ValueError("Runtime secret must be a non-empty JSON object")
    if database_host:
        if not isinstance(values.get("DATABASE_URL"), str):
            raise ValueError("Runtime secret lacks a database URL")
        values["DATABASE_URL"] = regional_database_url(values["DATABASE_URL"], database_host)
    lines = []
    for key, value in values.items():
        if not isinstance(key, str) or not re.fullmatch(r"[A-Z_][A-Z0-9_]*", key) or not isinstance(value, str):
            raise ValueError("Runtime secret has an invalid key or value")
        if any(character in value for character in ("\n", "\r", "\0")):
            raise ValueError("Runtime values cannot contain newline or NUL")
        lines.append(f"{key}={value}")
    destination.parent.mkdir(mode=0o750, parents=True, exist_ok=True)
    fd = os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    if hasattr(os, "fchmod"):
        os.fchmod(fd, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        handle.write("\n".join(lines) + "\n")
    source.unlink()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--destination", type=Path, required=True)
    parser.add_argument("--database-host", default="")
    args = parser.parse_args()
    try:
        prepare_runtime(args.source, args.destination, args.database_host)
    except (OSError, ValueError, TypeError, json.JSONDecodeError):
        # Exception messages can include secret values; never print them.
        print("Failed to prepare ERP runtime secret", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
