"""Generic session process-lifecycle helpers.

`sessions run` writes harness-agnostic ``process_start`` / ``process_exit``
entries for managed sessions. This module turns those entries into process rows
and verifies local liveness by checking both PID existence and the process start
time token captured at launch.
"""

from __future__ import annotations

import json
import os
import re
import subprocess
from dataclasses import dataclass
from typing import Iterator

import harness
import parse


_PROCESS_ENTRY_TYPES = {
    "session",
    "harness",
    "model_change",
    "process_start",
    "process_exit",
}
_PROCESS_ENTRY_TYPE = re.compile(
    r'^\s*\{\s*"type"\s*:\s*'
    r'"(?:session|harness|model_change|process_start|process_exit)"'
)
_PS_LSTART = re.compile(r"\S+\s+\S+\s+\d{1,2}\s+\d{2}:\d{2}:\d{2}\s+\d{4}")
# Both procps and BSD ps parse PIDs as signed pid_t values. An out-of-range
# value rejects the entire comma-separated selection instead of just that row.
_MAX_PID = (1 << 31) - 1


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
            result.update(
                {
                    "exited_at": self.exit.get("timestamp", ""),
                    "exit_code": self.exit.get("exit_code"),
                }
            )
        return result


def _linux_proc_stat_start_time(stat: str) -> str:
    """Extract field 22 from Linux proc stat, whose comm field can contain spaces."""
    try:
        _, rest = stat.rsplit(") ", 1)
    except ValueError:
        return ""

    fields = rest.split()
    if len(fields) < 20:
        return ""

    token = fields[19]
    if not token.isdigit() or token == "0":
        return ""
    return token


def _linux_process_start_time_token(pid: int) -> str:
    proc_stat = f"/proc/{pid}/stat"
    try:
        with open(proc_stat, encoding="utf-8") as f:
            token = _linux_proc_stat_start_time(f.read())
    except OSError:
        return ""
    return f"linux:{token}" if token else ""


@dataclass(frozen=True)
class _PsStartTimeOutput:
    tokens: dict[int, str]
    malformed_pids: set[int]
    has_unattributed_malformed_line: bool


def _parse_ps_start_time_tokens(output: str) -> _PsStartTimeOutput:
    tokens: dict[int, str] = {}
    malformed_pids: set[int] = set()
    has_unattributed_malformed_line = False
    for line in output.splitlines():
        fields = line.split(maxsplit=1)
        if not fields:
            continue
        if not fields[0].isdigit():
            has_unattributed_malformed_line = True
            continue

        pid = int(fields[0])
        lstart = " ".join(fields[1].split()) if len(fields) == 2 else ""
        if not _PS_LSTART.fullmatch(lstart) or pid in tokens:
            tokens.pop(pid, None)
            malformed_pids.add(pid)
            continue
        if pid not in malformed_pids:
            tokens[pid] = f"ps:{lstart}"

    return _PsStartTimeOutput(
        tokens=tokens,
        malformed_pids=malformed_pids,
        has_unattributed_malformed_line=has_unattributed_malformed_line,
    )


def _ps_start_time_tokens(output: str) -> dict[int, str] | None:
    parsed = _parse_ps_start_time_tokens(output)
    if parsed.malformed_pids or parsed.has_unattributed_malformed_line:
        return None
    return parsed.tokens


@dataclass(frozen=True)
class ProcessStartTimeProbe:
    tokens: dict[int, str]
    unknown: set[int]


def probe_process_start_times(pids: list[int]) -> ProcessStartTimeProbe:
    """Probe unique PIDs in bounded batches without hiding probe failures."""
    remaining: list[int] = []
    tokens: dict[int, str] = {}
    unknown: set[int] = set()
    for pid in dict.fromkeys(pid for pid in pids if pid > 0):
        if pid > _MAX_PID:
            unknown.add(pid)
            continue
        token = _linux_process_start_time_token(pid)
        if token:
            tokens[pid] = token
        else:
            remaining.append(pid)

    # macOS lacks /proc. Probe its `ps` once per bounded chunk rather than once
    # per stale lifecycle record. Exit 1 with valid empty output means no listed
    # PID exists; execution or output failures preserve an explicit unknown state.
    for offset in range(0, len(remaining), 128):
        chunk = remaining[offset : offset + 128]
        try:
            result = subprocess.run(
                ["ps", "-p", ",".join(map(str, chunk)), "-o", "pid=", "-o", "lstart="],
                capture_output=True,
                text=True,
                timeout=2,
                check=False,
            )
        except (OSError, subprocess.TimeoutExpired):
            unknown.update(chunk)
            continue
        clean_empty = (
            result.returncode == 1
            and not result.stdout.strip()
            and not result.stderr.strip()
        )
        if clean_empty:
            continue
        if result.returncode != 0 or not result.stdout.strip():
            unknown.update(chunk)
            continue

        parsed = _parse_ps_start_time_tokens(result.stdout)
        requested = set(chunk)
        known = parsed.tokens.keys() & requested
        tokens.update((pid, parsed.tokens[pid]) for pid in known)
        unknown.update(parsed.malformed_pids & requested)
        if (
            result.stderr.strip()
            or parsed.has_unattributed_malformed_line
            or parsed.tokens.keys() - requested
            or parsed.malformed_pids - requested
        ):
            unknown.update(requested - known)
    return ProcessStartTimeProbe(tokens=tokens, unknown=unknown)


def process_start_time_tokens(pids: list[int]) -> dict[int, str]:
    """Return known start tokens for callers that do not need probe state."""
    return probe_process_start_times(pids).tokens


def process_start_time_token(pid: int) -> str:
    """Return the same PID start token that `.mise/tasks/run` records."""
    return process_start_time_tokens([pid]).get(pid, "")


def _process_pid(start: dict) -> int | None:
    pid = start.get("pid")
    if type(pid) is not int or pid <= 0:
        return None
    return pid


def process_liveness_status(
    start: dict,
    probe: ProcessStartTimeProbe | None = None,
) -> str:
    pid = _process_pid(start)
    expected = start.get("pid_start_time", "")
    if pid is None or not isinstance(expected, str) or not expected:
        return "unknown"
    current = probe if probe is not None else probe_process_start_times([pid])
    if pid in current.unknown:
        return "unknown"
    return "live" if current.tokens.get(pid, "") == expected else "dead"


def process_is_live(start: dict) -> bool:
    return process_liveness_status(start) == "live"


def load_process_session(filepath: str) -> parse.Session:
    """Load only header, harness, model, and generic lifecycle entries."""
    entries: list[dict] = []
    with open(filepath, encoding="utf-8") as f:
        for raw in f:
            if not _PROCESS_ENTRY_TYPE.search(raw):
                continue
            try:
                entry = json.loads(raw)
            except json.JSONDecodeError:
                continue
            if entry.get("type") in _PROCESS_ENTRY_TYPES:
                entries.append(entry)
    return parse.Session(filepath=filepath, entries=entries)


def iter_session_files(project_filter: str = "") -> Iterator[str]:
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
            if project_filter:
                try:
                    project = adapter.project(
                        os.path.join(project_path, "session.jsonl")
                    )
                except harness.Unsupported:
                    project = ""
                if project_filter not in project and project_filter not in project_path:
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
    defer_liveness: bool = False,
) -> list[ProcessRow]:
    session = load_process_session(filepath)
    meta = session.metadata()
    if (
        project_filter
        and project_filter not in meta["project"]
        and project_filter not in filepath
    ):
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
        elif defer_liveness:
            status = "pending"
        else:
            status = process_liveness_status(start)

        if include_all or status in ("live", "unknown"):
            rows.append(
                ProcessRow(
                    session=session,
                    filepath=filepath,
                    start=start,
                    exit=exit_entry,
                    status=status,
                )
            )
    return rows


def collect_process_rows(
    *,
    limit: int = 20,
    project_filter: str = "",
    include_all: bool = False,
) -> list[ProcessRow]:
    rows: list[ProcessRow] = []
    for filepath in iter_session_files(project_filter):
        try:
            rows.extend(
                session_process_rows(
                    filepath,
                    project_filter=project_filter,
                    include_all=True,
                    defer_liveness=True,
                )
            )
        except Exception:
            continue

    pending = [row for row in rows if row.status == "pending"]
    pids: list[int] = []
    for row in pending:
        pid = _process_pid(row.start)
        if pid is not None:
            pids.append(pid)
    probe = probe_process_start_times(pids)
    for row in pending:
        row.status = process_liveness_status(row.start, probe)

    if not include_all:
        rows = [row for row in rows if row.status in ("live", "unknown")]
    rows.sort(key=lambda row: row.start.get("timestamp", ""), reverse=True)
    return rows[:limit]
