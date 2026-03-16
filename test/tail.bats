#!/usr/bin/env bats

load helpers

setup() { setup_test_sessions; }
teardown() { teardown_test_sessions; }

@test "tail shows last messages" {
  export usage_session_id="$SESSION_1"
  export usage_limit="3"
  run python3 "$TASKS_DIR/tail"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "let's wrap up"
  echo "$output" | grep -q "sccache config looks good"
}

@test "tail respects --limit" {
  export usage_session_id="$SESSION_1"
  export usage_limit="1"
  run python3 "$TASKS_DIR/tail"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "Showing last 1 of"
}

@test "tail --no-tools filters tool blocks" {
  export usage_session_id="$SESSION_1"
  export usage_no_tools="true"
  run python3 "$TASKS_DIR/tail"
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -q "\[tool_use:"
}

@test "tail shows session header with project" {
  export usage_session_id="$SESSION_1"
  run python3 "$TASKS_DIR/tail"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "Session:"
  echo "$output" | grep -q "project"
}

@test "tail supports prefix matching" {
  export usage_session_id="${SESSION_1:0:8}"
  run python3 "$TASKS_DIR/tail"
  [ "$status" -eq 0 ]
}
