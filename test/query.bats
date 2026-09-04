#!/usr/bin/env bats

bats_require_minimum_version 1.5.0
load helpers

setup() { setup_test_sessions; }
teardown() { teardown_test_sessions; }

@test "query with no SQL shows schema without scanning sessions" {
  rm -rf "$PI_DIR"
  run sessions query
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "# sessions query"
  echo "$output" | grep -q "bash_calls"
}

@test "query requires an explicit database and refresh boundary" {
  db="$BATS_TEST_TMPDIR/missing.sqlite"
  source=$(find "$PROJECT_DIR" -name "*_${SESSION_1}.jsonl")
  source_hash=$(shasum -a 256 "$source" | awk '{print $1}')

  run sessions query --refresh
  [ "$status" -ne 0 ]
  [[ "$output" == *"--refresh requires --db"* ]]

  run sessions query --db "$db" --sql "select count(*) from sessions"
  [ "$status" -ne 0 ]
  [[ "$output" == *"create it with --refresh"* ]]
  [ ! -e "$db" ]

  run sessions query "${SESSION_1:0:8}" --db "$source" --refresh \
    --sql "select count(*) from sessions"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Refusing to replace session source"* ]]
  [ "$(shasum -a 256 "$source" | awk '{print $1}')" = "$source_hash" ]
}

@test "query refreshes and reuses a private database with visible freshness" {
  caller="$BATS_TEST_TMPDIR/caller"
  mkdir -p "$caller"
  export SESSIONS_CALLER_PWD="$caller"
  db="$caller/query?private.sqlite"
  requested_db="query?private.sqlite"
  file=$(find "$PROJECT_DIR" -name "*_${SESSION_1}.jsonl")

  run --separate-stderr sessions query "${SESSION_1:0:8}" \
    --db "$requested_db" --refresh \
    --sql "select count(*) as entries from entries" --format json
  [ "$status" -eq 0 ]
  [ -f "$db" ]
  [ ! -e "$caller/query" ]
  echo "$output" | python3 -c 'import json, sys; assert json.load(sys.stdin)[0]["entries"] == 9'
  python3 -c 'import os, sys; assert os.stat(sys.argv[1]).st_mode & 0o777 == 0o600' "$db"
  [[ "$stderr" == *"database: fresh"* ]]
  [[ "$stderr" == *"scope=selected=1"* ]]

  printf '%s\n' '{"type":"custom","id":"later","parentId":"a1","timestamp":"2026-03-14T10:02:00.000Z"}' >> "$file"

  run --separate-stderr sessions query --db "$requested_db" \
    --sql "select count(*) as entries from entries" --format json
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c 'import json, sys; assert json.load(sys.stdin)[0]["entries"] == 9'
  [[ "$stderr" == *"database: stale"* ]]
  [[ "$stderr" == *"changed=1"* ]]

  run --separate-stderr sessions query "${SESSION_1:0:8}" \
    --db "$requested_db" --refresh \
    --sql "select count(*) as entries from entries" --format json
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c 'import json, sys; assert json.load(sys.stdin)[0]["entries"] == 10'
  [[ "$stderr" == *"database: fresh"* ]]

  db_hash=$(shasum -a 256 "$db" | awk '{print $1}')
  run sessions query --db "$requested_db" --out "$requested_db" \
    --sql "select count(*) from sessions"
  [ "$status" -ne 0 ]
  [[ "$output" == *"--out must not replace the --db projection"* ]]
  [ "$(shasum -a 256 "$db" | awk '{print $1}')" = "$db_hash" ]
}

@test "query refresh can build a reusable database without SQL" {
  db="$BATS_TEST_TMPDIR/query.sqlite"

  run --separate-stderr sessions query "${SESSION_1:0:8}" \
    --db "$db" --refresh --text none

  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -f "$db" ]
  [[ "$stderr" == *"database: fresh"* ]]
  python3 - "$db" <<'PY'
import sqlite3
import sys

with sqlite3.connect(sys.argv[1]) as conn:
    assert conn.execute("select count(*) from sessions").fetchone()[0] == 1
PY
}

@test "query rejects incompatible reusable databases without a traceback" {
  db="$BATS_TEST_TMPDIR/incompatible.sqlite"
  python3 - "$db" <<'PY'
import sqlite3
import sys

with sqlite3.connect(sys.argv[1]) as conn:
    conn.execute("create table projection_meta (key text primary key, value text not null)")
    conn.executemany("insert into projection_meta values (?, ?)", [
        ("schema_version", "1"),
        ("built_at", "2026-09-03T00:00:00+00:00"),
        ("text_mode", "none"),
        ("project", ""),
        ("limit", "20"),
        ("session_ids", '["aaaaaaaa"]'),
    ])
    conn.execute("create table projection_sources (source_key text, state_key text)")
PY

  run --separate-stderr sessions query --db "$db" --sql "select 1"

  [ "$status" -ne 0 ]
  [ -z "$output" ]
  [[ "$stderr" == *"Not a sessions query database"* ]]
  [[ "$stderr" != *"Traceback"* ]]
}

@test "query freshness includes corpus candidates omitted from the projection" {
  db="$BATS_TEST_TMPDIR/corpus.sqlite"
  candidate="$PROJECT_DIR/newest-invalid.jsonl"
  printf '%s\n' 'not-json' > "$candidate"
  touch "$candidate"

  run --separate-stderr sessions query --project test/project --limit 2 \
    --db "$db" --refresh --text none \
    --sql "select count(*) as sessions, \
                  (select count(*) from projection_sources) as candidates, \
                  (select min(length(source_key)) from projection_sources) as key_chars, \
                  (select min(length(state_key)) from projection_sources) as state_chars \
           from sessions" --format json
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c '
import json, sys
row = json.load(sys.stdin)[0]
assert row["sessions"] == 2, row
assert row["candidates"] > row["sessions"], row
assert row["key_chars"] == 64, row
assert row["state_chars"] == 64, row
'
  [[ "$stderr" == *"database: fresh"* ]]
  [[ "$stderr" == *"scope=project=test/project,limit=2"* ]]

  printf '%s\n' 'still-not-json' >> "$candidate"

  run --separate-stderr sessions query --db "$db" \
    --sql "select count(*) as sessions from sessions" --format json
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"database: stale"* ]]
  [[ "$stderr" == *"changed=1"* ]]
}

@test "query marks a source change during refresh as stale" {
  db="$BATS_TEST_TMPDIR/raced.sqlite"
  source=$(find "$PROJECT_DIR" -name "*_${SESSION_1}.jsonl")

  run env PYTHONPATH="$REPO_DIR/lib" python3 - "$db" "$source" "${SESSION_1:0:8}" <<'PY'
import sys
from pathlib import Path
from unittest.mock import patch

from query import snapshot
from query.cli import parse_args

path = Path(sys.argv[1])
source = Path(sys.argv[2])
args = parse_args([sys.argv[3], "--db", str(path), "--refresh", "--text", "none"])
original = snapshot.build_db


def build_then_change(namespace):
    connection = original(namespace)
    with source.open("a") as handle:
        handle.write('{"type":"custom","id":"during-build"}\n')
    return connection


with patch.object(snapshot, "build_db", side_effect=build_then_change):
    connection = snapshot.refresh_snapshot(args, path)
try:
    freshness = snapshot._freshness(connection)
finally:
    connection.close()
assert "database: stale" in freshness, freshness
assert "changed=1" in freshness, freshness
PY

  [ "$status" -eq 0 ]
}

@test "query refresh failure preserves the old database and removes its temporary" {
  db="$BATS_TEST_TMPDIR/existing.sqlite"
  printf '%s' 'existing database' > "$db"

  run env PYTHONPATH="$REPO_DIR/lib" python3 - "$db" "${SESSION_1:0:8}" <<'PY'
import sys
from pathlib import Path
from unittest.mock import patch

from query import snapshot
from query.cli import parse_args

path = Path(sys.argv[1])
args = parse_args([sys.argv[2], "--db", str(path), "--refresh", "--text", "none"])
with patch.object(snapshot.os, "replace", side_effect=OSError("injected failure")):
    try:
        snapshot.refresh_snapshot(args, path)
    except OSError as exc:
        assert str(exc) == "injected failure", exc
    else:
        raise AssertionError("refresh unexpectedly replaced the target")
assert path.read_bytes() == b"existing database"
assert list(path.parent.glob(f".{path.name}.*.tmp")) == []
PY

  [ "$status" -eq 0 ]
}

@test "query projection indexes parent and tool-call identity lookups" {
  run sessions query "${SESSION_1:0:8}" --sql "
select name
from sqlite_master
where type = 'index'
  and name in ('entries_session_entry_id', 'tool_calls_session_call_id')
order by name
" --format json

  [ "$status" -eq 0 ]
  echo "$output" | python3 -c "
import json, sys
assert [row['name'] for row in json.load(sys.stdin)] == [
    'entries_session_entry_id',
    'tool_calls_session_call_id',
]
"
}

@test "query supports single-session prefix scope" {
  run sessions query "${SESSION_1:0:8}" \
    --sql "select session_id, project, total_entries from sessions" \
    --format json
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c "
import json, sys
rows = json.load(sys.stdin)
assert len(rows) == 1, rows
assert rows[0]['session_id'] == '${SESSION_1}'
assert rows[0]['project'] == 'test/project'
assert rows[0]['total_entries'] > 0
"
}

@test "query projects addressable entries and parent links" {
  run sessions query "${SESSION_1:0:8}" --sql "
select seq, entry_id, parent_id, type, role
from entries
where seq between 1 and 3
order by seq
" --format json

  [ "$status" -eq 0 ]
  echo "$output" | python3 -c "
import json, sys
rows = json.load(sys.stdin)
assert rows == [
    {
        'seq': 1,
        'entry_id': '${SESSION_1}',
        'parent_id': None,
        'type': 'session',
        'role': '',
    },
    {
        'seq': 2,
        'entry_id': 'mc1',
        'parent_id': None,
        'type': 'model_change',
        'role': '',
    },
    {
        'seq': 3,
        'entry_id': 'u1',
        'parent_id': 'mc1',
        'type': 'message',
        'role': 'user',
    },
], rows
"
}

@test "query retains the events compatibility view" {
  run sessions query "${SESSION_1:0:8}" --sql "
select * from events where seq = 3
" --format json

  [ "$status" -eq 0 ]
  echo "$output" | python3 -c "
import json, sys
rows = json.load(sys.stdin)
assert rows == [{
    'session_id': '${SESSION_1}',
    'seq': 3,
    'timestamp': '2026-03-14T10:00:01.000Z',
    'type': 'message',
    'role': 'user',
}], rows
"
}

@test "query projects generic session metadata as JSON" {
  run sessions query --project test/project --limit 10 --sql "
select session_id,
       meta is null as meta_is_null,
       json_valid(meta) as meta_is_valid,
       json_extract(meta, '$.agent.name') as agent_name,
       json_extract(meta, '$.purpose') as purpose
from sessions
where session_id in ('${SESSION_1}', '${SESSION_3}')
order by session_id
" --format json

  [ "$status" -eq 0 ]
  echo "$output" | python3 -c "
import json, sys
rows = json.load(sys.stdin)
assert rows == [
    {
        'session_id': '${SESSION_3}',
        'meta_is_null': 0,
        'meta_is_valid': 1,
        'agent_name': 'ikma',
        'purpose': 'scout-report',
    },
    {
        'session_id': '${SESSION_1}',
        'meta_is_null': 1,
        'meta_is_valid': None,
        'agent_name': None,
        'purpose': None,
    },
], rows
"
}

@test "query projects managed process lifecycle and live status" {
  local session_file="${PROJECT_DIR}2026-03-14T10-00-00-000Z_${SESSION_1}.jsonl"
  local live_pid="$$"
  local live_start
  live_start=$(PYTHONPATH="$REPO_DIR/lib" python3 -c \
    'import processes, sys; print(processes.process_start_time_token(int(sys.argv[1])))' \
    "$live_pid")
  [ -n "$live_start" ]

  cat >> "$session_file" <<JSONL
{"type":"process_start","id":"process-live","timestamp":"2026-03-14T10:31:00.000Z","pid":${live_pid},"pid_start_time":"${live_start}","cwd":"/test/project","harness":"pi","model":"test-model","headless":true}
{"type":"process_start","id":"process-exited","timestamp":"2026-03-14T10:32:00.000Z","pid":999999,"pid_start_time":"test:old","cwd":"/test/project","harness":"pi","model":"test-model","headless":false}
{"type":"process_exit","id":"exit-old","timestamp":"2026-03-14T10:33:00.000Z","process_start_id":"process-exited","exit_code":0}
JSONL

  run sessions query "${SESSION_1:0:8}" --sql "
select session_id, process_start_id, pid, pid_start_time, status,
       started_at, exited_at, exit_code, cwd, harness, model, headless
from processes
order by started_at
" --format json

  [ "$status" -eq 0 ]
  echo "$output" | python3 -c "
import json, sys
rows = json.load(sys.stdin)
assert rows == [
    {
        'session_id': '${SESSION_1}',
        'process_start_id': 'process-live',
        'pid': ${live_pid},
        'pid_start_time': '${live_start}',
        'status': 'live',
        'started_at': '2026-03-14T10:31:00.000Z',
        'exited_at': None,
        'exit_code': None,
        'cwd': '/test/project',
        'harness': 'pi',
        'model': 'test-model',
        'headless': 1,
    },
    {
        'session_id': '${SESSION_1}',
        'process_start_id': 'process-exited',
        'pid': 999999,
        'pid_start_time': 'test:old',
        'status': 'exited',
        'started_at': '2026-03-14T10:32:00.000Z',
        'exited_at': '2026-03-14T10:33:00.000Z',
        'exit_code': 0,
        'cwd': '/test/project',
        'harness': 'pi',
        'model': 'test-model',
        'headless': 0,
    },
], rows
"
}

@test "query supports encoded project and limit corpus scope" {
  run sessions query --project "--test-project--" --limit 2 \
    --sql "select count(*) as n from sessions" \
    --format json
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c "
import json, sys
rows = json.load(sys.stdin)
assert rows == [{'n': 2}], rows
"
}

@test "query corpus includes sessions regardless of filename prefix" {
  cat > "${PROJECT_DIR}agent-abc1234.jsonl" <<JSONL
{"type":"session","version":3,"id":"agent-abc1234","timestamp":"2026-03-15T15:00:00.000Z","cwd":"/test/project"}
{"type":"model_change","id":"mc1","parentId":null,"timestamp":"2026-03-15T15:00:00.001Z","provider":"test","modelId":"test-model"}
{"type":"message","id":"u1","parentId":"mc1","timestamp":"2026-03-15T15:00:01.000Z","message":{"role":"user","content":[{"type":"text","text":"test"}]}}
{"type":"message","id":"a1","parentId":"u1","timestamp":"2026-03-15T15:00:02.000Z","message":{"role":"assistant","content":[{"type":"text","text":"done"}],"model":"test-model","provider":"test"}}
JSONL

  run sessions query --project test/project --limit 10 \
    --sql "select session_id from sessions where session_id = 'agent-abc1234'" \
    --format json

  [ "$status" -eq 0 ]
  echo "$output" | python3 -c "
import json, sys
rows = json.load(sys.stdin)
assert rows == [{'session_id': 'agent-abc1234'}], rows
"
}

@test "query rejects mutating SQL" {
  run sessions query --sql "delete from sessions" --format json
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "Only read-only"
}

@test "query rejects non-positive display and text budgets" {
  run sessions query "${SESSION_1:0:8}" --sql "select 'abc' as value" --format grid --max-col-width 0
  [ "$status" -ne 0 ]
  echo "$output" | grep -q -- "--max-col-width: must be greater than 0"

  run sessions query "${SESSION_1:0:8}" --text compact --max-output-chars 0 --sql "select output_excerpt from bash_calls limit 1" --format json
  [ "$status" -ne 0 ]
  echo "$output" | grep -q -- "--max-output-chars: must be greater than 0"

  run sessions query "${SESSION_1:0:8}" --format grid --max-cell-lines -1 --sql "select 'abc' as value"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q -- "--max-cell-lines: must be greater than or equal to 0"
}

@test "query redacts common secret command shapes" {
  run python3 - <<'PY'
import sys
sys.path.insert(0, "lib")
from query.util import compact_text, redact

samples = [
    "TOKEN=plain gh api user",
    "TOKEN='quoted secret' gh api user",
    'TOKEN="double quoted" gh api user',
    "curl -H 'Authorization: Bearer bearer-secret' https://example.test",
    "tool --password hunter2 --token tok123",
]
redacted = "\n".join(redact(sample) for sample in samples)
assert "plain" not in redacted
assert "quoted secret" not in redacted
assert "double quoted" not in redacted
assert "bearer-secret" not in redacted
assert "hunter2" not in redacted
assert "tok123" not in redacted
assert compact_text("sensitive", max_chars=0) == ""
PY
  [ "$status" -eq 0 ]
}

@test "query default text mode exposes redacted bash commands but not messages or output" {
  run sessions query "${SESSION_1:0:8}" --sql "
select
  b.command,
  b.output_excerpt,
  (select text_excerpt from messages where role = 'user' limit 1) as message_excerpt
from bash_calls b
limit 1
" --format json
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c "
import json, sys
rows = json.load(sys.stdin)
assert len(rows) == 1, rows
row = rows[0]
assert row['command'] == 'cat ~/.config/sccache/config', row
assert row['output_excerpt'] is None, row
assert row['message_excerpt'] is None, row
"
}

@test "query compact text mode exposes bounded output excerpts" {
  run sessions query "${SESSION_1:0:8}" --text compact --sql "
select command, output_excerpt
from bash_calls
limit 1
" --format json
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c "
import json, sys
rows = json.load(sys.stdin)
assert len(rows) == 1, rows
row = rows[0]
assert row['command'] == 'cat ~/.config/sccache/config', row
assert '[cache]' in row['output_excerpt'], row
"
}

@test "query bash status fixture includes bash call metadata" {
  run sessions query "${SESSION_1:0:8}" --sql "
select command_category, exit_status, is_error, output_lines
from bash_calls
limit 1
" --format json
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c "
import json, sys
rows = json.load(sys.stdin)
assert rows == [{
    'command_category': 'file-op',
    'exit_status': None,
    'is_error': 0,
    'output_lines': 2,
}], rows
"
}

@test "query can read packaged SQL presets when caller cwd differs" {
  export SESSIONS_CALLER_PWD="$BATS_TEST_TMPDIR"
  run sessions query "${SESSION_1:0:8}" --sql-file queries/bash-status.sql --format json
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c "
import json, sys
rows = json.load(sys.stdin)
assert len(rows) == 1, rows
assert rows[0]['command'] == 'cat ~/.config/sccache/config', rows
"
}

@test "query bundled analysis examples execute against one projection" {
  db="$BATS_TEST_TMPDIR/examples.sqlite"
  run --separate-stderr sessions query "${SESSION_1:0:8}" \
    --db "$db" --refresh --text commands
  [ "$status" -eq 0 ]

  for preset in \
    agent-activity \
    agent-segment-density \
    attribution-health \
    bash-failure-recovery \
    bash-size-risk \
    intentional-waits \
    tool-pair-integrity
  do
    run --separate-stderr sessions query --db "$db" \
      --sql-file "queries/$preset.sql" --format json
    if [ "$status" -ne 0 ]; then
      echo "$preset failed: $output $stderr" >&3
      return 1
    fi
    echo "$output" | python3 -m json.tool >/dev/null
  done
}
