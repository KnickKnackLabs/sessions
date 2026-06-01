#!/usr/bin/env bats

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
{"type":"message","id":"$id","parentId":"wait-test","timestamp":"2026-03-14T10:31:00.000Z","message":{"role":"assistant","content":[{"type":"text","text":"$text"}],"model":"claude-opus-4-6","provider":"anthropic","stopReason":"stop","timestamp":1710405060000}}
JSONL
}

append_user_text() {
  local file="$1"
  local id="$2"
  local text="$3"
  cat >> "$file" <<JSONL
{"type":"message","id":"$id","parentId":"wait-test","timestamp":"2026-03-14T10:31:00.000Z","message":{"role":"user","content":[{"type":"text","text":"$text"}],"timestamp":1710405060000}}
JSONL
}

append_assistant_tool_only() {
  local file="$1"
  local id="$2"
  local command="$3"
  cat >> "$file" <<JSONL
{"type":"message","id":"$id","parentId":"wait-test","timestamp":"2026-03-14T10:31:00.000Z","message":{"role":"assistant","content":[{"type":"toolCall","id":"tc-$id","name":"bash","arguments":{"command":"$command"}}],"model":"claude-opus-4-6","provider":"anthropic","stopReason":"toolUse","timestamp":1710405060000}}
JSONL
}

@test "wait returns the next appended rendered message" {
  file=$(session_path "$SESSION_1")
  (
    sleep 1
    append_assistant_text "$file" "a-wait-1" "new wait message ready"
  ) &
  appender=$!

  run sessions wait "$SESSION_1" --timeout 5 --interval 0.1
  wait "$appender"

  [ "$status" -eq 0 ]
  echo "$output" | grep -q "new wait message ready"
  ! echo "$output" | grep -q "hello.*help"
}

@test "wait times out when no matching message appears" {
  run sessions wait "$SESSION_1" --timeout 0.3 --interval 0.05

  [ "$status" -eq 124 ]
  echo "$output" | grep -q "Timed out waiting"
}

@test "wait clears inherited optional usage defaults" {
  file=$(session_path "$SESSION_1")
  (
    sleep 1
    append_assistant_text "$file" "a-wait-clear-usage" "usage defaults cleared"
  ) &
  appender=$!

  run env \
    usage_count=2 \
    usage_tools=true \
    usage_user_only=true \
    usage_assistant_only=true \
    usage_match=never \
    usage_json=true \
    bash -c 'sessions wait "$1" --timeout 5 --interval 0.1' _ "$SESSION_1"
  wait "$appender"

  [ "$status" -eq 0 ]
  echo "$output" | grep -q "Assistant"
  echo "$output" | grep -q "usage defaults cleared"
  ! echo "$output" | python3 -m json.tool >/dev/null 2>&1
}

@test "wait ignores tool-only messages by default" {
  file=$(session_path "$SESSION_1")
  (
    sleep 1
    append_assistant_tool_only "$file" "a-wait-tool-default" "echo hidden-tool"
  ) &
  appender=$!

  run sessions wait "$SESSION_1" --timeout 2 --interval 0.1
  wait "$appender"

  [ "$status" -eq 124 ]
  echo "$output" | grep -q "Timed out waiting"
}

@test "wait --tools can match tool-only messages" {
  file=$(session_path "$SESSION_1")
  (
    sleep 1
    append_assistant_tool_only "$file" "a-wait-tool-visible" "echo visible-tool"
  ) &
  appender=$!

  run sessions wait "$SESSION_1" --tools --timeout 5 --interval 0.1
  wait "$appender"

  [ "$status" -eq 0 ]
  echo "$output" | grep -q "\[tool_use:.*bash"
  echo "$output" | grep -q "visible-tool"
}

@test "wait --assistant-only ignores new user messages" {
  file=$(session_path "$SESSION_1")
  (
    sleep 1
    append_user_text "$file" "u-wait-ignored" "human/operator note"
    sleep 0.5
    append_assistant_text "$file" "a-wait-assistant" "assistant follow-up"
  ) &
  appender=$!

  run sessions wait "$SESSION_1" --assistant-only --timeout 5 --interval 0.1
  wait "$appender"

  [ "$status" -eq 0 ]
  echo "$output" | grep -q "assistant follow-up"
  ! echo "$output" | grep -q "human/operator note"
}

@test "wait --match waits for a matching new message" {
  file=$(session_path "$SESSION_1")
  (
    sleep 1
    append_assistant_text "$file" "a-wait-unmatched" "still working"
    sleep 0.5
    append_assistant_text "$file" "a-wait-matched" "Done with the requested work"
  ) &
  appender=$!

  run sessions wait "$SESSION_1" --match "done with" --timeout 5 --interval 0.1
  wait "$appender"

  [ "$status" -eq 0 ]
  echo "$output" | grep -q "Done with the requested work"
  ! echo "$output" | grep -q "still working"
}

@test "wait --count collects multiple new matching messages" {
  file=$(session_path "$SESSION_1")
  (
    sleep 1
    append_assistant_text "$file" "a-wait-count-1" "first counted wait message"
    sleep 0.5
    append_assistant_text "$file" "a-wait-count-2" "second counted wait message"
  ) &
  appender=$!

  run sessions wait "$SESSION_1" --count 2 --timeout 5 --interval 0.1
  wait "$appender"

  [ "$status" -eq 0 ]
  echo "$output" | grep -q "first counted wait message"
  echo "$output" | grep -q "second counted wait message"
}

@test "wait --json returns matching messages as JSON" {
  file=$(session_path "$SESSION_1")
  (
    sleep 1
    append_assistant_text "$file" "a-wait-json" "json wait message"
  ) &
  appender=$!

  run sessions wait "$SESSION_1" --json --timeout 5 --interval 0.1
  wait "$appender"

  [ "$status" -eq 0 ]
  echo "$output" | python3 -c "
import json, sys
data = json.load(sys.stdin)
assert data['session_id'] == '$SESSION_1'
assert len(data['messages']) == 1
assert data['messages'][0]['text'] == 'json wait message'
"
}
