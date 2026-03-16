#!/usr/bin/env bats

load helpers

setup() { setup_test_sessions; }
teardown() { teardown_test_sessions; }

@test "inspect shows session metadata" {
  export usage_session_id="$SESSION_1"
  run python3 "$TASKS_DIR/inspect"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "Session:"
  echo "$output" | grep -q "$SESSION_1"
}

@test "inspect shows model" {
  export usage_session_id="$SESSION_1"
  run python3 "$TASKS_DIR/inspect"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "claude-opus-4-6"
}

@test "inspect shows duration" {
  export usage_session_id="$SESSION_1"
  run python3 "$TASKS_DIR/inspect"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "Duration:"
  echo "$output" | grep -q "30m"
}

@test "inspect shows tool usage" {
  export usage_session_id="$SESSION_1"
  run python3 "$TASKS_DIR/inspect"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "Bash"
}

@test "inspect shows compaction status" {
  export usage_session_id="$SESSION_1"
  run python3 "$TASKS_DIR/inspect"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "Compacted:.*No"
}

@test "inspect --json outputs valid JSON" {
  export usage_session_id="$SESSION_1"
  export usage_json="true"
  run python3 "$TASKS_DIR/inspect"
  [ "$status" -eq 0 ]
  echo "$output" | python3 -m json.tool > /dev/null
}

@test "inspect --json includes tools map" {
  export usage_session_id="$SESSION_1"
  export usage_json="true"
  run python3 "$TASKS_DIR/inspect"
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c "
import json, sys
data = json.load(sys.stdin)
assert 'tools' in data
assert 'Bash' in data['tools']
"
}

@test "inspect shows file size" {
  export usage_session_id="$SESSION_1"
  run python3 "$TASKS_DIR/inspect"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "File size:"
}
