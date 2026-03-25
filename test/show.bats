#!/usr/bin/env bats

load helpers

setup() { setup_test_sessions; }
teardown() { teardown_test_sessions; }

@test "show displays session header" {
  run sessions show "$SESSION_1"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "Session:"
  echo "$output" | grep -q "claude-opus-4-6"
}

@test "show displays user messages" {
  run sessions show "$SESSION_1"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "hello, can you help me?"
  echo "$output" | grep -q "sccache configuration"
}

@test "show displays assistant messages" {
  run sessions show "$SESSION_1"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "Of course! What do you need help with?"
}

@test "show displays tool_use blocks" {
  run sessions show "$SESSION_1"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "\[tool_use: Bash"
}

@test "show --no-tools hides tool blocks" {
  run sessions show "$SESSION_1" --no-tools
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -q "\[tool_use:"
  ! echo "$output" | grep -q "\[tool_result:"
}

@test "show filters synthetic messages" {
  run sessions show "$SESSION_1"
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -q "No response requested"
}

@test "show supports prefix matching" {
  run sessions show "${SESSION_1:0:8}"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "hello, can you help me?"
}

@test "show errors on unknown session" {
  run sessions show "deadbeef-dead-beef-dead-beefdeadbeef"
  [ "$status" -eq 1 ]
  echo "$output" | grep -qi "no session"
}

@test "show errors with no session_id" {
  run sessions show
  [ "$status" -eq 1 ]
}
