"""Wait for structural turn or segment boundaries across session transcripts."""

from __future__ import annotations

import json
import os
import tempfile
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import harness
import parse
import processes


class WaitAnyError(Exception):
    """User-facing wait-any validation or runtime error."""


@dataclass
class WatchSpec:
    """One explicitly selected session stream."""

    name: str
    query: str


@dataclass
class Watch:
    """Resolved append-only transcript cursor and harness adapter."""

    name: str
    filepath: str
    session_id: str
    harness_name: str
    adapter: Any
    offset: int
    index: int
    order: int


@dataclass
class WaitResult:
    """First observed batch of settled boundaries, or a timeout tick."""

    event: str
    events: list[dict]
    watched: list[dict]
    timeout_seconds: float


def resolve_input_path(raw: str) -> Path:
    """Resolve a caller-provided path without depending on package cwd."""
    path = Path(raw).expanduser()
    if path.is_absolute():
        return path
    caller = Path(os.environ.get("SESSIONS_CALLER_PWD") or os.getcwd())
    return caller / path


def load_specs(session_queries: list[str], config_raw: str) -> list[WatchSpec]:
    """Load and validate positional or file-backed watch definitions."""
    if session_queries and config_raw:
        raise WaitAnyError("provide either session IDs or --config, not both")
    if not session_queries and not config_raw:
        raise WaitAnyError("provide at least one session ID or --config")

    if session_queries:
        specs = [WatchSpec(name=query, query=query) for query in session_queries]
    else:
        config_path = resolve_input_path(config_raw)
        try:
            config = json.loads(config_path.read_text(encoding="utf-8"))
        except OSError as error:
            raise WaitAnyError(f"cannot read config {config_path}: {error}") from error
        except json.JSONDecodeError as error:
            raise WaitAnyError(f"invalid JSON config {config_path}: {error}") from error

        if not isinstance(config, dict):
            raise WaitAnyError("config must be a JSON object")
        unknown = set(config) - {"version", "watches"}
        if unknown:
            raise WaitAnyError(f"unknown config field(s): {', '.join(sorted(unknown))}")
        if type(config.get("version")) is not int or config["version"] != 1:
            raise WaitAnyError("config version must be 1")
        rows = config.get("watches")
        if not isinstance(rows, list) or not rows:
            raise WaitAnyError("config watches must be a non-empty array")

        specs = []
        for position, row in enumerate(rows, start=1):
            if not isinstance(row, dict):
                raise WaitAnyError(f"watch {position} must be an object")
            unknown = set(row) - {"name", "session_id"}
            if unknown:
                raise WaitAnyError(
                    f"watch {position} has unknown field(s): "
                    + ", ".join(sorted(unknown))
                )
            name = row.get("name")
            query = row.get("session_id")
            if not isinstance(name, str) or not name.strip():
                raise WaitAnyError(f"watch {position} requires a non-empty name")
            if not isinstance(query, str) or not query.strip():
                raise WaitAnyError(f"watch {position} requires a non-empty session_id")
            specs.append(WatchSpec(name=name.strip(), query=query.strip()))

    names = [spec.name for spec in specs]
    duplicate_names = sorted({name for name in names if names.count(name) > 1})
    if duplicate_names:
        raise WaitAnyError(f"duplicate watch name: {duplicate_names[0]}")
    return specs


def _read_complete_entries(filepath: str, offset: int) -> tuple[list[dict], int]:
    """Read complete appended JSONL entries without consuming a partial line."""
    try:
        size = os.path.getsize(filepath)
    except OSError as error:
        raise WaitAnyError(
            f"cannot stat session transcript {filepath}: {error}"
        ) from error
    if size < offset:
        raise WaitAnyError(f"session transcript shrank while waiting: {filepath}")

    try:
        with open(filepath, "rb") as stream:
            stream.seek(offset)
            data = stream.read()
    except OSError as error:
        raise WaitAnyError(
            f"cannot read session transcript {filepath}: {error}"
        ) from error

    if not data:
        return [], offset
    complete_length = len(data) if data.endswith(b"\n") else data.rfind(b"\n") + 1
    if complete_length <= 0:
        return [], offset

    entries = []
    complete = data[:complete_length]
    for line in complete.splitlines():
        if not line.strip():
            continue
        try:
            entries.append(json.loads(line))
        except (json.JSONDecodeError, UnicodeDecodeError):
            continue
    return entries, offset + complete_length


def _initial_entries(filepath: str) -> tuple[list[dict], int]:
    return _read_complete_entries(filepath, 0)


def _load_cursor_state(path: Path | None, event_name: str) -> dict:
    if path is None or not path.exists():
        return {"version": 2, "event": event_name, "sessions": {}}
    try:
        state = json.loads(path.read_text(encoding="utf-8"))
    except OSError as error:
        raise WaitAnyError(f"cannot read cursor file {path}: {error}") from error
    except json.JSONDecodeError as error:
        raise WaitAnyError(f"invalid cursor JSON {path}: {error}") from error
    if not isinstance(state, dict) or type(state.get("version")) is not int:
        raise WaitAnyError("cursor file version must be 1 or 2")
    if state["version"] == 1:
        if event_name != "segment.settled":
            raise WaitAnyError(
                "cursor file version 1 represents 'segment.settled', "
                f"expected {event_name!r}"
            )
        state = {**state, "version": 2, "event": "segment.settled"}
    elif state["version"] != 2:
        raise WaitAnyError("cursor file version must be 1 or 2")
    if state.get("event") != event_name:
        raise WaitAnyError(
            f"cursor file event is {state.get('event')!r}, expected {event_name!r}"
        )
    sessions = state.get("sessions")
    if not isinstance(sessions, dict):
        raise WaitAnyError("cursor file sessions must be an object")
    return state


def save_cursor_state(path: Path | None, watches: list[Watch], event_name: str) -> None:
    """Atomically persist event-scoped cursor metadata without transcript content."""
    if path is None:
        return
    parent = path.parent
    if not parent.is_dir():
        raise WaitAnyError(f"cursor file parent does not exist: {parent}")
    state = {
        "version": 2,
        "event": event_name,
        "sessions": {
            watch.session_id: {
                "filepath": watch.filepath,
                "harness": watch.harness_name,
                "offset": watch.offset,
                "index": watch.index,
            }
            for watch in watches
        },
    }
    temp_path = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="w",
            encoding="utf-8",
            dir=parent,
            prefix=f".{path.name}.",
            delete=False,
        ) as stream:
            temp_path = Path(stream.name)
            json.dump(state, stream, indent=2, sort_keys=True)
            stream.write("\n")
        os.replace(temp_path, path)
    except OSError as error:
        if temp_path is not None:
            try:
                temp_path.unlink(missing_ok=True)
            except OSError:
                pass
        raise WaitAnyError(f"cannot write cursor file {path}: {error}") from error


def resolve_watches(
    specs: list[WatchSpec], cursor_path: Path | None, event_name: str
) -> list[Watch]:
    """Resolve session selectors and restore event-scoped durable cursors."""
    state = _load_cursor_state(cursor_path, event_name)
    stored_sessions = state["sessions"]
    stored_by_path = {
        stored.get("filepath"): (session_id, stored)
        for session_id, stored in stored_sessions.items()
        if isinstance(stored, dict) and isinstance(stored.get("filepath"), str)
    }
    watches = []
    resolved_ids = set()

    for order, spec in enumerate(specs):
        filepath = parse.find_session(spec.query)
        stored_match = stored_by_path.get(filepath)
        stored_harness = stored_match[1].get("harness") if stored_match else None

        if isinstance(stored_harness, str) and stored_harness:
            session_id, stored = stored_match
            try:
                adapter = harness.adapter(stored_harness)
            except ValueError as error:
                raise WaitAnyError(str(error)) from error
            harness_name = stored_harness
            try:
                latest_offset = os.path.getsize(filepath)
            except OSError as error:
                raise WaitAnyError(
                    f"cannot stat session transcript {filepath}: {error}"
                ) from error
            latest_index = None
        else:
            entries, latest_offset = _initial_entries(filepath)
            adapter = harness.resolve(filepath=filepath, entries=entries)
            harness_name = adapter.__name__.rsplit(".", 1)[-1]
            session_id = adapter.session_id(entries, filepath)
            latest_index = len(entries) - 1
            stored = stored_sessions.get(session_id)

        if session_id in resolved_ids:
            raise WaitAnyError(f"duplicate resolved session: {session_id}")
        resolved_ids.add(session_id)

        if stored is None:
            offset = latest_offset
            index = latest_index
        else:
            if not isinstance(stored, dict):
                raise WaitAnyError(f"invalid cursor entry for session {session_id}")
            if stored.get("filepath") != filepath:
                raise WaitAnyError(f"cursor path changed for session {session_id}")
            offset = stored.get("offset")
            index = stored.get("index")
            if type(offset) is not int or offset < 0:
                raise WaitAnyError(f"invalid cursor offset for session {session_id}")
            if type(index) is not int or index < -1:
                raise WaitAnyError(f"invalid cursor index for session {session_id}")
            if offset > latest_offset:
                raise WaitAnyError(
                    f"cursor is ahead of session transcript {session_id}"
                )
            if latest_index is not None and index > latest_index:
                raise WaitAnyError(
                    f"cursor is ahead of session transcript {session_id}"
                )

        watches.append(
            Watch(
                name=spec.name,
                filepath=filepath,
                session_id=session_id,
                harness_name=harness_name,
                adapter=adapter,
                offset=offset,
                index=index,
                order=order,
            )
        )

    save_cursor_state(cursor_path, watches, event_name)
    return watches


def current_session_state(watch: Watch) -> dict:
    """Reduce transcript and managed-process evidence to a current state."""
    entries, _offset = _initial_entries(watch.filepath)
    transcript_state = "unknown"
    basis = None
    for index, entry in enumerate(entries):
        if entry.get("type") != "message":
            continue
        message = entry.get("message", {})
        role = message.get("role")
        if role == "assistant":
            settled = watch.adapter.settled_segment(entry, index)
            if settled is not None:
                transcript_state = "idle"
                basis = {
                    key: settled[key]
                    for key in ("index", "timestamp", "stop_reason", "error")
                }
            else:
                transcript_state = "working"
                basis = None
        elif role in {"user", "toolResult"}:
            transcript_state = "working"
            basis = None

    rows = processes.session_process_rows(watch.filepath, include_all=True)
    statuses = {row.status for row in rows}
    if "live" in statuses:
        process_state = "live"
    elif "unknown" in statuses or not statuses:
        process_state = "unknown"
    elif statuses <= {"dead", "exited"}:
        process_state = "exited"
    else:
        process_state = "unknown"

    if process_state != "live":
        state = "exited" if process_state in {"dead", "exited"} else "unknown"
        basis = None
    else:
        state = transcript_state

    return {
        "source": watch.name,
        "session_id": watch.session_id,
        "state": state,
        "process_state": process_state,
        "basis": basis,
    }


def wait_for_state(
    watches: list[Watch],
    *,
    state: str,
    timeout_seconds: float,
    interval_seconds: float,
) -> dict:
    """Return immediately for a current match, or wait for one to appear."""
    deadline = time.monotonic() + timeout_seconds if timeout_seconds > 0 else None
    initial = True
    while True:
        matches = [
            observed
            for watch in watches
            if (observed := current_session_state(watch))["state"] == state
        ]
        if matches:
            return {
                "event": "state.current" if initial else "state.changed",
                "state": state,
                "sessions": matches,
            }
        initial = False
        if deadline is not None and time.monotonic() >= deadline:
            return {
                "event": "timeout",
                "state": state,
                "timeout_seconds": timeout_seconds,
                "watched": [
                    {"source": watch.name, "session_id": watch.session_id}
                    for watch in watches
                ],
            }
        sleep_for = interval_seconds
        if deadline is not None:
            sleep_for = min(sleep_for, max(0, deadline - time.monotonic()))
        if sleep_for > 0:
            time.sleep(sleep_for)


def _poll_watch(watch: Watch, event_name: str) -> list[dict]:
    entries, next_offset = _read_complete_entries(watch.filepath, watch.offset)
    events = []
    next_index = watch.index
    for entry in entries:
        next_index += 1
        if entry.get("type") == "harness" and entry.get("name"):
            try:
                watch.adapter = harness.adapter(entry["name"])
            except ValueError as error:
                raise WaitAnyError(str(error)) from error
            watch.harness_name = entry["name"]
        normalize = (
            watch.adapter.settled_turn
            if event_name == "turn.settled"
            else watch.adapter.settled_segment
        )
        event = normalize(entry, next_index)
        if event is None:
            continue
        events.append(
            {
                "source": watch.name,
                "session_id": watch.session_id,
                **event,
                "_watch_order": watch.order,
            }
        )
    watch.offset = next_offset
    watch.index = next_index
    return events


def wait_for_any(
    watches: list[Watch],
    *,
    event_name: str,
    timeout_seconds: float,
    interval_seconds: float,
    cursor_path: Path | None,
) -> WaitResult:
    """Return the first polling batch containing settled event boundaries."""
    deadline = time.monotonic() + timeout_seconds if timeout_seconds > 0 else None

    while True:
        events = []
        cursors_changed = False
        for watch in watches:
            previous_offset = watch.offset
            events.extend(_poll_watch(watch, event_name))
            cursors_changed = cursors_changed or watch.offset != previous_offset

        if events:
            events.sort(
                key=lambda event: (
                    event.get("timestamp", ""),
                    event["_watch_order"],
                    event["index"],
                )
            )
            for event in events:
                event.pop("_watch_order", None)
            return WaitResult(
                event=event_name,
                events=events,
                watched=[],
                timeout_seconds=timeout_seconds,
            )

        if cursors_changed:
            save_cursor_state(cursor_path, watches, event_name)
        if deadline is not None and time.monotonic() >= deadline:
            return WaitResult(
                event="timeout",
                events=[],
                watched=[
                    {"source": watch.name, "session_id": watch.session_id}
                    for watch in watches
                ],
                timeout_seconds=timeout_seconds,
            )

        sleep_for = interval_seconds
        if deadline is not None:
            sleep_for = min(sleep_for, max(0, deadline - time.monotonic()))
        if sleep_for > 0:
            time.sleep(sleep_for)


def result_to_dict(result: WaitResult) -> dict:
    if result.event != "timeout":
        return {"event": result.event, "events": result.events}
    return {
        "event": result.event,
        "timeout_seconds": result.timeout_seconds,
        "watched": result.watched,
    }
