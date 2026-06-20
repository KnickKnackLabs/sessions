from __future__ import annotations

import json
import os
import subprocess
from datetime import datetime
from pathlib import Path
from typing import Any

from .constants import (
    EXIT_RE,
    FAILURE_MARKERS,
    FILE_RE,
    GIT_GH_RE,
    INSTALL_RE,
    LINT_RE,
    SCRIPT_RE,
    SEARCH_RE,
    SECRET_PATTERNS,
    SESSION_RE,
    TEST_RE,
)
from .model import ScopeEntry


def resolve_path(value: str | Path) -> Path:
    path = Path(value).expanduser()
    if not path.is_absolute():
        caller = os.environ.get("SESSIONS_CALLER_PWD") or ""
        base = Path(caller) if caller else Path.cwd()
        path = base / path
    return path.resolve()


def load_json(path: Path, default: Any) -> Any:
    if not path.exists():
        return default
    with path.open() as f:
        return json.load(f)


def parse_ts(value: str | None) -> datetime | None:
    if not value:
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None


def duration_ms(start: str | None, end: str | None) -> int | None:
    first = parse_ts(start)
    second = parse_ts(end)
    if first is None or second is None:
        return None
    return int(max(0.0, (second - first).total_seconds()) * 1000)


def duration_session_ms(entry: ScopeEntry) -> int:
    return duration_ms(entry.first_timestamp, entry.last_timestamp) or 0


def safe_int(value: Any) -> int:
    if isinstance(value, bool):
        return int(value)
    if isinstance(value, int):
        return value
    if isinstance(value, float):
        return int(value)
    return 0


def safe_float(value: Any) -> float:
    try:
        return float(value or 0.0)
    except (TypeError, ValueError):
        return 0.0


def run_json(args: list[str]) -> Any:
    completed = subprocess.run(args, check=True, text=True, capture_output=True)
    return json.loads(completed.stdout)


def redact(text: str) -> str:
    redacted = text
    for pattern, replacement in SECRET_PATTERNS:
        redacted = pattern.sub(replacement, redacted)
    return redacted


def compact_text(text: str, *, max_chars: int) -> str:
    text = redact(text)
    if max_chars <= 0:
        return ""
    if len(text) <= max_chars:
        return text
    head_size = max_chars // 2
    tail_size = max_chars - head_size
    omitted = len(text) - max_chars
    return text[:head_size] + f"\n[... compacted {omitted:,} chars ...]\n" + text[-tail_size:]


def collect_text_blocks(content: Any) -> str:
    if isinstance(content, str):
        return content
    blocks = content if isinstance(content, list) else []
    texts: list[str] = []
    for block in blocks:
        if isinstance(block, dict) and isinstance(block.get("text"), str):
            texts.append(block["text"])
    return "\n".join(texts)


def command_category(command: str) -> str:
    lower = command.lower().strip()
    if TEST_RE.search(lower):
        return "test"
    if LINT_RE.search(lower):
        return "lint/validation"
    if GIT_GH_RE.search(lower):
        return "git/gh"
    if SESSION_RE.search(lower):
        return "sessions/drone"
    if INSTALL_RE.search(lower):
        return "install/build"
    if SEARCH_RE.search(lower):
        return "search/list"
    if FILE_RE.search(lower):
        return "file-op"
    if SCRIPT_RE.search(lower):
        return "script"
    return "other"


def output_status(text: str, is_error: bool) -> tuple[int | None, int]:
    match = EXIT_RE.search(text)
    if match:
        return int(match.group(1)), 1
    return (1 if is_error else None), int(is_error)
