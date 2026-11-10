import hashlib
import hmac
import json
from uuid import UUID, uuid4, uuid5

import pytest

from handler import InvalidEvent, verify_and_parse


def _request(secret=None):
    secret = secret or "a-long-test-secret-with-at-least-thirty-two-characters"
    event = {
        "id": str(uuid4()),
        "event_type": "erp.order.created",
        "occurred_at": "2026-11-06T12:00:00+00:00",
        "source": "andeslog-erp",
        "aggregate_type": "sales_order",
        "aggregate_id": "42",
        "payload": {"number": "SO-42"},
    }
    body = json.dumps(event, separators=(",", ":"), sort_keys=True).encode()
    signature = "sha256=" + hmac.new(secret.encode(), body, hashlib.sha256).hexdigest()
    return body, secret, signature, event


def test_valid_signed_event_is_parsed():
    body, secret, signature, expected = _request()
    event, digest = verify_and_parse(body, secret, signature)
    assert event == expected
    assert digest == hashlib.sha256(body).hexdigest()


def test_signed_inventory_event_accepts_deterministic_uuid():
    _body, secret, _signature, event = _request()
    event["id"] = str(uuid5(UUID("2d59705a-778b-4522-993b-896e259ac806"), str(uuid4())))
    event["event_type"] = "erp.inventory.movement_recorded"
    body = json.dumps(event, separators=(",", ":"), sort_keys=True).encode()
    signature = "sha256=" + hmac.new(secret.encode(), body, hashlib.sha256).hexdigest()
    actual, _digest = verify_and_parse(body, secret, signature)
    assert actual["id"] == event["id"]


def test_invalid_signature_is_rejected():
    body, secret, _signature, _event = _request()
    with pytest.raises(InvalidEvent, match="signature"):
        verify_and_parse(body, secret, "sha256=" + "0" * 64)


def test_oversized_event_is_rejected_before_json_parsing():
    with pytest.raises(InvalidEvent, match="size"):
        verify_and_parse(b"x" * (256 * 1024 + 1), "secret" * 8, "")
