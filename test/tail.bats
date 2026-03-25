#!/usr/bin/env bats

load helpers

setup() { setup_test_sessions; }
teardown() { teardown_test_sessions; }

@test "tail shows last messages" {
  run sessions tail "$SESSION_1" --limit 3
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "let's wrap up"
  echo "$output" | grep -q "sccache config looks good"
}

@test "tail respects --limit" {
  run sessions tail "$SESSION_1" --limit 1
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "Showing last 1 of"
}

@test "tail --no-tools filters tool blocks" {
  run sessions tail "$SESSION_1" --no-tools
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -q "\[tool_use:"
}

@test "tail shows session header with project" {
  run sessions tail "$SESSION_1"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "Session:"
  echo "$output" | grep -q "project"
}

@test "tail supports prefix matching" {
  run sessions tail "${SESSION_1:0:8}"
  [ "$status" -eq 0 ]
}
