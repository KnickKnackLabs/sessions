#!/usr/bin/env bats

load helpers

setup() {
  setup_test_sessions
  # Isolate zmx sessions per-test to prevent bats FD hangs.
  # zmx's forked daemon inherits bats' FDs; without isolation,
  # teardown can't fully clean up and bats blocks forever.
  export ZMX_DIR="/tmp/swk-$$"
  mkdir -p "$ZMX_DIR"
}
teardown() {
  # Clean up shell sessions in our isolated dir
  for name in $(zmx list --short 2>/dev/null || true); do
    shell kill "$name" 2>/dev/null || true
  done
  # Kill any lingering zmx processes
  for pid in $(zmx list 2>/dev/null | tr '\t' '\n' | grep "^pid=" | cut -d= -f2); do
    local children
    children=$(pgrep -P "$pid" 2>/dev/null || true)
    for cpid in $children; do kill "$cpid" 2>/dev/null || true; done
    kill "$pid" 2>/dev/null || true
  done
  rm -rf "${ZMX_DIR:-}"
  teardown_test_sessions
}

@test "wake errors on nonexistent session" {
  run sessions wake "deadbeef"
  [ "$status" -eq 1 ]
  echo "$output" | grep -qi "no session"
}

@test "wake errors when context file missing" {
  run sessions wake "$SESSION_1" --context-file "/tmp/nonexistent-$$"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "not found"
}

@test "wake launches session via shell" {
  command -v shell >/dev/null 2>&1 || skip "shell not installed"
  # Session 1 has no name — shell name derived from UUID prefix
  run sessions wake "${SESSION_1:0:8}"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "$SESSION_1"
  # Shell session should be named after the UUID prefix
  shell list 2>/dev/null | grep -q "${SESSION_1:0:8}"
}

@test "wake derives shell name from session name" {
  command -v shell >/dev/null 2>&1 || skip "shell not installed"
  # Create a named session
  run sessions new "wake-name-test-$$"
  [ "$status" -eq 0 ]
  local new_id
  new_id=$(echo "$output" | head -1)

  run sessions wake "wake-name-test-$$"
  [ "$status" -eq 0 ]
  # Shell session should be named after the session name
  shell list 2>/dev/null | grep -q "wake-name-test-$$"
}

@test "wake translates slashes in session name for shell" {
  command -v shell >/dev/null 2>&1 || skip "shell not installed"
  run sessions new "feature/test-$$"
  [ "$status" -eq 0 ]

  run sessions wake "feature/test-$$"
  [ "$status" -eq 0 ]
  # Slashes become dashes in shell name
  shell list 2>/dev/null | grep -q "feature-test-$$"
}

@test "wake injects context before launching" {
  command -v shell >/dev/null 2>&1 || skip "shell not installed"
  run sessions wake "$SESSION_1" --context "Review PR #42"
  [ "$status" -eq 0 ]
  src_file=$(find "$PROJECT_DIR" -name "*${SESSION_1}.jsonl")
  grep -q "PR #42" "$src_file"
}

@test "wake shows monitor instructions" {
  command -v shell >/dev/null 2>&1 || skip "shell not installed"
  run sessions wake "$SESSION_1"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "Monitor:"
}
