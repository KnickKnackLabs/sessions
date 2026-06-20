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

@test "query rejects mutating SQL" {
  run sessions query --sql "delete from sessions" --format json
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "Only read-only"
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
  run env SESSIONS_CALLER_PWD="$BATS_TEST_TMPDIR" PI_DIR="$PI_DIR" \
    bash -c "cd '$REPO_DIR' && mise run -q query -- '${SESSION_1:0:8}' --sql-file queries/bash-status.sql --format json"
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c "
import json, sys
rows = json.load(sys.stdin)
assert len(rows) == 1, rows
assert rows[0]['command'] == 'cat ~/.config/sccache/config', rows
"
}
