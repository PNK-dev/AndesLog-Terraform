import copy
import importlib.util
from pathlib import Path

import pytest

spec = importlib.util.spec_from_file_location("verify_erp_restore", Path(__file__).resolve().parents[1] / "verify_erp_restore.py")
verifier = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verifier)


def reference():
    tables = {name: {"rows": 0, "sha256": "a" * 64} for name in verifier.TABLES}
    tables["users"]["rows"] = 1
    return {"version": 1, "created_utc": "2026-11-10T00:00:00Z", "migration_revision": "abc123",
            "database": {"host": "primary.example", "port": 5432, "name": "andeslog", "postgres_major": 18},
            "tables": tables}


def test_matching_reference_requires_distinct_database():
    expected = reference()
    actual = copy.deepcopy(expected)
    actual["database"]["host"] = "restore.example"
    assert verifier.compare(expected, actual) == {"matching": True, "schema_matches": True,
                                                 "tables_checked": len(verifier.TABLES), "different_tables": []}
    with pytest.raises(verifier.VerificationError, match="same database"):
        verifier.compare(expected, expected)


def test_changed_content_and_schema_are_both_reported():
    expected = reference()
    actual = copy.deepcopy(expected)
    actual["database"]["host"] = "restore.example"
    actual["tables"]["inventory"]["sha256"] = "b" * 64
    actual["migration_revision"] = "other"
    result = verifier.compare(expected, actual)
    assert not result["matching"] and not result["schema_matches"] and result["different_tables"] == ["inventory"]


def test_different_postgres_major_never_claims_a_match():
    expected = reference()
    actual = copy.deepcopy(expected)
    actual["database"]["host"] = "restore.example"
    actual["database"]["postgres_major"] = 17
    with pytest.raises(verifier.VerificationError, match="major"):
        verifier.compare(expected, actual)


@pytest.mark.parametrize("change", [
    lambda m: m.update(version=True),
    lambda m: m["tables"].pop("orders"),
    lambda m: m["tables"]["users"].update(rows=0),
    lambda m: m["tables"]["inventory"].update(sha256="bad"),
    lambda m: m["tables"]["inventory"].update(rows=True),
])
def test_incomplete_or_invalid_reference_is_rejected(change):
    value = reference()
    change(value)
    with pytest.raises(verifier.VerificationError):
        verifier.validate_manifest(value)


def test_reference_is_exclusively_created_and_reloaded(tmp_path):
    path = tmp_path / "baseline.json"
    expected = reference()
    verifier.write_manifest(path, expected)
    assert verifier.read_manifest(path) == expected
    with pytest.raises(FileExistsError):
        verifier.write_manifest(path, expected)
    assert verifier.read_manifest(path) == expected


def test_invalid_or_large_reference_fails_closed(tmp_path):
    path = tmp_path / "baseline.json"
    path.write_text("not json", encoding="utf-8")
    with pytest.raises(verifier.VerificationError):
        verifier.read_manifest(path)
    path.write_bytes(b"x" * (verifier.MAX_MANIFEST_BYTES + 1))
    with pytest.raises(verifier.VerificationError, match="too large"):
        verifier.read_manifest(path)
