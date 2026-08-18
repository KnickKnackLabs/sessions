#!/usr/bin/env bats

bats_require_minimum_version 1.5.0
load helpers

setup() { setup_test_sessions; }
teardown() { teardown_test_sessions; }

session_path() {
  printf '%s\n' "$PROJECT_DIR"*"_$1.jsonl"
}

append_assistant_text() {
  local file="$1"
  local id="$2"
  local text="$3"
  cat >> "$file" <<JSONL
{"type":"message","id":"$id","parentId":"wait-any-test","timestamp":"2026-08-18T14:00:00.000Z","message":{"role":"assistant","content":[{"type":"text","text":"$text"}],"model":"gpt-5.6-sol","provider":"openai-codex","stopReason":"stop","timestamp":1787061600000}}
JSONL
}

append_assistant_tool_turn() {
  local file="$1"
  local id="$2"
  local text="$3"
  cat >> "$file" <<JSONL
{"type":"message","id":"$id","parentId":"wait-any-test","timestamp":"2026-08-18T14:00:00.000Z","message":{"role":"assistant","content":[{"type":"text","text":"$text"},{"type":"toolCall","id":"tc-$id","name":"bash","arguments":{"command":"printf working"}}],"model":"gpt-5.6-sol","provider":"openai-codex","stopReason":"toolUse","timestamp":1787061600000}}
JSONL
}

append_assistant_error() {
  local file="$1"
  local id="$2"
  cat >> "$file" <<JSONL
{"type":"message","id":"$id","parentId":"wait-any-test","timestamp":"2026-08-18T14:00:00.000Z","message":{"role":"assistant","content":[],"model":"gpt-5.6-sol","provider":"openai-codex","stopReason":"error","errorMessage":"provider usage limit","timestamp":1787061600000}}
JSONL
}

write_watch_config() {
  local path="$1"
  cat > "$path" <<JSON
{"version":1,"watches":[
  {"name":"alpha","session_id":"$SESSION_1"},
  {"name":"beta","session_id":"$SESSION_2"}
]}
JSON
}

wait_for_cursor() {
  local cursor="$1"
  local attempts=0
  while [ ! -f "$cursor" ] && [ "$attempts" -lt 100 ]; do
    sleep 0.05
    attempts=$((attempts + 1))
  done
  [ -f "$cursor" ]
}

@test "wait-any snapshots past existing settled turns by default" {
  run --separate-stderr sessions wait-any "$SESSION_1" \
    --timeout 0.15 --interval 0.05 --json

  [ "$status" -eq 124 ]
  echo "$output" | python3 -c '
import json, sys
assert json.load(sys.stdin)["event"] == "timeout"
'
}

@test "wait-any returns the first structural settled turn" {
  file_one=$(session_path "$SESSION_1")
  file_two=$(session_path "$SESSION_2")
  cursor="$BATS_TEST_TMPDIR/cursors.json"
  (
    wait_for_cursor "$cursor"
    append_assistant_tool_turn "$file_one" "a-any-working" "still running a tool"
    sleep 0.1
    append_assistant_text "$file_two" "a-any-settled" "beta is ready"
  ) &
  appender=$!

  run sessions wait-any "$SESSION_1" "$SESSION_2" \
    --cursor-file "$cursor" --timeout 5 --interval 0.05
  wait "$appender"

  [ "$status" -eq 0 ]
  echo "$output" | grep -q "beta is ready"
  echo "$output" | grep -q "${SESSION_2:0:8}"
  ! echo "$output" | grep -q "still running a tool"
}

@test "wait-any returns empty provider failures as settled events" {
  file=$(session_path "$SESSION_1")
  cursor="$BATS_TEST_TMPDIR/cursors.json"
  (
    wait_for_cursor "$cursor"
    append_assistant_error "$file" "a-any-error"
  ) &
  appender=$!

  run sessions wait-any "$SESSION_1" --cursor-file "$cursor" \
    --timeout 5 --interval 0.05 --json
  wait "$appender"

  [ "$status" -eq 0 ]
  echo "$output" | python3 -c '
import json, sys
result = json.load(sys.stdin)
assert result["event"] == "turn.settled"
assert len(result["events"]) == 1
event = result["events"][0]
assert event["stop_reason"] == "error"
assert event["error"] == "provider usage limit"
assert event["text"] == ""
'
}

@test "wait-any returns every settled turn observed in the winning poll" {
  file_one=$(session_path "$SESSION_1")
  file_two=$(session_path "$SESSION_2")
  cursor="$BATS_TEST_TMPDIR/cursors.json"
  (
    wait_for_cursor "$cursor"
    append_assistant_text "$file_one" "a-any-batch-1" "alpha settled"
    append_assistant_text "$file_two" "a-any-batch-2" "beta settled"
  ) &
  appender=$!

  run sessions wait-any "$SESSION_1" "$SESSION_2" \
    --cursor-file "$cursor" --timeout 5 --interval 0.3 --json
  wait "$appender"

  [ "$status" -eq 0 ]
  echo "$output" | python3 -c '
import json, sys
result = json.load(sys.stdin)
assert [event["source"] for event in result["events"]] == [
    "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
    "11111111-2222-3333-4444-555555555555",
]
'
}

@test "wait-any config assigns stable source names" {
  config="$BATS_TEST_TMPDIR/watches.json"
  cursor="$BATS_TEST_TMPDIR/cursors.json"
  write_watch_config "$config"
  file=$(session_path "$SESSION_2")
  (
    wait_for_cursor "$cursor"
    append_assistant_text "$file" "a-any-named" "named beta settled"
  ) &
  appender=$!

  run sessions wait-any --config "$config" --cursor-file "$cursor" \
    --timeout 5 --interval 0.05 --json
  wait "$appender"

  [ "$status" -eq 0 ]
  echo "$output" | python3 -c '
import json, sys
result = json.load(sys.stdin)
assert result["events"][0]["source"] == "beta"
'
}

@test "wait-any cursor file preserves events between invocations" {
  config="$BATS_TEST_TMPDIR/watches.json"
  cursor="$BATS_TEST_TMPDIR/cursors.json"
  write_watch_config "$config"

  run --separate-stderr sessions wait-any --config "$config" \
    --cursor-file "$cursor" --timeout 0.15 --interval 0.05 --json
  [ "$status" -eq 124 ]
  [ -f "$cursor" ]
  echo "$output" | python3 -c '
import json, sys
assert json.load(sys.stdin)["event"] == "timeout"
'

  append_assistant_text "$(session_path "$SESSION_1")" \
    "a-any-between" "arrived between waits"

  run sessions wait-any --config "$config" --cursor-file "$cursor" \
    --timeout 2 --interval 0.05 --json
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c '
import json, sys
result = json.load(sys.stdin)
assert result["events"][0]["source"] == "alpha"
assert result["events"][0]["text"] == "arrived between waits"
'
  python3 - "$cursor" <<'PY'
import json, pathlib, sys
text = pathlib.Path(sys.argv[1]).read_text()
state = json.loads(text)
assert "arrived between waits" not in text
assert set(state["sessions"]) == {
    "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
    "11111111-2222-3333-4444-555555555555",
}
assert {entry["harness"] for entry in state["sessions"].values()} == {"pi"}
PY

  run --separate-stderr sessions wait-any --config "$config" \
    --cursor-file "$cursor" --timeout 0.15 --interval 0.05 --json
  [ "$status" -eq 124 ]
}

@test "wait-any cursor does not consume a partial JSONL entry" {
  cursor="$BATS_TEST_TMPDIR/cursors.json"
  file=$(session_path "$SESSION_1")

  run --separate-stderr sessions wait-any "$SESSION_1" \
    --cursor-file "$cursor" --timeout 0.15 --interval 0.05 --json
  [ "$status" -eq 124 ]

  printf '%s' '{"type":"message","id":"a-any-partial","timestamp":"2026-08-18T14:00:00.000Z","message":{"role":"assistant","content":[' >> "$file"
  run --separate-stderr sessions wait-any "$SESSION_1" \
    --cursor-file "$cursor" --timeout 0.15 --interval 0.05 --json
  [ "$status" -eq 124 ]

  printf '%s\n' '{"type":"text","text":"complete after partial"}],"stopReason":"stop"}}' >> "$file"
  run sessions wait-any "$SESSION_1" --cursor-file "$cursor" \
    --timeout 2 --interval 0.05 --json

  [ "$status" -eq 0 ]
  echo "$output" | python3 -c '
import json, sys
result = json.load(sys.stdin)
assert result["events"][0]["text"] == "complete after partial"
'
}

@test "wait-any clears inherited optional usage values" {
  file=$(session_path "$SESSION_1")
  cursor="$BATS_TEST_TMPDIR/cursors.json"
  (
    wait_for_cursor "$cursor"
    append_assistant_text "$file" "a-any-clear-usage" "usage values cleared"
  ) &
  appender=$!

  run env \
    usage_config=/definitely/missing.json \
    usage_cursor_file=/definitely/missing/cursors.json \
    usage_timeout=0.01 \
    usage_interval=99 \
    usage_json=true \
    bash -c 'sessions wait-any "$1" --cursor-file "$2" \
      --timeout 5 --interval 0.05' _ "$SESSION_1" "$cursor"
  wait "$appender"

  [ "$status" -eq 0 ]
  echo "$output" | grep -q "usage values cleared"
  ! echo "$output" | python3 -m json.tool >/dev/null 2>&1
}

@test "wait-any resolves config and cursor paths from caller context" {
  config="$BATS_TEST_TMPDIR/watches.json"
  cursor="$BATS_TEST_TMPDIR/cursors.json"
  write_watch_config "$config"

  run --separate-stderr env SESSIONS_CALLER_PWD="$BATS_TEST_TMPDIR" \
    bash -c 'sessions wait-any --config watches.json \
      --cursor-file cursors.json --timeout 0.15 --interval 0.05 --json'

  [ "$status" -eq 124 ]
  [ -f "$cursor" ]
}

@test "wait-any rejects non-finite timing values" {
  run sessions wait-any "$SESSION_1" --timeout nan
  [ "$status" -ne 0 ]
  echo "$output" | grep -q -- "--timeout must be finite"

  run sessions wait-any "$SESSION_1" --interval inf
  [ "$status" -ne 0 ]
  echo "$output" | grep -q -- "--interval must be finite"
}

@test "wait-any rejects boolean config versions" {
  config="$BATS_TEST_TMPDIR/watches.json"
  cat > "$config" <<JSON
{"version":true,"watches":[{"name":"alpha","session_id":"$SESSION_1"}]}
JSON

  run sessions wait-any --config "$config" --timeout 1

  [ "$status" -ne 0 ]
  echo "$output" | grep -q "config version must be 1"
}

@test "wait-any rejects simultaneous positional and config targets" {
  config="$BATS_TEST_TMPDIR/watches.json"
  write_watch_config "$config"

  run sessions wait-any "$SESSION_1" --config "$config" --timeout 1

  [ "$status" -ne 0 ]
  echo "$output" | grep -q "either session IDs or --config"
}

@test "wait-any rejects duplicate config names before waiting" {
  config="$BATS_TEST_TMPDIR/watches.json"
  cat > "$config" <<JSON
{"version":1,"watches":[
  {"name":"same","session_id":"$SESSION_1"},
  {"name":"same","session_id":"$SESSION_2"}
]}
JSON

  run sessions wait-any --config "$config" --timeout 1

  [ "$status" -ne 0 ]
  echo "$output" | grep -q "duplicate watch name"
}
