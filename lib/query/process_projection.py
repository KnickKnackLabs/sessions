"""Project managed session process lifecycles into queryable SQLite rows."""

from __future__ import annotations

import sqlite3

import processes

from .model import ScopeEntry


def create_schema(conn: sqlite3.Connection) -> None:
    conn.executescript(
        """
        create table processes (
          session_id text,
          process_start_id text,
          pid integer,
          pid_start_time text,
          status text,
          started_at text,
          exited_at text,
          exit_code integer,
          cwd text,
          harness text,
          model text,
          headless integer,
          primary key (session_id, process_start_id)
        );
        """
    )


def _process_values(row: processes.ProcessRow) -> tuple[object, ...]:
    process = row.as_dict()
    return (
        process["session_id"],
        process["process_start_id"],
        process["pid"],
        process["pid_start_time"],
        process["status"],
        process["started_at"],
        process.get("exited_at"),
        process.get("exit_code"),
        process["cwd"],
        process["harness"],
        process["model"],
        int(process["headless"]),
    )


def project_processes(conn: sqlite3.Connection, entries: list[ScopeEntry]) -> None:
    rows: list[processes.ProcessRow] = []
    for entry in entries:
        rows.extend(
            processes.session_process_rows(
                entry.filepath,
                include_all=True,
                defer_liveness=True,
            )
        )

    processes.resolve_process_liveness(rows)
    conn.executemany(
        """
        insert into processes (
          session_id, process_start_id, pid, pid_start_time, status,
          started_at, exited_at, exit_code, cwd, harness, model, headless
        ) values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        (_process_values(row) for row in rows),
    )
