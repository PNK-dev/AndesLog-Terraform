"""Integration test using an isolated PostgreSQL and the actual ERP image."""
import importlib.util
import os
import subprocess
import sys
from html.parser import HTMLParser

import psycopg
from psycopg import errors

spec = importlib.util.spec_from_file_location("bootstrap_rds", "/tests/bootstrap-rds.py")
bootstrap = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bootstrap)

HOST = os.environ.get("TEST_DB_HOST", "db")
PASSWORD = "local-only-owner-password"
APP_PASSWORD = "local-only-app-password"


def connection(user, password, dbname):
    return psycopg.connect(host=HOST, user=user, password=password, dbname=dbname, connect_timeout=5)


def rejected(connection, statement):
    try:
        connection.execute(statement)
    except errors.InsufficientPrivilege:
        connection.rollback()
        return
    connection.rollback()
    raise AssertionError(f"Expected PostgreSQL to reject: {statement}")


with connection("postgres", "local-only-postgres-password", "postgres") as pg:
    pg.autocommit = True
    pg.execute("CREATE ROLE lab_owner LOGIN CREATEDB CREATEROLE PASSWORD 'local-only-owner-password'")
    pg.execute("CREATE DATABASE andeslog OWNER lab_owner")

with connection("lab_owner", PASSWORD, "postgres") as pg:
    pg.autocommit = True
    pg.execute("CREATE ROLE andeslog_app LOGIN PASSWORD 'before-migration'")

with connection("postgres", "local-only-postgres-password", "postgres") as pg:
    pg.autocommit = True
    pg.execute("ALTER DATABASE andeslog OWNER TO andeslog_app")

# A database already owned by the runtime user must not be silently converted.
with connection("lab_owner", PASSWORD, "postgres") as pg:
    try:
        bootstrap.prepare(pg, "andeslog_app", APP_PASSWORD)
        raise AssertionError("Legacy owner was not rejected")
    except ValueError as error:
        assert "owner" in str(error).lower()

with connection("postgres", "local-only-postgres-password", "postgres") as pg:
    pg.autocommit = True
    pg.execute("ALTER DATABASE andeslog OWNER TO lab_owner")

with connection("lab_owner", PASSWORD, "andeslog") as pg:
    bootstrap.assert_safe_schema(pg, "andeslog_app")
with connection("lab_owner", PASSWORD, "postgres") as pg:
    bootstrap.prepare(pg, "andeslog_app", APP_PASSWORD)

env = os.environ.copy()
env.update(SECRET_KEY="local-only-key", APP_ENV="development",
           BOOTSTRAP_ADMIN_USERNAME="admin", BOOTSTRAP_ADMIN_PASSWORD="local-only-admin-password",
           DATABASE_URL=f"postgresql+psycopg://lab_owner:{PASSWORD}@{HOST}:5432/andeslog")
subprocess.run(["flask", "--app", "app:create_app", "db", "upgrade"], env=env, check=True)

with connection("lab_owner", PASSWORD, "andeslog") as pg:
    bootstrap.finalize(pg, "andeslog_app")
    # Re-running the grants after another migration must be safe.
    bootstrap.finalize(pg, "andeslog_app")

env["DATABASE_URL"] = f"postgresql+psycopg://andeslog_app:{APP_PASSWORD}@{HOST}:5432/andeslog"
subprocess.run(["flask", "--app", "app:create_app", "seed-admin"], env=env, check=True)
with connection("andeslog_app", APP_PASSWORD, "andeslog") as app:
    assert app.execute('SELECT username FROM "user" WHERE username = %s', ("admin",)).fetchone() == ("admin",)
    app.execute("INSERT INTO warehouse (code, name, city, active) VALUES ('LOCAL', 'Local test', 'Lima', true)")
    app.commit()
    rejected(app, "CREATE TABLE public.unwanted (id integer)")
    rejected(app, "CREATE TEMP TABLE unwanted (id integer)")
    rejected(app, "DROP TABLE public.warehouse")
    rejected(app, "TRUNCATE TABLE public.warehouse")
    rejected(app, "UPDATE public.alembic_version SET version_num = 'invalid'")

# Exercise a real login/readiness/ERP query with the restricted role.
os.environ.update(env)
sys.path.insert(0, "/app")
from app import create_app
application = create_app()
client = application.test_client()
assert client.get("/api/health/ready").status_code == 200
class CsrfToken(HTMLParser):
    value = None
    def handle_starttag(self, tag, attrs):
        fields = dict(attrs)
        if tag == "input" and fields.get("name") == "csrf_token":
            self.value = fields.get("value")

token = CsrfToken()
token.feed(client.get("/login").get_data(as_text=True))
assert token.value
assert client.post("/login", data={"username": "admin", "password": "local-only-admin-password", "csrf_token": token.value}).status_code == 302
assert client.get("/api/v1/summary").status_code == 200
assert client.get("/warehouses").status_code == 200
print("OK: migration owner, restricted ERP DML, legacy guard, seed and ERP readiness verified locally")
