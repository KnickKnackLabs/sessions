#!/usr/bin/env bats

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

@test "query supports project and limit corpus scope" {
  run sessions query --project test/project --limit 2 \
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
