"""Create or update AndesLog's least-privilege PostgreSQL application role."""

from __future__ import annotations

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


def connect_with_retry(master: dict[str, str]) -> psycopg.Connection:
    settings = {
        "host": os.environ["DB_HOST"],
        "port": int(os.environ.get("DB_PORT", "5432")),
        "dbname": "postgres",
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


def main() -> None:
    master = read_json(os.environ["RDS_MASTER_SECRET_FILE"])
    app_secret = read_json(os.environ["ERP_DB_SECRET_FILE"])
    app_user = app_secret.get("username", "andeslog_app")
    app_password = app_secret["password"]

    with connect_with_retry(master) as connection:
        connection.autocommit = True
        with connection.cursor() as cursor:
            cursor.execute("SELECT 1 FROM pg_roles WHERE rolname = %s", (app_user,))
            role_exists = cursor.fetchone() is not None
            if role_exists:
                cursor.execute(
                    sql.SQL("ALTER ROLE {} WITH LOGIN PASSWORD {}").format(
                        sql.Identifier(app_user), sql.Literal(app_password)
                    )
                )
            else:
                cursor.execute(
                    sql.SQL("CREATE ROLE {} WITH LOGIN PASSWORD {}").format(
                        sql.Identifier(app_user), sql.Literal(app_password)
                    )
                )

            cursor.execute("SELECT 1 FROM pg_database WHERE datname = %s", ("andeslog",))
            if cursor.fetchone() is None:
                cursor.execute(
                    sql.SQL("CREATE DATABASE {} OWNER {}").format(
                        sql.Identifier("andeslog"), sql.Identifier(app_user)
                    )
                )
            else:
                cursor.execute(
                    sql.SQL("ALTER DATABASE {} OWNER TO {}").format(
                        sql.Identifier("andeslog"), sql.Identifier(app_user)
                    )
                )


if __name__ == "__main__":
    main()
