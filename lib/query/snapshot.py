from __future__ import annotations

import argparse
import hashlib
import json
import os
import sqlite3
import sys
import tempfile
from datetime import UTC, datetime
from pathlib import Path

import parse

from .db import QUERY_SCHEMA_VERSION, build_db
from .scope import session_files
from .util import resolve_path

_REQUIRED_METADATA = {
    "schema_version",
    "built_at",
    "text_mode",
    "project",
    "limit",
    "session_ids",
}


def _invalid_database() -> SystemExit:
    return SystemExit("Not a sessions query database; refresh it with --refresh")


def _metadata(conn: sqlite3.Connection) -> dict[str, str]:
    try:
        metadata = dict(conn.execute("select key, value from projection_meta"))
    except sqlite3.Error as exc:
        raise _invalid_database() from exc
    if not _REQUIRED_METADATA.issubset(metadata):
        raise _invalid_database() from ValueError("missing projection metadata")
    return metadata


def _source_paths(args: argparse.Namespace) -> list[Path]:
    if args.session_ids:
        paths = [
            Path(parse.find_session(session_id)) for session_id in args.session_ids
        ]
    else:
        paths = session_files(project=args.project)
    return list(dict.fromkeys(path.resolve() for path in paths))


def _source_key(path: Path) -> str:
    return hashlib.sha256(os.fsencode(path)).hexdigest()


def _state_key(size: int, mtime_ns: int) -> str:
    return hashlib.sha256(f"{size}:{mtime_ns}".encode()).hexdigest()


def _source_manifest(paths: list[Path]) -> dict[str, str]:
    sources: dict[str, str] = {}
    for path in paths:
        key = _source_key(path)
        try:
            stat = path.stat()
            sources[key] = _state_key(stat.st_size, stat.st_mtime_ns)
        except OSError:
            sources[key] = ""
    return sources


def _refuse_session_target(path: Path) -> None:
    if path.suffix.lower() == ".jsonl":
        raise SystemExit(
            f"Refusing to replace session source with query database: {path}"
        )


def _add_provenance(
    conn: sqlite3.Connection,
    args: argparse.Namespace,
    sources: dict[str, str],
) -> None:
    conn.executescript(
        """
        create table projection_meta (key text primary key, value text not null);
        create table projection_sources (
          source_key text primary key,
          state_key text not null
        );
        """
    )
    values = {
        "schema_version": QUERY_SCHEMA_VERSION,
        "built_at": datetime.now(UTC).isoformat(),
        "text_mode": args.text,
        "project": args.project,
        "limit": str(args.limit),
        "session_ids": json.dumps(args.session_ids),
    }
    conn.executemany("insert into projection_meta values (?, ?)", values.items())
    conn.executemany(
        "insert into projection_sources values (?, ?)", sorted(sources.items())
    )


def _connect_read_only(path: Path) -> sqlite3.Connection:
    return sqlite3.connect(f"{path.as_uri()}?mode=ro", uri=True)


def refresh_snapshot(args: argparse.Namespace, path: Path) -> sqlite3.Connection:
    _refuse_session_target(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    sources = _source_manifest(_source_paths(args))
    memory = build_db(args)
    temporary: Path | None = None
    try:
        _add_provenance(memory, args, sources)
        memory.commit()

        handle = tempfile.NamedTemporaryFile(
            dir=path.parent, prefix=f".{path.name}.", suffix=".tmp", delete=False
        )
        temporary = Path(handle.name)
        handle.close()

        disk = sqlite3.connect(temporary)
        try:
            memory.backup(disk)
        finally:
            disk.close()
        os.chmod(temporary, 0o600)
        os.replace(temporary, path)
    finally:
        memory.close()
        if temporary is not None:
            temporary.unlink(missing_ok=True)
    return _connect_read_only(path)


def _freshness(conn: sqlite3.Connection) -> str:
    meta = _metadata(conn)
    if meta["schema_version"] != QUERY_SCHEMA_VERSION:
        raise SystemExit(
            "Unsupported sessions query database; refresh it with --refresh"
        )

    try:
        known = dict(
            conn.execute("select source_key, state_key from projection_sources")
        )
        session_ids = json.loads(meta["session_ids"])
        limit = int(meta["limit"])
    except (json.JSONDecodeError, sqlite3.Error, TypeError, ValueError) as exc:
        raise _invalid_database() from exc
    if not isinstance(session_ids, list):
        raise _invalid_database() from ValueError("invalid session ID scope")

    if session_ids:
        try:
            paths = [
                Path(filepath).resolve()
                for (filepath,) in conn.execute("select filepath from sessions")
            ]
        except sqlite3.Error as exc:
            raise _invalid_database() from exc
    else:
        paths = [path.resolve() for path in session_files(project=meta["project"])]
    current = _source_manifest(paths)

    missing = sum(
        source_key not in current or current[source_key] == "" for source_key in known
    )
    changed = sum(
        source_key in current
        and current[source_key] != ""
        and current[source_key] != expected
        for source_key, expected in known.items()
    )
    new = len(set(current) - set(known))

    state = "fresh" if changed == 0 and missing == 0 and new == 0 else "stale"
    scope = (
        f"selected={len(session_ids)}"
        if session_ids
        else f"project={meta['project'] or '*'},limit={limit}"
    )
    return (
        f"sessions query database: {state}; built {meta['built_at']}; "
        f"text={meta['text_mode']}; scope={scope}; "
        f"changed={changed}; missing={missing}; new={new}"
    )


def open_database(args: argparse.Namespace) -> sqlite3.Connection:
    if not args.db:
        if args.refresh:
            raise SystemExit("--refresh requires --db")
        return build_db(args)

    path = resolve_path(Path(args.db))
    if args.refresh:
        conn = refresh_snapshot(args, path)
    else:
        if not path.exists():
            raise SystemExit(
                f"Query database not found: {path}; create it with --refresh"
            )
        conn = _connect_read_only(path)
    try:
        conn.row_factory = sqlite3.Row
        freshness = _freshness(conn)
    except BaseException:
        conn.close()
        raise
    print(freshness, file=sys.stderr)
    return conn
