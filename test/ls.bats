#!/usr/bin/env bats

load helpers

setup() { setup_test_sessions; }
teardown() { teardown_test_sessions; }

@test "ls shows sessions" {
  run python3 "$TASKS_DIR/ls"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "${SESSION_1:0:8}"
  echo "$output" | grep -q "${SESSION_2:0:8}"
}

@test "ls shows sessions sorted by mtime (newest first)" {
  run python3 "$TASKS_DIR/ls"
  [ "$status" -eq 0 ]
  # SESSION_2 was touched after SESSION_1, so it should appear first
  line_2=$(echo "$output" | grep "${SESSION_2:0:8}")
  line_1=$(echo "$output" | grep "${SESSION_1:0:8}")
  pos_2=$(echo "$output" | grep -n "${SESSION_2:0:8}" | head -1 | cut -d: -f1)
  pos_1=$(echo "$output" | grep -n "${SESSION_1:0:8}" | head -1 | cut -d: -f1)
  [ "$pos_2" -lt "$pos_1" ]
}

@test "ls respects --limit" {
  export usage_limit="1"
  run python3 "$TASKS_DIR/ls"
  [ "$status" -eq 0 ]
  # Should only show 1 session (the newest)
  count=$(echo "$output" | grep -c "^  [0-9a-f]" || true)
  [ "$count" -eq 1 ]
}

@test "ls --json outputs valid JSON" {
  export usage_json="true"
  run python3 "$TASKS_DIR/ls"
  [ "$status" -eq 0 ]
  echo "$output" | python3 -m json.tool > /dev/null
}

@test "ls --json includes session metadata" {
  export usage_json="true"
  run python3 "$TASKS_DIR/ls"
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c "
import json, sys
data = json.load(sys.stdin)
assert len(data) == 2, f'expected 2 sessions, got {len(data)}'
assert all('session_id' in s for s in data)
assert all('model' in s for s in data)
"
}

@test "ls shows message counts" {
  run python3 "$TASKS_DIR/ls"
  [ "$status" -eq 0 ]
  # Session 1 has 4 user + 4 assistant = 8 messages total
  # (queue-operation entries are not counted)
  echo "$output" | grep "${SESSION_1:0:8}" | grep -qE "[[:space:]]+8$"
}

@test "ls shows model name" {
  run python3 "$TASKS_DIR/ls"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "claude-opus-4-6"
}

@test "ls excludes agent- prefixed files by default" {
  echo '{"type":"user","message":{"role":"user","content":"test"},"sessionId":"agent-test","timestamp":"2026-03-15T15:00:00.000Z"}' > "${PROJECT_DIR}agent-abc1234.jsonl"
  run python3 "$TASKS_DIR/ls"
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -q "agent-abc"
}

@test "ls --all includes agent sessions" {
  echo '{"type":"user","message":{"role":"user","content":"test"},"sessionId":"agent-abc1234","timestamp":"2026-03-15T15:00:00.000Z"}' > "${PROJECT_DIR}agent-abc1234.jsonl"
  export usage_all="true"
  run python3 "$TASKS_DIR/ls"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "agent-ab"
}

@test "ls errors when sessions dir missing" {
  rm -rf "$CLAUDE_DIR"
  run python3 "$TASKS_DIR/ls"
  [ "$status" -eq 1 ]
  echo "$output" | grep -qi "no sessions"
}
