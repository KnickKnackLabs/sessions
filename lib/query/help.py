from __future__ import annotations


def schema_text() -> str:
    return """# sessions query

Build an ephemeral SQLite projection over local session JSONL files. The JSONL
session store remains the source of truth; no durable DB is required.

Default text mode is `commands`: bash command text is redacted and queryable, but
message text and tool output text are not inserted. Use `--text none` for fully
structural queries, `--text compact` for compacted excerpts, or `--text full`
only with explicit local privacy approval.

Tables/views:

- `sessions(session_id, runtime, project, name, model, first_timestamp,
  last_timestamp, duration_ms, total_entries, user_messages,
  assistant_messages, filepath, calls, *_tokens, cost_total)`
- `processes(session_id, process_start_id, pid, pid_start_time, status,
  started_at, exited_at, exit_code, cwd, harness, model, headless)`
- `events(session_id, seq, timestamp, type, role)`
- `messages(session_id, seq, timestamp, role, text_chars, text_excerpt,
  has_usage)`
- `tool_calls(session_id, seq, timestamp, tool_call_id, tool_name, command,
  command_category)`
- `tool_results(session_id, seq, timestamp, tool_call_id, tool_name, is_error,
  exit_status, output_bytes, output_lines, output_excerpt)`
- `tool_pairs(session_id, call_seq, result_seq, start_timestamp, end_timestamp,
  duration_ms, tool_call_id, tool_name, command, command_category, is_error,
  exit_status, output_bytes, output_lines, output_excerpt)`
- `bash_calls` view over `tool_pairs where tool_name = 'bash'`

Examples:

```sh
sessions query --project junior/home --limit 30 --sql-file queries/bash-status.sql --format grid
sessions query 019ed94e --sql 'select * from bash_calls where is_error = 1 limit 20' --format grid
sessions query --text compact --sql-file queries/bash-with-output.sql --format jsonl
sessions query --project junior/home --limit 30 --sql-file queries/bash-status.sql --browser
```
"""
