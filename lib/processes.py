"""Generic session process-lifecycle helpers.

`sessions run` writes harness-agnostic ``process_start`` / ``process_exit``
entries for managed sessions. This module turns those entries into process rows
and verifies local liveness by checking both PID existence and the process start
time token captured at launch.
"""

from __future__ import annotations

import os
import subprocess
from dataclasses import dataclass
from typing import Iterator

import harness
import parse


@dataclass
class ProcessRow:
    session: parse.Session
    filepath: str
    start: dict
    exit: dict | None
    status: str

    def as_dict(self) -> dict:
        meta = self.session.metadata()
        result = {
            "session_id": meta["session_id"],
            "name": meta.get("name", ""),
            "project": meta["project"],
            "filepath": self.filepath,
            "process_start_id": self.start.get("id", ""),
            "pid": self.start.get("pid"),
            "pid_start_time": self.start.get("pid_start_time", ""),
            "status": self.status,
            "started_at": self.start.get("timestamp", ""),
            "cwd": self.start.get("cwd", ""),
            "command": self.start.get("command", ""),
            "argv": self.start.get("argv", []),
            "harness": self.start.get("harness", ""),
            "model": self.start.get("model", meta.get("model", "")),
            "headless": self.start.get("headless", False),
        }
        if self.exit is not None:
            result.update({
                "exited_at": self.exit.get("timestamp", ""),
                "exit_code": self.exit.get("exit_code"),
            })
        return result


def process_start_time_token(pid: int) -> str:
    """Return the same PID start token that `.mise/tasks/run` records."""
    proc_stat = f"/proc/{pid}/stat"
    try:
        with open(proc_stat, encoding="utf-8") as f:
            fields = f.read().split()
        if len(fields) >= 22 and fields[21]:
            return f"linux:{fields[21]}"
    except OSError:
        pass

    try:
        result = subprocess.run(
            ["ps", "-p", str(pid), "-o", "lstart="],
            capture_output=True,
            text=True,
            timeout=2,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return ""

    if result.returncode != 0:
        return ""
    normalized = " ".join(result.stdout.split())
    return f"ps:{normalized}" if normalized else ""


def process_is_live(start: dict) -> bool:
    try:
        pid = int(start.get("pid"))
    except (TypeError, ValueError):
        return False

    expected = start.get("pid_start_time", "")
    if not expected:
        return False

    return process_start_time_token(pid) == expected


def iter_session_files() -> Iterator[str]:
    for name in harness.available():
        adapter = harness.adapter(name)
        try:
            sessions_dir = adapter.sessions_dir()
        except harness.Unsupported:
            continue
        if not sessions_dir or not os.path.isdir(sessions_dir):
            continue
        for project_dir in os.listdir(sessions_dir):
            project_path = os.path.join(sessions_dir, project_dir)
            if not os.path.isdir(project_path):
                continue
            for fname in os.listdir(project_path):
                if not fname.endswith(".jsonl"):
                    continue
                yield os.path.join(project_path, fname)


def session_process_rows(
    filepath: str,
    *,
    project_filter: str = "",
    include_all: bool = False,
) -> list[ProcessRow]:
    session = parse.load(filepath)
    meta = session.metadata()
    if project_filter and project_filter not in meta["project"] and project_filter not in filepath:
        return []

    starts: list[dict] = []
    exits_by_start: dict[str, dict] = {}
    for entry in session.entries:
        etype = entry.get("type")
        if etype == "process_start":
            starts.append(entry)
        elif etype == "process_exit":
            start_id = entry.get("process_start_id")
            if start_id:
                exits_by_start[start_id] = entry

    rows: list[ProcessRow] = []
    for start in starts:
        exit_entry = exits_by_start.get(start.get("id", ""))
        if exit_entry is not None:
            status = "exited"
        elif process_is_live(start):
            status = "live"
        else:
            status = "dead"

        if include_all or status == "live":
            rows.append(ProcessRow(
                session=session,
                filepath=filepath,
                start=start,
                exit=exit_entry,
                status=status,
            ))
    return rows


def collect_process_rows(
    *,
    limit: int = 20,
    project_filter: str = "",
    include_all: bool = False,
) -> list[ProcessRow]:
    rows: list[ProcessRow] = []
    for filepath in iter_session_files():
        try:
            rows.extend(session_process_rows(
                filepath,
                project_filter=project_filter,
                include_all=include_all,
            ))
        except Exception:
            continue

    rows.sort(key=lambda row: row.start.get("timestamp", ""), reverse=True)
    return rows[:limit]
