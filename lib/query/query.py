from __future__ import annotations

import sqlite3


def safe_sql(sql: str) -> str:
    stripped = sql.strip()
    if not stripped:
        raise SystemExit("Missing SQL")
    lowered = stripped.lower()
    if not lowered.startswith(("select", "with", "pragma")):
        raise SystemExit("Only read-only SELECT/WITH/PRAGMA queries are supported")
    if lowered.startswith("pragma") and "=" in lowered:
        raise SystemExit("Only read-only PRAGMA queries are supported")
    return stripped


def rows_for_query(
    conn: sqlite3.Connection, sql: str
) -> tuple[list[str], list[sqlite3.Row]]:
    conn.execute("pragma query_only = on")
    cursor = conn.execute(safe_sql(sql))
    names = [description[0] for description in cursor.description or []]
    return names, cursor.fetchall()
