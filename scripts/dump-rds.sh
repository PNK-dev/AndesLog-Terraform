#!/usr/bin/env bash
set -euo pipefail
# Restrict the dump from creation, rather than only after pg_dump finishes.
umask 077

if [[ $# -ne 1 ]]; then
  echo "Usage: sudo andeslog-rds-dump /path/to/output.dump" >&2
  exit 2
fi

output_file="$1"
if [[ "$output_file" != /* || -e "$output_file" || -L "$output_file" ]]; then
  echo "Output must be an absolute path to a new file." >&2
  exit 2
fi

python3 - "$output_file" <<'PY'
import os
import subprocess
import sys
from pathlib import Path
from urllib.parse import parse_qs, unquote, urlparse

settings = {}
for line in Path("/etc/andeslog-app/erp.env").read_text(encoding="utf-8").splitlines():
    if "=" in line and not line.lstrip().startswith("#"):
        key, value = line.split("=", 1)
        settings[key.strip()] = value.strip()

url = urlparse(settings["DATABASE_URL"])
options = parse_qs(url.query)
env = os.environ.copy()
env.update(
    {
        "PGHOST": url.hostname or "",
        "PGPORT": str(url.port or 5432),
        "PGUSER": unquote(url.username or ""),
        "PGPASSWORD": unquote(url.password or ""),
        "PGDATABASE": unquote(url.path.lstrip("/")),
        "PGSSLMODE": options.get("sslmode", ["verify-full"])[0],
        "PGSSLROOTCERT": unquote(
            options.get("sslrootcert", ["/etc/ssl/certs/aws-rds-global-bundle.pem"])[0]
        ),
    }
)
subprocess.run(
    ["pg_dump", "--format=custom", "--no-owner", "--file", sys.argv[1]],
    env=env,
    check=True,
)
PY

chown "${SUDO_USER:-ubuntu}:${SUDO_USER:-ubuntu}" "$output_file"
chmod 0600 "$output_file"
