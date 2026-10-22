#!/usr/bin/env python3
"""Small lab-only HTTP service for the AndesLog ALB target group."""

import json
import os
import re
import socket
import subprocess
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


DB_HOST = os.environ.get("DB_HOST", "10.10.21.10")
DB_NAME = os.environ.get("DB_NAME", "andeslog")
DB_USER = os.environ.get("DB_USER", "andeslog_app")
ALLOWED_STATUSES = {"pending", "in_transit", "delivered"}


def query(sql):
    password = os.environ.get("DB_PASSWORD", "")
    if not password:
        raise RuntimeError("DB_PASSWORD is not configured on this host")
    env = os.environ.copy()
    env["PGPASSWORD"] = password
    result = subprocess.run(
        ["/usr/bin/psql", "-X", "-qAt", "-v", "ON_ERROR_STOP=1", "-h", DB_HOST,
         "-U", DB_USER, "-d", DB_NAME, "-c", sql],
        check=True, capture_output=True, text=True, timeout=8, env=env,
    )
    return result.stdout.strip()


class Handler(BaseHTTPRequestHandler):
    server_version = "AndesLogLab/1.0"

    def send_json(self, status, payload):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/health":
            return self.send_json(200, {"status": "ok", "instance": socket.gethostname()})
        if self.path == "/":
            return self.send_json(200, {
                "service": "AndesLog tracking demo",
                "instance": socket.gethostname(),
                "routes": ["GET /health", "GET /orders", "POST /orders"],
            })
        if self.path == "/orders":
            try:
                rows = query("SELECT COALESCE(json_agg(row_to_json(o)), '[]'::json)::text FROM (SELECT id, order_ref, status, created_at FROM orders ORDER BY created_at DESC LIMIT 100) AS o")
                return self.send_json(200, json.loads(rows or "[]"))
            except (RuntimeError, subprocess.SubprocessError, OSError, json.JSONDecodeError):
                return self.send_json(503, {"error": "database is not ready or credentials are not configured"})
        return self.send_json(404, {"error": "not found"})

    def do_POST(self):
        if self.path != "/orders":
            return self.send_json(404, {"error": "not found"})
        try:
            length = int(self.headers.get("Content-Length", "0"))
            if length < 1 or length > 4096:
                return self.send_json(400, {"error": "invalid body length"})
            payload = json.loads(self.rfile.read(length))
            order_ref = payload.get("order_ref", "")
            status = payload.get("status", "pending")
            if not isinstance(order_ref, str) or not re.fullmatch(r"[A-Za-z0-9_-]{1,64}", order_ref):
                return self.send_json(400, {"error": "order_ref must contain 1-64 letters, digits, _ or -"})
            if status not in ALLOWED_STATUSES:
                return self.send_json(400, {"error": "unsupported order status"})
            # Restrictive validation plus SQL literal escaping keeps this demo's
            # psql-based example bounded without an additional Python package.
            sql = ("INSERT INTO orders (order_ref, status) VALUES ('" + order_ref.replace("'", "''") +
                   "', '" + status.replace("'", "''") +
                   "') RETURNING json_build_object('id', id, 'order_ref', order_ref, 'status', status, 'created_at', created_at)::text")
            result = query(sql)
            return self.send_json(201, json.loads(result))
        except (ValueError, TypeError, RuntimeError, subprocess.SubprocessError, OSError, json.JSONDecodeError):
            return self.send_json(503, {"error": "database is not ready or request is invalid"})

    def log_message(self, fmt, *args):
        # Keep the demo logs free from request bodies and credentials.
        print("%s - %s" % (self.address_string(), fmt % args), flush=True)


if __name__ == "__main__":
    ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
