from __future__ import annotations

import argparse
import json
import sqlite3
from pathlib import Path

from .model import ScopeEntry, ToolCallRecord, ToolResultRecord, UsageTotals
from .process_projection import create_schema as create_process_schema
from .process_projection import project_processes
from .scope import scope_entries
from .util import (
    collect_text_blocks,
    command_category,
    compact_text,
    duration_ms,
    duration_session_ms,
    output_status,
    redact,
)


def create_schema(conn: sqlite3.Connection) -> None:
    conn.executescript(
        """
        create table sessions (
          session_id text primary key,
          runtime text,
          project text,
          name text,
          slug text,
          meta text,
          model text,
          first_timestamp text,
          last_timestamp text,
          duration_ms integer,
          total_entries integer,
          user_messages integer,
          assistant_messages integer,
          filepath text,
          calls integer,
          input_tokens integer,
          output_tokens integer,
          cache_read_tokens integer,
          cache_write_tokens integer,
          total_tokens integer,
          cost_total real
        );

        create table entries (
          session_id text,
          seq integer,
          entry_id text,
          parent_id text,
          timestamp text,
          type text,
          role text,
          primary key (session_id, seq)
        );

        create view events as
          select session_id, seq, timestamp, type, role from entries;

        create table messages (
          session_id text,
          seq integer,
          timestamp text,
          role text,
          text_chars integer,
          text_excerpt text,
          has_usage integer,
          primary key (session_id, seq)
        );

        create table tool_calls (
          session_id text,
          seq integer,
          timestamp text,
          tool_call_id text,
          tool_name text,
          command text,
          command_category text,
          primary key (session_id, seq, tool_call_id)
        );

        create table tool_results (
          session_id text,
          seq integer,
          timestamp text,
          tool_call_id text,
          tool_name text,
          is_error integer,
          exit_status integer,
          output_bytes integer,
          output_lines integer,
          output_excerpt text,
          primary key (session_id, seq, tool_call_id)
        );

        create table tool_pairs (
          session_id text,
          call_seq integer,
          result_seq integer,
          start_timestamp text,
          end_timestamp text,
          duration_ms integer,
          tool_call_id text,
          tool_name text,
          command text,
          command_category text,
          is_error integer,
          exit_status integer,
          output_bytes integer,
          output_lines integer,
          output_excerpt text,
          primary key (session_id, call_seq, tool_call_id)
        );

        create view bash_calls as
          select * from tool_pairs where tool_name = 'bash';
        """
    )
    create_process_schema(conn)


def insert_session(
    conn: sqlite3.Connection, entry: ScopeEntry, usage: UsageTotals
) -> None:
    conn.execute(
        """
        insert into sessions values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        (
            entry.session_id,
            entry.runtime,
            entry.project,
            entry.name,
            entry.slug,
            (
                json.dumps(entry.meta, separators=(",", ":"), sort_keys=True)
                if entry.meta is not None
                else None
            ),
            entry.model,
            entry.first_timestamp,
            entry.last_timestamp,
            duration_session_ms(entry),
            entry.total_entries,
            entry.user_messages,
            entry.assistant_messages,
            entry.filepath,
            usage.calls,
            usage.input_tokens,
            usage.output_tokens,
            usage.cache_read_tokens,
            usage.cache_write_tokens,
            usage.total_tokens,
            usage.cost_total,
        ),
    )


def text_allowed(text_mode: str, kind: str) -> bool:
    if text_mode == "full":
        return True
    if text_mode == "compact":
        return True
    if text_mode == "commands" and kind == "command":
        return True
    return False


def ingest_session(
    conn: sqlite3.Connection,
    entry: ScopeEntry,
    usage: UsageTotals,
    *,
    text_mode: str,
    max_output_chars: int,
    max_message_chars: int,
) -> None:
    insert_session(conn, entry, usage)
    filepath = Path(entry.filepath)
    if not filepath.exists():
        return

    tool_calls: list[ToolCallRecord] = []
    tool_results: dict[str, ToolResultRecord] = {}

    with filepath.open() as f:
        for seq, line in enumerate(f, start=1):
            try:
                obj = json.loads(line)
            except json.JSONDecodeError:
                continue
            entry_id = obj.get("id")
            if not isinstance(entry_id, str) or not entry_id:
                entry_id = None
            parent_id = obj.get("parentId")
            if not isinstance(parent_id, str) or not parent_id:
                parent_id = None
            timestamp = str(obj.get("timestamp") or "")
            entry_type = str(obj.get("type") or "")
            message = obj.get("message") if isinstance(obj.get("message"), dict) else {}
            role = str(message.get("role") or "") if message else ""
            conn.execute(
                "insert into entries values (?, ?, ?, ?, ?, ?, ?)",
                (
                    entry.session_id,
                    seq,
                    entry_id,
                    parent_id,
                    timestamp,
                    entry_type,
                    role,
                ),
            )

            if entry_type != "message":
                continue

            text = collect_text_blocks(message.get("content"))
            text_excerpt = None
            if text and text_allowed(text_mode, "message"):
                text_excerpt = compact_text(
                    text,
                    max_chars=max_message_chars
                    if text_mode == "compact"
                    else max(len(text), max_message_chars),
                )
            conn.execute(
                "insert into messages values (?, ?, ?, ?, ?, ?, ?)",
                (
                    entry.session_id,
                    seq,
                    timestamp,
                    role,
                    len(text),
                    text_excerpt,
                    int(bool(message.get("usage"))),
                ),
            )

            if role == "assistant":
                blocks = (
                    message.get("content")
                    if isinstance(message.get("content"), list)
                    else []
                )
                for block in blocks:
                    if not isinstance(block, dict) or block.get("type") != "toolCall":
                        continue
                    tool_name = str(block.get("name") or "<unknown>")
                    args = (
                        block.get("arguments")
                        if isinstance(block.get("arguments"), dict)
                        else {}
                    )
                    command = None
                    category = None
                    if tool_name == "bash":
                        raw_command = str(args.get("command") or "")
                        category = command_category(raw_command)
                        if text_allowed(text_mode, "command"):
                            command = redact(raw_command)
                    call = ToolCallRecord(
                        session_id=entry.session_id,
                        call_seq=seq,
                        call_id=str(block.get("id") or ""),
                        timestamp=timestamp,
                        tool_name=tool_name,
                        command=command,
                        command_category=category,
                    )
                    tool_calls.append(call)
                    conn.execute(
                        "insert into tool_calls values (?, ?, ?, ?, ?, ?, ?)",
                        (
                            call.session_id,
                            call.call_seq,
                            call.timestamp,
                            call.call_id,
                            call.tool_name,
                            call.command,
                            call.command_category,
                        ),
                    )

            if role == "toolResult":
                tool_name = str(message.get("toolName") or "<unknown>")
                content_text = collect_text_blocks(message.get("content"))
                is_error = bool(message.get("isError"))
                exit_status, status_error = output_status(content_text, is_error)
                is_error = bool(is_error or status_error)
                output_excerpt = None
                if text_allowed(text_mode, "output"):
                    output_excerpt = compact_text(
                        content_text,
                        max_chars=max_output_chars
                        if text_mode == "compact"
                        else max(len(content_text), max_output_chars),
                    )
                result = ToolResultRecord(
                    session_id=entry.session_id,
                    result_seq=seq,
                    tool_call_id=str(message.get("toolCallId") or ""),
                    timestamp=timestamp,
                    tool_name=tool_name,
                    is_error=int(is_error),
                    exit_status=exit_status,
                    output_bytes=len(content_text.encode("utf-8", errors="replace")),
                    output_lines=len(content_text.splitlines()) if content_text else 0,
                    output_excerpt=output_excerpt,
                )
                tool_results[result.tool_call_id] = result
                conn.execute(
                    "insert into tool_results values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                    (
                        result.session_id,
                        result.result_seq,
                        result.timestamp,
                        result.tool_call_id,
                        result.tool_name,
                        result.is_error,
                        result.exit_status,
                        result.output_bytes,
                        result.output_lines,
                        result.output_excerpt,
                    ),
                )

    for call in tool_calls:
        result = tool_results.get(call.call_id)
        conn.execute(
            "insert into tool_pairs values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            (
                call.session_id,
                call.call_seq,
                result.result_seq if result else None,
                call.timestamp,
                result.timestamp if result else None,
                duration_ms(call.timestamp, result.timestamp) if result else None,
                call.call_id,
                call.tool_name,
                call.command,
                call.command_category,
                result.is_error if result else None,
                result.exit_status if result else None,
                result.output_bytes if result else None,
                result.output_lines if result else None,
                result.output_excerpt if result else None,
            ),
        )


def build_db(args: argparse.Namespace) -> sqlite3.Connection:
    entries, usage = scope_entries(args)
    conn = sqlite3.connect(":memory:")
    conn.row_factory = sqlite3.Row
    create_schema(conn)
    with conn:
        for entry in entries:
            ingest_session(
                conn,
                entry,
                usage.get(entry.session_id, UsageTotals()),
                text_mode=args.text,
                max_output_chars=args.max_output_chars,
                max_message_chars=args.max_message_chars,
            )
        project_processes(conn, entries)
    return conn
