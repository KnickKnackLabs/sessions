from __future__ import annotations


def schema_text() -> str:
    return """# sessions query

Build a SQLite projection over local session JSONL files. The JSONL session store
remains the source of truth; no durable DB is required. Pass `--db PATH --refresh`
to atomically build an explicit reusable projection, then use `--db PATH` for
later queries. Refresh can run without SQL. Reuse queries the stored
scope and text mode, reports source drift, and never silently rebuilds; the
default still builds a fresh ephemeral projection.

Default text mode is `commands`: bash command text is redacted and queryable, but
message text and tool output text are not inserted. Use `--text none` for fully
structural queries, `--text compact` for compacted excerpts, or `--text full`
only with explicit local privacy approval.

Tables/views:

- `sessions(session_id, runtime, project, name, slug, meta, model, first_timestamp,
  last_timestamp, duration_ms, total_entries, user_messages,
  assistant_messages, filepath, calls, *_tokens, cost_total)`
- `processes(session_id, process_start_id, pid, pid_start_time, status,
  started_at, exited_at, exit_code, cwd, harness, model, headless)`
- `entries(session_id, seq, entry_id, parent_id, timestamp, type, role)`
- `events(session_id, seq, timestamp, type, role)` compatibility view
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
- reusable databases also include `projection_meta` and `projection_sources`;
  the latter records opaque candidate-source fingerprints from before the build

The projection indexes `(session_id, entry_id)` and `(session_id, tool_call_id)`
for lineage and pairing queries. Scope and text flags affect new projections,
including `--refresh`; they do not reshape an existing `--db` projection.

`sessions.meta` contains generic session-header metadata as JSON, or `NULL` when
none exists. Use SQLite JSON functions such as `json_extract(meta, '$.agent.name')`
to query caller-defined metadata without baking those conventions into Sessions.

Examples:

```sh
sessions query --project junior/home --limit 30 --sql-file queries/bash-status.sql --format grid
sessions query --limit 10000 --sql-file queries/attribution-health.sql --format grid
sessions query --limit 10000 --sql-file queries/agent-activity.sql --format grid
sessions query --limit 10000 --sql-file queries/agent-segment-density.sql --browser
sessions query --sql-file queries/bash-failure-recovery.sql --browser
sessions query --sql-file queries/bash-size-risk.sql --format grid
sessions query --sql-file queries/intentional-waits.sql --browser
sessions query --sql-file queries/tool-pair-integrity.sql --format grid
sessions query --db /tmp/sessions.sqlite --refresh --sql 'select count(*) from sessions'
sessions query --db /tmp/sessions.sqlite --sql-file queries/bash-status.sql --format grid
sessions query 019ed94e --sql 'select * from bash_calls where is_error = 1 limit 20' --format grid
sessions query --text compact --sql-file queries/bash-with-output.sql --format jsonl
sessions query --project junior/home --limit 30 --sql-file queries/bash-status.sql --browser
```
"""
