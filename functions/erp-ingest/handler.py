"""Dependency-free validation helpers for the ERP event ingress function."""

from __future__ import annotations

import hashlib
import hmac
import json
from uuid import UUID

MAX_EVENT_BYTES = 256 * 1024


class InvalidEvent(ValueError):
    pass


def verify_and_parse(body: bytes, secret: str, signature: str) -> tuple[dict, str]:
    if not secret or len(secret) < 32:
        raise InvalidEvent("Integration authentication is not configured")
    if not body or len(body) > MAX_EVENT_BYTES:
        raise InvalidEvent("Event body size is invalid")
    expected = "sha256=" + hmac.new(secret.encode("utf-8"), body, hashlib.sha256).hexdigest()
    if not hmac.compare_digest(expected, signature or ""):
        raise InvalidEvent("Event signature is invalid")
    try:
        event = json.loads(body)
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise InvalidEvent("Event JSON is invalid") from exc
    if not isinstance(event, dict):
        raise InvalidEvent("Event must be a JSON object")
    try:
        event_id = str(UUID(event.get("id", "")))
    except (ValueError, TypeError, AttributeError) as exc:
        raise InvalidEvent("Event ID must be a UUID") from exc
    if event_id != event.get("id"):
        raise InvalidEvent("Event ID must be a canonical UUID")
    for key, max_length in (("event_type", 100), ("aggregate_type", 40), ("aggregate_id", 100)):
        value = event.get(key)
        if not isinstance(value, str) or not value or len(value) > max_length:
            raise InvalidEvent(f"Event field {key} is invalid")
    if not isinstance(event.get("payload"), dict):
        raise InvalidEvent("Event payload must be a JSON object")
    if event.get("source") != "andeslog-erp":
        raise InvalidEvent("Event source is invalid")
    return event, hashlib.sha256(body).hexdigest()
