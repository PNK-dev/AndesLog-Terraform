"""Integration test against two disposable, loopback-only PostgreSQL clusters.

Requires psycopg and local PostgreSQL server binaries. No cloud service is used.
"""

import importlib.util
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path

try:
    import psycopg
except ImportError:
    psycopg = None


ROOT = Path(__file__).resolve().parents[2]
PROBE_PATH = ROOT / "scripts" / "rds-replication-probe.py"
WITNESS_PATH = ROOT / "scripts" / "rds-failover-witness.py"
ARCHIVE_AUDIT_PATH = ROOT / "scripts" / "reconcile-erp-archive.py"
PG_BIN = Path(os.environ.get("ANDESLOG_TEST_PG_BIN", r"C:\Program Files\PostgreSQL\18\bin"))
if os.name != "nt" and not os.environ.get("ANDESLOG_TEST_PG_BIN"):
    path = shutil.which("pg_ctl")
    PG_BIN = Path(path).parent if path else Path("/nonexistent")


def binary(name):
    return PG_BIN / (name + (".exe" if os.name == "nt" else ""))


@unittest.skipUnless(psycopg and all(binary(x).is_file() for x in ("initdb", "pg_ctl", "pg_basebackup")), "PostgreSQL binaries and psycopg are required")
class LocalReplicationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        spec = importlib.util.spec_from_file_location("rds_replication_probe", PROBE_PATH)
        cls.probe_module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.probe_module)
        witness_spec = importlib.util.spec_from_file_location("rds_failover_witness", WITNESS_PATH)
        cls.witness_module = importlib.util.module_from_spec(witness_spec)
        witness_spec.loader.exec_module(cls.witness_module)
        audit_spec = importlib.util.spec_from_file_location("reconcile_erp_archive", ARCHIVE_AUDIT_PATH)
        cls.archive_audit = importlib.util.module_from_spec(audit_spec)
        audit_spec.loader.exec_module(cls.archive_audit)
        cls.temp = tempfile.TemporaryDirectory(prefix="andeslog-pg-replication-")
        cls.root = Path(cls.temp.name).resolve()
        cls.primary_dir = cls.root / "primary"
        cls.replica_dir = cls.root / "replica"
        cls.primary_started = False
        cls.replica_started = False
        sockets = [socket.socket(), socket.socket()]
        try:
            for sock in sockets:
                sock.bind(("127.0.0.1", 0))
            cls.primary_port, cls.replica_port = [sock.getsockname()[1] for sock in sockets]
        finally:
            for sock in sockets:
                sock.close()
        try:
            cls.run_pg("initdb", "-D", str(cls.primary_dir), "--username=postgres", "--auth=trust", "--no-locale", "--encoding=UTF8")
            cls.start_cluster(cls.primary_dir, cls.primary_port, "primary.log")
            cls.primary_started = True
            with cls.connect(cls.primary_port) as primary:
                primary.execute((ROOT / "scripts" / "sql" / "create-replication-probe.sql").read_text(encoding="utf-8"))
                primary.execute("CREATE ROLE andeslog_probe_test LOGIN")
                primary.execute("GRANT SELECT, INSERT ON public.andeslog_replication_probes TO andeslog_probe_test")
            cls.run_pg("pg_basebackup", "-h", "127.0.0.1", "-p", str(cls.primary_port), "-U", "postgres", "-D", str(cls.replica_dir), "-R", "-X", "stream", "--no-password")
            cls.start_cluster(cls.replica_dir, cls.replica_port, "replica.log")
            cls.replica_started = True
        except Exception:
            cls.stop_and_cleanup()
            raise

    @classmethod
    def run_pg(cls, name, *args):
        # The background postgres process can inherit captured pipes on Windows,
        # leaving subprocess.run waiting for EOF after pg_ctl has exited.
        starting_server = name == "pg_ctl" and args and args[0] == "start"
        result = subprocess.run(
            [str(binary(name)), *args],
            stdout=subprocess.DEVNULL if starting_server else subprocess.PIPE,
            stderr=subprocess.DEVNULL if starting_server else subprocess.PIPE,
            text=True, timeout=45, creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
        )
        if result.returncode:
            raise RuntimeError(f"{name} failed: {(result.stderr or '')[-1200:]} {(result.stdout or '')[-1200:]}")

    @classmethod
    def start_cluster(cls, directory, port, log_name):
        cls.run_pg("pg_ctl", "start", "-D", str(directory), "-l", str(cls.root / log_name), "-w", "-t", "30", "-o", f"-h 127.0.0.1 -p {port}")

    @classmethod
    def connect(cls, port, user="postgres"):
        return psycopg.connect(host="127.0.0.1", port=port, dbname="postgres", user=user, sslmode="disable", connect_timeout=5, autocommit=True)

    @classmethod
    def stop_and_cleanup(cls):
        if cls.root.parent != Path(tempfile.gettempdir()).resolve() or not cls.root.name.startswith("andeslog-pg-replication-"):
            raise RuntimeError("Unexpected temporary cluster path; refusing cleanup")
        for directory in (cls.replica_dir, cls.primary_dir):
            if (directory / "postmaster.pid").exists():
                result = subprocess.run([str(binary("pg_ctl")), "status", "-D", str(directory)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10, creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
                if result.returncode == 0:
                    cls.run_pg("pg_ctl", "stop", "-D", str(directory), "-m", "immediate", "-w", "-t", "30")
                elif result.returncode != 3:
                    raise RuntimeError("Could not verify that the temporary server stopped")
        # The only recursive cleanup target is the verified directory created above.
        cls.temp.cleanup()

    @classmethod
    def tearDownClass(cls):
        cls.stop_and_cleanup()

    def test_marker_is_committed_and_replayed(self):
        with self.connect(self.primary_port, "andeslog_probe_test") as primary, self.connect(self.replica_port, "andeslog_probe_test") as replica:
            result = self.probe_module.probe(primary, replica, timeout=10, interval=0.1)
            self.assertTrue(result["observed"])
            self.assertTrue(result["within_timeout"])
            self.assertGreaterEqual(result["commit_to_observation_seconds"], 0)
            self.assertEqual(replica.execute("SELECT count(*) FROM public.andeslog_replication_probes WHERE probe_id=%s", (result["probe_id"],)).fetchone()[0], 1)
            with self.assertRaises(psycopg.errors.InsufficientPrivilege):
                primary.execute("DELETE FROM public.andeslog_replication_probes WHERE probe_id=%s", (result["probe_id"],))

    def test_erp_readiness_rejects_a_real_postgresql_replica(self):
        # The ERP repository may be cloned under either supported sibling name.
        erp_root = next((root for root in (ROOT.parent / "ERP-APP", ROOT.parent / "AndesLog-ERP")
                         if (root / "app" / "__init__.py").is_file()), None)
        if erp_root is None:
            self.skipTest("Sibling ERP repository is required")
        sys.path.insert(0, str(erp_root))
        try:
            from app import create_app
            from app.models import db
            apps = [create_app({"TESTING": True, "SECRET_KEY": "local-test-only",
                                "SQLALCHEMY_DATABASE_URI": f"postgresql+psycopg://postgres@127.0.0.1:{port}/postgres"})
                    for port in (self.primary_port, self.replica_port)]
            apps.append(create_app({"TESTING": True, "SECRET_KEY": "local-test-only",
                "SQLALCHEMY_DATABASE_URI": f"postgresql+psycopg://postgres@127.0.0.1:{self.primary_port}/postgres?options=-c%20default_transaction_read_only%3Don"}))
            try:
                primary = apps[0].test_client().get("/api/health/ready")
                replica = apps[1].test_client().get("/api/health/ready")
                self.assertEqual(primary.status_code, 200)
                self.assertEqual(replica.status_code, 503)
                self.assertEqual(replica.json["database"], "read_only")
                self.assertEqual(apps[1].test_client().get("/api/health/live").status_code, 200)
                readonly_session = apps[2].test_client().get("/api/health/ready")
                self.assertEqual(readonly_session.status_code, 503)
                self.assertEqual(readonly_session.json["database"], "read_only")
            finally:
                for app in apps:
                    with app.app_context():
                        db.session.remove()
                        db.engine.dispose()
        finally:
            sys.path.remove(str(erp_root))

    def test_archive_audit_selects_delivered_rows_in_read_only_snapshot(self):
        import uuid
        from types import SimpleNamespace
        from psycopg.rows import dict_row
        from psycopg.types.json import Json

        event_id = str(uuid.uuid4())
        pending_id = str(uuid.uuid4())
        secondary_id = str(uuid.uuid4())
        created = __import__("datetime").datetime(2026, 11, 10, 12, 0)
        row = {"id": event_id, "event_type": "erp.test", "aggregate_type": "test", "aggregate_id": "1",
               "payload": {"demo": True}, "created_at": created}
        with self.connect(self.primary_port) as primary:
            primary.execute("CREATE TABLE public.outbox_event (id text PRIMARY KEY, event_type text, aggregate_type text, aggregate_id text, payload json, created_at timestamp, status text, delivered_destination text)")
            primary.execute("INSERT INTO public.outbox_event VALUES (%s,%s,%s,%s,%s,%s,%s,%s),(%s,%s,%s,%s,%s,%s,%s,%s),(%s,%s,%s,%s,%s,%s,%s,%s)",
                            (event_id, "erp.test", "test", "1", Json({"demo": True}), created, "delivered", None,
                             pending_id, "erp.test", "test", "2", Json({"demo": False}), created, "pending", None,
                             secondary_id, "erp.test", "test", "1", Json({"demo": True}), created, "delivered", "secondary"))
            primary.execute("GRANT SELECT ON public.outbox_event TO andeslog_probe_test")
        expected = {event_id: self.archive_audit.canonical_event(row)[1],
                    secondary_id: self.archive_audit.canonical_event(dict(row, id=secondary_id))[1]}

        class FakeContainer:
            def get_blob_client(inner, name):
                body = expected[name.removesuffix(".json")]
                return SimpleNamespace(get_blob_properties=lambda: SimpleNamespace(etag='"test"', size=len(body)),
                                       download_blob=lambda **_: SimpleNamespace(readall=lambda: body))

        with psycopg.connect(host="127.0.0.1", port=self.primary_port, dbname="postgres", user="andeslog_probe_test",
                             sslmode="disable", autocommit=False, row_factory=dict_row) as connection:
            result, issues = self.archive_audit.audit_database(connection, FakeContainer(), limit=10, deadline=time.monotonic() + 10)
            self.assertEqual(result["checked"], 1)
            self.assertEqual(result["matching"], 1)
            self.assertFalse(result["database_is_replica"])
            self.assertEqual(result["delivery_source"], "primary")
            self.assertEqual(issues, [])
            with self.assertRaises(psycopg.errors.ReadOnlySqlTransaction):
                connection.execute("INSERT INTO public.andeslog_replication_probes (probe_id) VALUES (%s)", (uuid.uuid4(),))
        with psycopg.connect(host="127.0.0.1", port=self.primary_port, dbname="postgres", user="andeslog_probe_test",
                             sslmode="disable", autocommit=False, row_factory=dict_row) as connection:
            result, issues = self.archive_audit.audit_database(connection, FakeContainer(), limit=10,
                                                                deadline=time.monotonic() + 10, delivery_source="secondary")
            self.assertEqual(result["checked"], 1)
            self.assertEqual(result["matching"], 1)
            self.assertEqual(result["delivery_source"], "secondary")
            self.assertEqual(issues, [])
        with psycopg.connect(host="127.0.0.1", port=self.primary_port, dbname="postgres", user="andeslog_probe_test",
                             sslmode="disable", autocommit=False, row_factory=dict_row) as connection:
            result, issues = self.archive_audit.audit_database(connection, FakeContainer(), limit=10,
                deadline=time.monotonic() + 10, delivery_source="secondary", comparison_container=FakeContainer())
            self.assertEqual(result["checked"], 1)
            self.assertEqual(result["already_present"], 1)
            self.assertEqual(result["comparison_mode"], "failback_preview")
            self.assertEqual(issues, [])
            with self.assertRaises(psycopg.errors.ReadOnlySqlTransaction):
                connection.execute("INSERT INTO public.andeslog_replication_probes (probe_id) VALUES (%s)", (uuid.uuid4(),))
        sys.path.insert(0, str(ROOT / "scripts"))
        import erp_failback_execute as replay_executor
        with psycopg.connect(host="127.0.0.1", port=self.primary_port, dbname="postgres", user="andeslog_probe_test",
                             sslmode="disable", autocommit=False, row_factory=dict_row) as connection:
            rows = replay_executor.read_confirmed_batch(connection, expected_host="127.0.0.1", limit=10)
            self.assertEqual([row["id"] for row in rows], [secondary_id])
            with self.assertRaises(psycopg.errors.ReadOnlySqlTransaction):
                connection.execute("INSERT INTO public.andeslog_replication_probes (probe_id) VALUES (%s)", (uuid.uuid4(),))
        with psycopg.connect(host="127.0.0.1", port=self.primary_port, dbname="postgres", user="andeslog_probe_test",
                             sslmode="disable", autocommit=False, row_factory=dict_row) as connection:
            with self.assertRaises(replay_executor.replay.audit.AuditError):
                replay_executor.read_confirmed_batch(connection, expected_host="wrong.example", limit=10)
        with psycopg.connect(host="127.0.0.1", port=self.replica_port, dbname="postgres", user="andeslog_probe_test",
                             sslmode="disable", autocommit=False, row_factory=dict_row) as connection:
            with self.assertRaises(replay_executor.replay.audit.AuditError):
                replay_executor.read_confirmed_batch(connection, expected_host="127.0.0.1", limit=10)

    def test_paused_replay_times_out_then_catches_up(self):
        with self.connect(self.primary_port) as primary, self.connect(self.replica_port) as replica:
            replica.execute("SELECT pg_wal_replay_pause()")
            try:
                deadline = time.monotonic() + 10
                while replica.execute("SELECT pg_get_wal_replay_pause_state()").fetchone()[0] != "paused":
                    if time.monotonic() >= deadline:
                        self.fail("Replica did not pause")
                    time.sleep(0.1)
                result = self.probe_module.probe(primary, replica, timeout=1, interval=0.1)
                self.assertFalse(result["observed"])
                self.assertFalse(result["within_timeout"])
            finally:
                replica.execute("SELECT pg_wal_replay_resume()")
            deadline = time.monotonic() + 10
            while replica.execute("SELECT count(*) FROM public.andeslog_replication_probes WHERE probe_id=%s", (result["probe_id"],)).fetchone()[0] != 1:
                if time.monotonic() >= deadline:
                    self.fail("Replica did not catch up")
                time.sleep(0.1)

    def test_paused_witness_detects_missing_acknowledged_writes(self):
        journal = self.root / "paused-witness.jsonl"
        with self.connect(self.replica_port) as replica:
            replica.execute("SELECT pg_wal_replay_pause()")
            try:
                deadline = time.monotonic() + 10
                while replica.execute("SELECT pg_get_wal_replay_pause_state()").fetchone()[0] != "paused":
                    if time.monotonic() >= deadline:
                        self.fail("Replica did not pause")
                    time.sleep(0.1)
                self.witness_module.record(lambda: self.connect(self.primary_port, "andeslog_probe_test"), journal, 2, 0.1, sleep=lambda _: None)
                result = self.witness_module.verify(replica, journal, "replica")
                self.assertEqual(result["confirmed"], 2)
                self.assertEqual(result["confirmed_missing"], 2)
                self.assertFalse(result["all_confirmed_present"])
            finally:
                replica.execute("SELECT pg_wal_replay_resume()")
            deadline = time.monotonic() + 10
            while not self.witness_module.verify(replica, journal, "replica")["all_confirmed_present"]:
                if time.monotonic() >= deadline:
                    self.fail("Replica did not catch up")
                time.sleep(0.1)

    def test_rejects_two_writers_before_inserting(self):
        with self.connect(self.primary_port) as primary, self.connect(self.primary_port) as other:
            before = primary.execute("SELECT count(*) FROM public.andeslog_replication_probes").fetchone()[0]
            with self.assertRaises(self.probe_module.ProbeError):
                self.probe_module.probe(primary, other, timeout=2, interval=0.1)
            after = primary.execute("SELECT count(*) FROM public.andeslog_replication_probes").fetchone()[0]
            self.assertEqual(before, after)

    def test_lost_commit_response_is_uncertain_even_if_row_exists(self):
        journal = self.root / "lost-commit-response.jsonl"

        class LostResponseConnection:
            def __init__(inner):
                inner.connection = self.connect(self.primary_port, "andeslog_probe_test")
                inner.autocommit = True

            def execute(inner, *args):
                return inner.connection.execute(*args)

            def transaction(inner):
                tx = inner.connection.transaction()

                class LostResponse:
                    def __enter__(nested):
                        return tx.__enter__()

                    def __exit__(nested, exc_type, exc, tb):
                        result = tx.__exit__(exc_type, exc, tb)
                        if exc_type is None:
                            raise psycopg.OperationalError("simulated lost commit response")
                        return result

                return LostResponse()

            def close(inner):
                inner.connection.close()

        recorded = self.witness_module.record(LostResponseConnection, journal, 1, 0.1, sleep=lambda _: None)
        self.assertEqual(recorded, {"confirmed": 0, "uncertain": 1})
        with self.connect(self.primary_port, "andeslog_probe_test") as primary:
            result = self.witness_module.verify(primary, journal, "primary")
        self.assertEqual(result["uncertain_present"], 1)
        self.assertFalse(result["all_confirmed_present"])

    def test_incomplete_and_malformed_witness_journals_fail_closed(self):
        import uuid

        marker, run_id = str(uuid.uuid4()), str(uuid.uuid4())
        journal = self.root / "incomplete-witness.jsonl"
        with journal.open("w", encoding="utf-8") as stream:
            self.witness_module.write_event(stream, "start", run_id)
            self.witness_module.write_event(stream, "intent", marker)
        markers, closed = self.witness_module.read_journal(journal)
        self.assertFalse(closed)
        self.assertEqual(markers[marker], "unknown")
        with journal.open("w", encoding="utf-8") as stream:
            self.witness_module.write_event(stream, "start", run_id)
            self.witness_module.write_event(stream, "ack", marker)
        with self.assertRaises(self.witness_module.WitnessError):
            self.witness_module.read_journal(journal)

    def test_rejects_connections_without_autocommit(self):
        with self.connect(self.primary_port) as primary, self.connect(self.replica_port) as replica:
            primary.autocommit = False
            with self.assertRaises(self.probe_module.ProbeError):
                self.probe_module.probe(primary, replica, timeout=2, interval=0.1)

    def test_marker_observed_after_deadline_is_not_success(self):
        with self.connect(self.primary_port) as primary, self.connect(self.replica_port) as replica:
            calls = 0

            def clock():
                nonlocal calls
                calls += 1
                if calls == 2:
                    deadline = time.monotonic() + 5
                    while primary.execute("SELECT count(*) FROM public.andeslog_replication_probes").fetchone()[0] != replica.execute("SELECT count(*) FROM public.andeslog_replication_probes").fetchone()[0]:
                        if time.monotonic() >= deadline:
                            self.fail("Replica did not catch up")
                        time.sleep(0.05)
                return (0.0, 0.1, 2.0)[calls - 1]

            result = self.probe_module.probe(primary, replica, timeout=1, interval=0.1, clock=clock)
            self.assertTrue(result["observed"])
            self.assertFalse(result["within_timeout"])

    def test_z_promoted_replica_is_rejected_as_probe_target(self):
        journal = self.root / "failover-witness.jsonl"
        calls = 0

        def connect_with_one_unknown():
            nonlocal calls
            calls += 1
            if calls == 2:
                raise psycopg.OperationalError("synthetic lost connection")
            return self.connect(self.primary_port, "andeslog_probe_test")

        self.witness_module.record(connect_with_one_unknown, journal, 3, 0.1, sleep=lambda _: None)
        with self.connect(self.primary_port) as primary, self.connect(self.replica_port) as replica:
            result = self.probe_module.probe(primary, replica, timeout=10, interval=0.1)
            deadline = time.monotonic() + 10
            while not self.witness_module.verify(replica, journal, "replica")["all_confirmed_present"]:
                if time.monotonic() >= deadline:
                    self.fail("Witness markers did not reach replica")
                time.sleep(0.1)

        # Prepare a real ERP database on the disposable local primary. Wait for
        # the schema and seed records before introducing replication isolation.
        erp_root = next((root for root in (ROOT.parent / "ERP-APP", ROOT.parent / "AndesLog-ERP")
                         if (root / "app" / "__init__.py").is_file()), None)
        if erp_root is None:
            self.fail("The sibling ERP project is required for the business failover test")
        sys.path.insert(0, str(erp_root))
        from app import create_app
        from app.models import InventoryBalance, OutboxEvent, Product, User, Warehouse, db
        from app.outbox_worker import serialize_event
        with self.connect(self.primary_port) as primary:
            primary.execute("CREATE DATABASE andeslog_business_test")
        erp_app = create_app({"TESTING": True, "SECRET_KEY": "local-business-failover-test",
            "WTF_CSRF_ENABLED": False, "SESSION_COOKIE_SECURE": False,
            "SQLALCHEMY_DATABASE_URI": f"postgresql+psycopg://postgres@127.0.0.1:{self.primary_port}/andeslog_business_test"})
        with erp_app.app_context():
            db.create_all()
            user = User(username="failover-test", role="admin")
            user.set_password("local-business-test-only")
            warehouse = Warehouse(code="TEST-HA", name="Laboratorio", city="Lima")
            product = Product(sku="HA-001", name="Producto de prueba", unit="unidad")
            db.session.add_all([user, warehouse, product])
            db.session.commit()
            warehouse_id, product_id = warehouse.id, product.id
        with self.connect(self.primary_port) as primary, self.connect(self.replica_port) as replica:
            barrier = primary.execute("SELECT pg_current_wal_lsn()").fetchone()[0]
            deadline = time.monotonic() + 15
            while not replica.execute("SELECT COALESCE(pg_last_wal_replay_lsn() >= %s::pg_lsn, false)", (barrier,)).fetchone()[0]:
                if time.monotonic() >= deadline:
                    self.fail("ERP schema and baseline did not reach the replica")
                time.sleep(0.1)

        # Reserve a closed loopback port and reconfigure only the disposable
        # standby to prevent reconnecting to the primary. No external network.
        from psycopg import sql
        blocked_socket = socket.socket()
        blocked_socket.bind(("127.0.0.1", 0))
        blocked_port = blocked_socket.getsockname()[1]
        try:
            with self.connect(self.replica_port) as replica:
                conninfo = f"host=127.0.0.1 port={blocked_port} user=postgres connect_timeout=1"
                replica.execute(sql.SQL("ALTER SYSTEM SET primary_conninfo = {}").format(sql.Literal(conninfo)))
                replica.execute("SELECT pg_reload_conf()")
                deadline = time.monotonic() + 10
                while (replica.execute("SELECT current_setting('primary_conninfo')").fetchone()[0] != conninfo or
                       replica.execute("SELECT count(*) FROM pg_stat_wal_receiver WHERE status = 'streaming'").fetchone()[0]):
                    if time.monotonic() >= deadline:
                        self.fail("The local replica did not disconnect")
                    time.sleep(0.1)
            client = erp_app.test_client()
            self.assertEqual(client.post("/login", data={"username": "failover-test", "password": "local-business-test-only"}).status_code, 302)
            business_operation_id = str(__import__("uuid").uuid4())
            movement = client.post("/inventory", data={"warehouse_id": str(warehouse_id), "product_id": str(product_id),
                "operation_id": business_operation_id, "movement_type": "entrada", "quantity": "3", "reason": "local failover test"})
            self.assertEqual(movement.status_code, 302)
            with erp_app.app_context():
                self.assertEqual(InventoryBalance.query.one().quantity, 3)
                original_event = OutboxEvent.query.filter_by(event_type="erp.inventory.movement_recorded").one()
                original_event_id, original_event_body = original_event.id, serialize_event(original_event)
                db.session.remove()
                db.engine.dispose()
        except BaseException:
            blocked_socket.close()
            raise
        continuous_journal = self.root / "continuous-witness.jsonl"
        ready, down_observed, use_promoted = threading.Event(), threading.Event(), threading.Event()
        failures = []
        attempts = 0

        def connect_during_failover():
            nonlocal attempts
            attempts += 1
            if attempts >= 3:
                ready.set()  # Two prior attempts have completed their journal entries.
            try:
                return self.connect(self.replica_port if use_promoted.is_set() else self.primary_port, "andeslog_probe_test")
            except psycopg.Error:
                down_observed.set()
                raise

        def writer():
            try:
                self.witness_module.record(connect_during_failover, continuous_journal, 60, 0.1)
            except Exception as exc:
                failures.append(type(exc).__name__)

        thread = threading.Thread(target=writer, daemon=True)
        thread.start()
        try:
            self.assertTrue(ready.wait(8), "Writer did not establish baseline")
            self.run_pg("pg_ctl", "stop", "-D", str(self.primary_dir), "-m", "immediate", "-w", "-t", "30")
            self.assertTrue(down_observed.wait(8), "Writer did not observe the primary outage")
            self.run_pg("pg_ctl", "promote", "-D", str(self.replica_dir), "-w", "-t", "30")
            promoted_tick = time.monotonic_ns()
            use_promoted.set()
        finally:
            use_promoted.set()
            thread.join(timeout=20)
            blocked_socket.close()
        self.assertFalse(thread.is_alive())
        self.assertEqual(failures, [])
        with self.connect(self.replica_port, "andeslog_probe_test") as recovered:
            witness = self.witness_module.verify(recovered, journal, "primary")
            self.assertEqual(witness["confirmed"], 2)
            self.assertEqual(witness["confirmed_missing"], 0)
            self.assertEqual(witness["uncertain_absent"], 1)
            self.assertTrue(witness["journal_closed"])
            self.assertEqual(recovered.execute("SELECT count(*) FROM public.andeslog_replication_probes WHERE probe_id=%s", (result["probe_id"],)).fetchone()[0], 1)
            with self.assertRaises(self.probe_module.ProbeError):
                self.probe_module.probe(recovered, recovered, timeout=2, interval=0.1)
            import json
            events = [json.loads(line) for line in continuous_journal.read_text(encoding="utf-8").splitlines()]
            post_promotion = [event["id"] for event in events if event["kind"] == "ack" and event["monotonic_ns"] > promoted_tick]
            self.assertTrue(post_promotion, "No confirmed write after promotion")
            rows = recovered.execute("SELECT count(*) FROM public.andeslog_replication_probes WHERE probe_id = ANY(%s::uuid[])", (post_promotion,)).fetchone()[0]
            self.assertEqual(rows, len(post_promotion))
            continuous = self.witness_module.verify(recovered, continuous_journal, "primary")
            self.assertGreater(continuous["uncertain_absent"] + continuous["uncertain_present"], 0)
        with psycopg.connect(host="127.0.0.1", port=self.replica_port, dbname="andeslog_business_test", user="postgres",
                             sslmode="disable", autocommit=True) as business:
            self.assertEqual(business.execute("SELECT count(*) FROM warehouse WHERE code = 'TEST-HA'").fetchone()[0], 1)
            self.assertEqual(business.execute("SELECT count(*) FROM inventory_balances").fetchone()[0], 0)
            self.assertEqual(business.execute("SELECT count(*) FROM outbox_event WHERE event_type = 'erp.inventory.movement_recorded'").fetchone()[0], 0)

        # A separate ERP node is manually directed to the promoted primary.
        # Carry over the existing signed session: this demonstrates business
        # behavior after promotion, not automatic endpoint failover or zero loss.
        recovery_app = create_app({"TESTING": True, "SECRET_KEY": "local-business-failover-test",
            "WTF_CSRF_ENABLED": False, "SESSION_COOKIE_SECURE": False,
            "SQLALCHEMY_DATABASE_URI": f"postgresql+psycopg://postgres@127.0.0.1:{self.replica_port}/andeslog_business_test"})
        try:
            recovery_client = recovery_app.test_client()
            cookie = client.get_cookie("session")
            self.assertIsNotNone(cookie)
            recovery_client.set_cookie("session", cookie.value, domain="localhost")
            self.assertEqual(recovery_client.get("/api/health/ready").status_code, 200)
            self.assertEqual(recovery_client.get("/inventory").status_code, 200)
            replay = {"warehouse_id": str(warehouse_id), "product_id": str(product_id), "operation_id": business_operation_id,
                      "movement_type": "entrada", "quantity": "3", "reason": "local failover test"}
            self.assertEqual(recovery_client.post("/inventory", data=replay).status_code, 302)
            self.assertEqual(recovery_client.post("/inventory", data=replay).status_code, 302)
            response = recovery_client.post("/inventory", data={"warehouse_id": str(warehouse_id), "product_id": str(product_id),
                "operation_id": str(__import__("uuid").uuid4()), "movement_type": "entrada", "quantity": "5", "reason": "post-promotion recovery test"})
            self.assertEqual(response.status_code, 302)
            with recovery_app.app_context():
                self.assertEqual(InventoryBalance.query.one().quantity, 8)
                events = OutboxEvent.query.filter_by(event_type="erp.inventory.movement_recorded").all()
                self.assertEqual(len(events), 2)
                self.assertTrue(all(event.status == "pending" for event in events))
                self.assertEqual(sum(event.id == original_event_id for event in events), 1)
                self.assertNotEqual(serialize_event(next(event for event in events if event.id == original_event_id)), original_event_body)
                db.session.remove()
                db.engine.dispose()
        finally:
            with recovery_app.app_context():
                db.session.remove()
                db.engine.dispose()
            sys.path.remove(str(erp_root))


if __name__ == "__main__":
    unittest.main()
