import importlib.util
import json
import tempfile
import unittest
from pathlib import Path
from urllib.parse import urlsplit, unquote

spec = importlib.util.spec_from_file_location("prepare_migration", Path(__file__).parents[1] / "prepare-rds-migration-env.py")
migration = importlib.util.module_from_spec(spec)
spec.loader.exec_module(migration)


class MigrationEnvironmentTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.master = self.root / "master.json"
        self.runtime = self.root / "runtime.env"
        self.output = self.root / "migration.env"
        self.master.write_text(json.dumps({"username": "owner", "password": "local@secret:/!"}), encoding="utf-8")
        self.runtime.write_text("APP_ENV=development\nDATABASE_URL=postgresql+psycopg://andeslog_app:test@db.example:5432/andeslog?sslmode=verify-full&sslrootcert=%2Fetc%2Fssl%2Fcerts%2Faws-rds-global-bundle.pem\n", encoding="utf-8")

    def tearDown(self):
        self.tmp.cleanup()

    def test_owner_url_encodes_password_and_refuses_overwrite(self):
        migration.create(self.master, self.runtime, self.output, "db.example")
        lines = self.output.read_text(encoding="utf-8").splitlines()
        url = urlsplit(next(line.partition("=")[2] for line in lines if line.startswith("DATABASE_URL=")))
        self.assertEqual(unquote(url.password), "local@secret:/!")
        self.assertEqual(url.hostname, "db.example")
        with self.assertRaises(FileExistsError):
            migration.create(self.master, self.runtime, self.output, "db.example")

    def test_rejects_wrong_host_and_tls_without_creating_file(self):
        with self.assertRaises(ValueError):
            migration.create(self.master, self.runtime, self.output, "different.example")
        self.runtime.write_text(self.runtime.read_text(encoding="utf-8").replace("verify-full", "require"), encoding="utf-8")
        with self.assertRaises(ValueError):
            migration.create(self.master, self.runtime, self.output, "db.example")
        self.assertFalse(self.output.exists())


if __name__ == "__main__":
    unittest.main()
