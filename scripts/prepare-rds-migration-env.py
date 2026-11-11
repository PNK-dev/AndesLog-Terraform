"""Create a short-lived environment for schema migrations as the DB owner."""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
from urllib.parse import quote, urlsplit


def create(master_file: Path, runtime_file: Path, output_file: Path, expected_host: str) -> None:
    master = json.loads(master_file.read_text(encoding="utf-8"))
    if not isinstance(master, dict) or not all(isinstance(master.get(x), str) and master[x] for x in ("username", "password")):
        raise ValueError("Invalid master secret")
    lines = runtime_file.read_text(encoding="utf-8").splitlines()
    matches = [line for line in lines if line.startswith("DATABASE_URL=")]
    if len(matches) != 1:
        raise ValueError("Expected one database URL")
    original = urlsplit(matches[0].partition("=")[2])
    if (original.scheme != "postgresql+psycopg" or original.hostname != expected_host or original.port != 5432
            or original.path != "/andeslog" or not original.query or original.fragment):
        raise ValueError("Unexpected database URL")
    from urllib.parse import parse_qs
    query = parse_qs(original.query, strict_parsing=True)
    if query.get("sslmode") != ["verify-full"] or query.get("sslrootcert") != ["/etc/ssl/certs/aws-rds-global-bundle.pem"]:
        raise ValueError("Database TLS verification is required")
    url = (f"postgresql+psycopg://{quote(master['username'], safe='')}:{quote(master['password'], safe='')}"
           f"@{expected_host}:5432/andeslog?{original.query}")
    output = "\n".join("DATABASE_URL=" + url if line.startswith("DATABASE_URL=") else line for line in lines) + "\n"
    descriptor = os.open(output_file, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as stream:
        stream.write(output)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--master", required=True, type=Path)
    parser.add_argument("--runtime", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--host", required=True)
    args = parser.parse_args()
    try:
        create(args.master, args.runtime, args.output, args.host)
    except (OSError, ValueError, TypeError, KeyError):
        raise SystemExit("Could not prepare the temporary migration environment.") from None


if __name__ == "__main__":
    main()
