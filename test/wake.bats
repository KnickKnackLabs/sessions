#!/usr/bin/env bats

load helpers

setup() { setup_test_sessions; }
teardown() {
  # Clean up any zmx sessions from this test run
  for name in $(zmx list --short 2>/dev/null); do
    zmx kill "$name" 2>/dev/null || true
  done
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

@test "wake launches session via zmx" {
  command -v zmx >/dev/null 2>&1 || skip "zmx not installed"
  # Use a unique name to avoid collisions
  AGENT_HARNESS="echo" run sessions wake "${SESSION_1:0:8}" --name "wake-test-$$"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "$SESSION_1"
  echo "$output" | grep -q "zmx pane"
  zmx list 2>/dev/null | grep -q "wake-test-$$"
}

@test "wake injects context before launching" {
  command -v zmx >/dev/null 2>&1 || skip "zmx not installed"
  AGENT_HARNESS="echo" run sessions wake "$SESSION_1" --context "Review PR #42" --name "wake-ctx-$$"
  [ "$status" -eq 0 ]
  src_file=$(find "$PROJECT_DIR" -name "*${SESSION_1}.jsonl")
  # Context should be the second-to-last entry (last is whatever zmx injected timing-wise)
  grep -q "PR #42" "$src_file"
}

@test "wake shows attach and monitor instructions" {
  command -v zmx >/dev/null 2>&1 || skip "zmx not installed"
  AGENT_HARNESS="echo" run sessions wake "$SESSION_1" --name "wake-instr-$$"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "Attach:"
  echo "$output" | grep -q "Monitor:"
}
