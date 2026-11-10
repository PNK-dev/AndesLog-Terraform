"""Run checkpoint and ERP ingress tests against loopback Azurite.

Installs the official Azurite npm package in a temporary directory only.
Requires Node.js, npm, pytest and azure-storage-blob in the Python environment.
"""

import base64
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import time
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
NPM = shutil.which("npm.cmd" if os.name == "nt" else "npm")
NODE = shutil.which("node")
FLAGS = getattr(subprocess, "CREATE_NO_WINDOW", 0)


def main():
    if not NPM or not NODE:
        raise RuntimeError("Node.js and npm are required")
    with tempfile.TemporaryDirectory(prefix="andeslog-azurite-") as temp:
        root = Path(temp).resolve()
        if root.parent != Path(tempfile.gettempdir()).resolve() or not root.name.startswith("andeslog-azurite-"):
            raise RuntimeError("Unexpected temporary directory")
        env = os.environ.copy()
        env["npm_config_cache"] = str(root / "npm-cache")
        print("Preparing isolated Azurite installation...", flush=True)
        result = subprocess.run(
            [NPM, "install", "--prefix", str(root), "--no-audit", "--no-fund", "--omit=optional", "azurite@3.37.0"],
            stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True, timeout=120, env=env, creationflags=FLAGS,
        )
        if result.returncode:
            raise RuntimeError("Temporary Azurite installation failed: " + result.stderr[-1000:])
        print("Starting loopback-only Blob emulator...", flush=True)
        package = root / "node_modules" / "azurite"
        binary = package / json.loads((package / "package.json").read_text(encoding="utf-8"))["bin"]["azurite-blob"]
        with socket.socket() as sock:
            sock.bind(("127.0.0.1", 0))
            port = sock.getsockname()[1]
        account = "andeslogtest"
        key = base64.b64encode(os.urandom(32)).decode("ascii")
        env["AZURITE_ACCOUNTS"] = account + ":" + key
        env["ANDESLOG_AZURITE_CONNECTION_STRING"] = (
            f"DefaultEndpointsProtocol=http;AccountName={account};AccountKey={key};"
            f"BlobEndpoint=http://127.0.0.1:{port}/{account};"
        )
        server = subprocess.Popen(
            [NODE, str(binary), "--blobHost", "127.0.0.1", "--blobPort", str(port), "--location", str(root / "data"), "--silent", "--skipApiVersionCheck"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, env=env, creationflags=FLAGS,
        )
        try:
            deadline = time.monotonic() + 25
            while True:
                if server.poll() is not None:
                    raise RuntimeError("Azurite exited before becoming ready")
                try:
                    with socket.create_connection(("127.0.0.1", port), timeout=1):
                        break
                except OSError:
                    if time.monotonic() >= deadline:
                        raise RuntimeError("Azurite did not start on loopback")
                    time.sleep(0.25)
            result = subprocess.run(
                [sys.executable, "-m", "pytest", "-q",
                 str(ROOT / "functions" / "erp-ingest" / "test_files_dr_checkpoint_azurite.py"),
                 str(ROOT / "functions" / "erp-ingest" / "test_outbox_azurite.py")],
                cwd=ROOT, env=env, timeout=60, creationflags=FLAGS, capture_output=True, text=True,
            )
            print(result.stdout, end="", flush=True)
            if result.stderr:
                print(result.stderr, end="", file=sys.stderr, flush=True)
            return result.returncode
        finally:
            server.terminate()
            try:
                server.wait(timeout=10)
            except subprocess.TimeoutExpired:
                server.kill()
                server.wait(timeout=10)


if __name__ == "__main__":
    raise SystemExit(main())
