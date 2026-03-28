#!/usr/bin/env bats

load helpers

setup() { setup_test_sessions; }
teardown() { teardown_test_sessions; }

@test "list shows sessions" {
  run sessions list
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "${SESSION_1:0:8}"
  echo "$output" | grep -q "${SESSION_2:0:8}"
}

@test "list shows sessions sorted by mtime (newest first)" {
  run sessions list
  [ "$status" -eq 0 ]
  # SESSION_2 was touched after SESSION_1, so it should appear first
  pos_2=$(echo "$output" | grep -n "${SESSION_2:0:8}" | head -1 | cut -d: -f1)
  pos_1=$(echo "$output" | grep -n "${SESSION_1:0:8}" | head -1 | cut -d: -f1)
  [ "$pos_2" -lt "$pos_1" ]
}

@test "list respects --limit" {
  run sessions list --limit 1
  [ "$status" -eq 0 ]
  # Should only show 1 session (the newest)
  count=$(echo "$output" | grep -c "^  [0-9a-f]" || true)
  [ "$count" -eq 1 ]
}

@test "list --json outputs valid JSON" {
  run sessions list --json
  [ "$status" -eq 0 ]
  echo "$output" | python3 -m json.tool > /dev/null
}

@test "list --json includes session metadata" {
  run sessions list --json
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c "
import json, sys
data = json.load(sys.stdin)
assert len(data) == 2, f'expected 2 sessions, got {len(data)}'
assert all('session_id' in s for s in data)
assert all('model' in s for s in data)
"
}

@test "list shows message counts" {
  run sessions list
  [ "$status" -eq 0 ]
  # Session 1 has 3 user + 3 assistant = 6 messages
  # (toolResult entries are not counted as user/assistant)
  # Rich table adds trailing padding, so match with surrounding whitespace
  echo "$output" | grep "${SESSION_1:0:8}" | grep -qE "[[:space:]]+6[[:space:]]*$"
}

@test "list shows model name" {
  run sessions list
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "claude-opus-4-6"
}

@test "list excludes agent- prefixed files by default" {
  echo '{"type":"user","message":{"role":"user","content":"test"},"sessionId":"agent-test","timestamp":"2026-03-15T15:00:00.000Z"}' > "${PROJECT_DIR}agent-abc1234.jsonl"
  run sessions list
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -q "agent-abc"
}

@test "list --all includes agent sessions" {
  echo '{"type":"user","message":{"role":"user","content":"test"},"sessionId":"agent-abc1234","timestamp":"2026-03-15T15:00:00.000Z"}' > "${PROJECT_DIR}agent-abc1234.jsonl"
  run sessions list --all
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "agent-ab"
}

@test "list errors when sessions dir missing" {
  rm -rf "$PI_DIR"
  run sessions list
  [ "$status" -eq 1 ]
  echo "$output" | grep -qi "no sessions"
}
