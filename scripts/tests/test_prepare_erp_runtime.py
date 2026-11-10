import importlib.util
import json
import tempfile
import unittest
from pathlib import Path


module_path = Path(__file__).resolve().parents[1] / "prepare-erp-runtime.py"
spec = importlib.util.spec_from_file_location("prepare_erp_runtime", module_path)
runtime = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runtime)


class PrepareRuntimeTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.source = Path(self.directory.name) / "source.json"
        self.destination = Path(self.directory.name) / "private" / "erp.env"

    def write_secret(self, value):
        self.source.write_text(json.dumps(value), encoding="utf-8")

    def test_primary_preserves_values_and_removes_source(self):
        self.write_secret({"SECRET_KEY": "fake-test-value", "APP_ENV": "production"})
        runtime.prepare_runtime(self.source, self.destination)
        self.assertEqual(self.destination.read_text(encoding="utf-8"), "SECRET_KEY=fake-test-value\nAPP_ENV=production\n")
        self.assertFalse(self.source.exists())

    def test_regional_host_preserves_credentials_port_path_and_tls(self):
        url = "postgresql+psycopg://user:encoded%40password@primary.example:5432/andeslog?sslmode=verify-full"
        self.write_secret({"DATABASE_URL": url})
        runtime.prepare_runtime(self.source, self.destination, "replica.example")
        self.assertEqual(
            self.destination.read_text(encoding="utf-8"),
            "DATABASE_URL=postgresql+psycopg://user:encoded%40password@replica.example:5432/andeslog?sslmode=verify-full\n",
        )

    def test_rejects_invalid_hostname_and_keeps_source(self):
        self.write_secret({"DATABASE_URL": "postgresql://user:password@primary:5432/db?sslmode=verify-full"})
        with self.assertRaises(ValueError):
            runtime.prepare_runtime(self.source, self.destination, "attacker.example/extra")
        self.assertTrue(self.source.exists())
        self.assertFalse(self.destination.exists())

    def test_rejects_invalid_database_and_multiline_values(self):
        for secret in (
            {"DATABASE_URL": "sqlite:///local.db"},
            {"DATABASE_URL": "postgresql://host/db?sslmode=disable"},
            {"DATABASE_URL": "postgresql://host/db?sslmode=verify-full", "BAD": "x\ny"},
        ):
            with self.subTest(secret=secret):
                self.write_secret(secret)
                with self.assertRaises(ValueError):
                    runtime.prepare_runtime(self.source, self.destination, "replica.example")
                self.assertTrue(self.source.exists())
                self.assertFalse(self.destination.exists())


if __name__ == "__main__":
    unittest.main()
