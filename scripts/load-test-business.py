#!/usr/bin/env python3
"""Prueba acotada y de solo lectura con sesiones reales del ERP AndesLog."""
from __future__ import annotations

import argparse
import concurrent.futures
import getpass
import http.cookiejar
import json
import math
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from html.parser import HTMLParser
from pathlib import Path

ROUTES = ("/", "/warehouses", "/inventory", "/orders", "/transport", "/api/v1/summary")
SUMMARY_KEYS = {"warehouses", "products", "customers", "open_orders", "active_trips"}


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


class TokenParser(HTMLParser):
    def __init__(self):
        super().__init__()
        self.token = None

    def handle_starttag(self, tag, attrs):
        fields = dict(attrs)
        if tag == "input" and fields.get("name") == "csrf_token":
            self.token = fields.get("value")


def base_url(value: str, allow_http: bool) -> str:
    parsed = urllib.parse.urlsplit(value)
    if (parsed.scheme not in {"http", "https"} or not parsed.hostname or parsed.username or parsed.password
            or parsed.path not in {"", "/"} or parsed.query or parsed.fragment):
        raise ValueError("Indica solo una URL base HTTP(S), sin ruta ni credenciales.")
    if parsed.scheme == "http" and parsed.hostname not in {"localhost", "127.0.0.1", "::1"} and not allow_http:
        raise ValueError("HTTP remoto expone la contraseña; usa HTTPS o acepta el laboratorio con --allow-http.")
    return f"{parsed.scheme}://{parsed.netloc}"


def open_response(opener, request, timeout):
    try:
        with opener.open(request, timeout=timeout) as response:
            return response.status, response.headers, response.read(2 * 1024 * 1024 + 1)
    except urllib.error.HTTPError as error:
        with error:
            return error.code, error.headers, error.read(4096)


def login(base, username, password, timeout):
    opener = urllib.request.build_opener(NoRedirect(), urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()))
    status, _, body = open_response(opener, base + "/login", timeout)
    if status != 200:
        raise RuntimeError(f"La página de acceso respondió HTTP {status}.")
    parser = TokenParser()
    parser.feed(body.decode("utf-8", errors="strict"))
    if not parser.token:
        raise RuntimeError("No se encontró el token CSRF de acceso.")
    payload = urllib.parse.urlencode({"username": username, "password": password, "csrf_token": parser.token}).encode()
    request = urllib.request.Request(base + "/login", data=payload, method="POST")
    status, headers, _ = open_response(opener, request, timeout)
    if status not in {302, 303} or headers.get("Location") != "/":
        raise RuntimeError("El ERP no aceptó la sesión de prueba.")
    check(opener, base, "/api/v1/summary", timeout)
    return opener


def check(opener, base, route, timeout):
    start = time.monotonic()
    status, _, body = open_response(opener, base + route, timeout)
    elapsed = (time.monotonic() - start) * 1000
    if status != 200 or len(body) > 2 * 1024 * 1024:
        raise RuntimeError(f"{route}: respuesta HTTP {status} o cuerpo demasiado grande.")
    if route == "/api/v1/summary":
        try:
            values = json.loads(body)
            if not isinstance(values, dict) or not SUMMARY_KEYS.issubset(values):
                raise ValueError("incomplete")
        except (ValueError, UnicodeError):
            raise RuntimeError("La respuesta autenticada de resumen es inválida.") from None
    return elapsed


def percentile(values, p):
    values = sorted(values)
    return values[max(0, math.ceil(len(values) * p) - 1)]


def bounded_int(low, high):
    def parse(value):
        try:
            number = int(value)
        except ValueError:
            raise argparse.ArgumentTypeError("Debe ser un entero.") from None
        if not low <= number <= high:
            raise argparse.ArgumentTypeError(f"Debe estar entre {low} y {high}.")
        return number
    return parse


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--url", required=True, help="URL base del ERP, preferentemente HTTPS")
    parser.add_argument("--username", default="admin")
    parser.add_argument("--secret-file", type=Path, help="Archivo local .secret con credenciales iniciales")
    parser.add_argument("--allow-http", action="store_true", help="Aceptar HTTP remoto de laboratorio")
    parser.add_argument("--users", type=bounded_int(1, 10), default=3, help="Sesiones virtuales, máximo 10")
    parser.add_argument("--requests-per-user", type=bounded_int(1, 30), default=12)
    parser.add_argument("--timeout", type=bounded_int(1, 30), default=10)
    parser.add_argument("--max-latency-ms", type=bounded_int(100, 30000), default=5000)
    args = parser.parse_args(argv)
    try:
        base = base_url(args.url, args.allow_http)
        if args.secret_file:
            credentials = {}
            for line in args.secret_file.read_text(encoding="utf-8-sig").splitlines():
                name, sep, value = line.partition("=")
                if sep and name in {"BOOTSTRAP_ADMIN_USERNAME", "BOOTSTRAP_ADMIN_PASSWORD"}:
                    if name in credentials:
                        raise ValueError("El archivo contiene una credencial duplicada.")
                    credentials[name] = value
            username = credentials.get("BOOTSTRAP_ADMIN_USERNAME", "")
            password = credentials.get("BOOTSTRAP_ADMIN_PASSWORD", "")
        else:
            username = args.username
            password = getpass.getpass("Contraseña del usuario ERP: ")
        if not username or not password:
            raise ValueError("Faltan credenciales del ERP.")
        if base.startswith("http://") and args.allow_http:
            print("AVISO: HTTP remoto no cifra las credenciales de esta prueba.")
        sessions = [login(base, username, password, args.timeout) for _ in range(args.users)]
        del password
        print(f"Sesiones autenticadas: {len(sessions)}. Máximo {args.users * args.requests_per_user} GET; sin escrituras de negocio.")
        latencies = []
        start = time.monotonic()
        with concurrent.futures.ThreadPoolExecutor(max_workers=args.users) as executor:
            for number in range(args.requests_per_user):
                route = ROUTES[number % len(ROUTES)]
                futures = [executor.submit(check, session, base, route, args.timeout) for session in sessions]
                results = [future.result() for future in futures]
                latencies.extend(results)
                if max(results) > args.max_latency_ms:
                    raise RuntimeError(f"Se superó el límite de latencia en {route}; prueba detenida.")
        duration = time.monotonic() - start
        print(f"GET correctos: {len(latencies)}; errores: 0; RPS: {len(latencies) / duration:.2f}; "
              f"p50: {percentile(latencies, .50):.1f} ms; p95: {percentile(latencies, .95):.1f} ms; "
              f"p99: {percentile(latencies, .99):.1f} ms; máximo: {max(latencies):.1f} ms.")
        print("El ensayo no demuestra capacidad de 100, 500, 1000 o 5000 usuarios ni cobertura de escrituras.")
        return 0
    except (OSError, ValueError, RuntimeError, UnicodeError, urllib.error.URLError) as error:
        print(f"Prueba detenida: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
