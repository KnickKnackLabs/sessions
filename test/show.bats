#!/usr/bin/env bats

load helpers

setup() { setup_test_sessions; }
teardown() { teardown_test_sessions; }

@test "show displays session header" {
  export usage_session_id="$SESSION_1"
  run python3 "$TASKS_DIR/show"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "Session:"
  echo "$output" | grep -q "claude-opus-4-6"
}

@test "show displays user messages" {
  export usage_session_id="$SESSION_1"
  run python3 "$TASKS_DIR/show"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "hello, can you help me?"
  echo "$output" | grep -q "sccache configuration"
}

@test "show displays assistant messages" {
  export usage_session_id="$SESSION_1"
  run python3 "$TASKS_DIR/show"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "Of course! What do you need help with?"
}

@test "show displays tool_use blocks" {
  export usage_session_id="$SESSION_1"
  run python3 "$TASKS_DIR/show"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "\[tool_use: Bash"
}

@test "show --no-tools hides tool blocks" {
  export usage_session_id="$SESSION_1"
  export usage_no_tools="true"
  run python3 "$TASKS_DIR/show"
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -q "\[tool_use:"
  ! echo "$output" | grep -q "\[tool_result:"
}

@test "show filters synthetic messages" {
  export usage_session_id="$SESSION_1"
  run python3 "$TASKS_DIR/show"
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -q "No response requested"
}

@test "show supports prefix matching" {
  export usage_session_id="${SESSION_1:0:8}"
  run python3 "$TASKS_DIR/show"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "hello, can you help me?"
}

@test "show errors on unknown session" {
  export usage_session_id="deadbeef-dead-beef-dead-beefdeadbeef"
  run python3 "$TASKS_DIR/show"
  [ "$status" -eq 1 ]
  echo "$output" | grep -qi "no session"
}

@test "show errors with no session_id" {
  export usage_session_id=""
  run python3 "$TASKS_DIR/show"
  [ "$status" -eq 1 ]
}
