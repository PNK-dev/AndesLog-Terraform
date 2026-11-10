"""Safe argument checks for the RDS dump wrapper; no database is contacted."""

import os
import shutil
import subprocess
from pathlib import Path

import pytest


ROOT = Path(__file__).resolve().parents[2]
BASH = (r"C:\Program Files\Git\bin\bash.exe" if os.name == "nt" else shutil.which("bash"))


@pytest.mark.skipif(not BASH or not Path(BASH).is_file(), reason="Bash is required")
def test_dump_wrapper_rejects_relative_and_existing_paths(tmp_path):
    existing = tmp_path / "already-exists.dump"
    existing.write_bytes(b"do not overwrite")
    if os.name == "nt":
        cygpath = Path(BASH).parent.parent / "usr" / "bin" / "cygpath.exe"
        result = subprocess.run([str(cygpath), "-u", str(existing)], capture_output=True, text=True, check=True)
        absolute = result.stdout.strip()
    else:
        absolute = str(existing)
    for path in ("relative.dump", absolute):
        result = subprocess.run([BASH, "scripts/dump-rds.sh", path], cwd=ROOT, capture_output=True, text=True, timeout=10)
        assert result.returncode == 2
        assert "absolute path to a new file" in result.stderr
    assert existing.read_bytes() == b"do not overwrite"
