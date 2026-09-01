from __future__ import annotations

from dataclasses import dataclass


@dataclass
class ScopeEntry:
    session_id: str
    name: str = ""
    project: str = ""
    slug: str = ""
    meta: dict | None = None
    model: str = ""
    first_timestamp: str = ""
    last_timestamp: str = ""
    total_entries: int = 0
    user_messages: int = 0
    assistant_messages: int = 0
    filepath: str = ""
    runtime: str = "pi"


@dataclass
class UsageTotals:
    calls: int = 0
    input_tokens: int = 0
    output_tokens: int = 0
    cache_read_tokens: int = 0
    cache_write_tokens: int = 0
    total_tokens: int = 0
    cost_total: float = 0.0


@dataclass
class ToolCallRecord:
    session_id: str
    call_seq: int
    call_id: str
    timestamp: str
    tool_name: str
    command: str | None
    command_category: str | None


@dataclass
class ToolResultRecord:
    session_id: str
    result_seq: int
    tool_call_id: str
    timestamp: str
    tool_name: str
    is_error: int
    exit_status: int | None
    output_bytes: int
    output_lines: int
    output_excerpt: str | None
