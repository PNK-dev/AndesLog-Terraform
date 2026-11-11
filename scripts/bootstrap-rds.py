"""Prepare an RDS database owner and an application role without DDL rights.

Migrations run separately as the database owner. Never use this to take
ownership from an existing application role; legacy databases need migration.
"""
from __future__ import annotations

import argparse
import json
import os
import time
from pathlib import Path

import psycopg
from psycopg import sql


def read_json(path: str) -> dict[str, str]:
    with Path(path).open(encoding="utf-8") as secret_file:
        value = json.load(secret_file)
    if not isinstance(value, dict):
        raise ValueError("Secret file must contain a JSON object")
    return value


def connect_with_retry(master: dict[str, str], dbname: str) -> psycopg.Connection:
    settings = {
        "host": os.environ["DB_HOST"],
        "port": int(os.environ.get("DB_PORT", "5432")),
        "dbname": dbname,
        "user": master["username"],
        "password": master["password"],
        "sslmode": "verify-full",
        "sslrootcert": "/etc/ssl/certs/aws-rds-global-bundle.pem",
        "connect_timeout": 10,
    }
    last_error: Exception | None = None
    for attempt in range(1, 13):
        try:
            return psycopg.connect(**settings)
        except psycopg.OperationalError as error:
            last_error = error
            if attempt < 12:
                time.sleep(5)
    assert last_error is not None
    raise last_error


def prepare(connection: psycopg.Connection, app_user: str, password: str) -> None:
    if app_user != "andeslog_app" or not password:
        raise ValueError("Unexpected application role or empty password")
    connection.autocommit = True
    with connection.cursor() as cursor:
        cursor.execute("SELECT current_user")
        owner = cursor.fetchone()[0]
        if owner == app_user:
            raise ValueError("The database owner must not be the runtime role")
        cursor.execute("SELECT pg_get_userbyid(datdba) FROM pg_database WHERE datname = %s", ("andeslog",))
        database = cursor.fetchone()
        if database and database[0] != owner:
            raise ValueError("Legacy or unexpected database owner; an explicit migration is required")
        cursor.execute(
            "SELECT rolsuper, rolcreatedb, rolcreaterole, rolreplication, rolbypassrls "
            "FROM pg_roles WHERE rolname = %s", (app_user,)
        )
        attributes = cursor.fetchone()
        if attributes:
            cursor.execute("SELECT EXISTS (SELECT 1 FROM pg_auth_members m JOIN pg_roles r ON r.oid = m.member WHERE r.rolname = %s)", (app_user,))
            if any(attributes) or cursor.fetchone()[0]:
                raise ValueError("Existing application role has elevated privileges or memberships")
            cursor.execute(sql.SQL("ALTER ROLE {} WITH LOGIN PASSWORD {}").format(sql.Identifier(app_user), sql.Literal(password)))
        else:
            cursor.execute(sql.SQL("CREATE ROLE {} WITH LOGIN PASSWORD {}").format(sql.Identifier(app_user), sql.Literal(password)))
        if not database:
            cursor.execute(sql.SQL("CREATE DATABASE {} OWNER {}").format(sql.Identifier("andeslog"), sql.Identifier(owner)))


def assert_safe_schema(connection: psycopg.Connection, app_user: str) -> None:
    if app_user != "andeslog_app":
        raise ValueError("Unexpected application role")
    with connection.cursor() as cursor:
        cursor.execute("SELECT current_user, current_database(), pg_get_userbyid(datdba) FROM pg_database WHERE datname = current_database()")
        current, database, owner = cursor.fetchone()
        if database != "andeslog" or owner != current or current == app_user:
            raise ValueError("Database owner or destination is unexpected")
        cursor.execute("SELECT nspname FROM pg_namespace WHERE nspname = 'public' AND pg_get_userbyid(nspowner) = %s", (app_user,))
        if cursor.fetchone():
            raise ValueError("The application owns the schema; an explicit migration is required")
        cursor.execute("SELECT relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = 'public' AND pg_get_userbyid(c.relowner) = %s LIMIT 1", (app_user,))
        if cursor.fetchone():
            raise ValueError("The application owns schema objects; an explicit migration is required")


def finalize(connection: psycopg.Connection, app_user: str) -> None:
    assert_safe_schema(connection, app_user)
    with connection.cursor() as cursor:
        database = "andeslog"
        cursor.execute("REVOKE CREATE ON SCHEMA public FROM PUBLIC")
        cursor.execute(sql.SQL("REVOKE CREATE ON SCHEMA public FROM {}").format(sql.Identifier(app_user)))
        cursor.execute(sql.SQL("REVOKE CREATE, TEMPORARY ON DATABASE {} FROM PUBLIC").format(sql.Identifier(database)))
        cursor.execute(sql.SQL("REVOKE ALL PRIVILEGES ON DATABASE {} FROM {}").format(sql.Identifier(database), sql.Identifier(app_user)))
        cursor.execute(sql.SQL("GRANT CONNECT ON DATABASE {} TO {}").format(sql.Identifier(database), sql.Identifier(app_user)))
        cursor.execute(sql.SQL("GRANT USAGE ON SCHEMA public TO {}").format(sql.Identifier(app_user)))
        cursor.execute(sql.SQL("REVOKE ALL PRIVILEGES ON ALL TABLES IN SCHEMA public FROM {}").format(sql.Identifier(app_user)))
        cursor.execute(sql.SQL("REVOKE ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public FROM {}").format(sql.Identifier(app_user)))
        cursor.execute("SELECT c.relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = 'public' AND c.relkind IN ('r', 'p') AND c.relname <> 'alembic_version'")
        for (table,) in cursor.fetchall():
            cursor.execute(sql.SQL("GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.{} TO {}").format(sql.Identifier(table), sql.Identifier(app_user)))
        cursor.execute("SELECT to_regclass('public.alembic_version')")
        if cursor.fetchone()[0] is not None:
            cursor.execute(sql.SQL("GRANT SELECT ON TABLE public.alembic_version TO {}").format(sql.Identifier(app_user)))
        cursor.execute(sql.SQL("GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO {}").format(sql.Identifier(app_user)))
        cursor.execute("SELECT has_database_privilege(%s, current_database(), 'CREATE'), has_database_privilege(%s, current_database(), 'TEMPORARY'), has_schema_privilege(%s, 'public', 'CREATE')", (app_user, app_user, app_user))
        if any(cursor.fetchone()):
            raise ValueError("The application still has effective database or schema creation rights")
        cursor.execute("SELECT EXISTS (SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = 'public' AND c.relkind IN ('r', 'p') AND (has_table_privilege(%s, c.oid, 'TRUNCATE') OR has_table_privilege(%s, c.oid, 'TRIGGER'))) ", (app_user, app_user))
        if cursor.fetchone()[0]:
            raise ValueError("The application still has effective elevated table rights")
    connection.commit()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("phase", choices=("prepare", "finalize"))
    args = parser.parse_args()
    master = read_json(os.environ["RDS_MASTER_SECRET_FILE"])
    app_secret = read_json(os.environ["ERP_DB_SECRET_FILE"])
    app_user = app_secret.get("username", "andeslog_app")
    if args.phase == "prepare":
        with connect_with_retry(master, "postgres") as connection:
            with connection.cursor() as cursor:
                cursor.execute("SELECT 1 FROM pg_database WHERE datname = %s", ("andeslog",))
                exists = cursor.fetchone() is not None
            connection.rollback()
            if exists:
                with connect_with_retry(master, "andeslog") as existing:
                    assert_safe_schema(existing, app_user)
            prepare(connection, app_user, app_secret["password"])
    else:
        with connect_with_retry(master, "andeslog") as connection:
            finalize(connection, app_user)


if __name__ == "__main__":
    main()
