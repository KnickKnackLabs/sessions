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
  AGENT_HARNESS_HEADLESS="echo" run sessions wake "deadbeef"
  [ "$status" -eq 1 ]
  echo "$output" | grep -qi "no session"
}

@test "wake errors when context file missing" {
  AGENT_HARNESS_HEADLESS="echo" run sessions wake "$SESSION_1" --context-file "/tmp/nonexistent-$$"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "not found"
}

@test "wake launches session via shell" {
  command -v shell >/dev/null 2>&1 || skip "shell not installed"
  # Use a unique name to avoid collisions
  AGENT_HARNESS_HEADLESS="echo" run sessions wake "${SESSION_1:0:8}" --name "wake-test-$$"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "$SESSION_1"
  echo "$output" | grep -q "shell"
  shell list 2>/dev/null | grep -q "wake-test-$$"
}

@test "wake injects context before launching" {
  command -v shell >/dev/null 2>&1 || skip "shell not installed"
  AGENT_HARNESS_HEADLESS="echo" run sessions wake "$SESSION_1" --context "Review PR #42" --name "wake-ctx-$$"
  [ "$status" -eq 0 ]
  src_file=$(find "$PROJECT_DIR" -name "*${SESSION_1}.jsonl")
  # Context should be the second-to-last entry (last is whatever zmx injected timing-wise)
  grep -q "PR #42" "$src_file"
}

@test "wake shows attach and monitor instructions" {
  command -v shell >/dev/null 2>&1 || skip "shell not installed"
  AGENT_HARNESS_HEADLESS="echo" run sessions wake "$SESSION_1" --name "wake-instr-$$"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "Monitor:"
  echo "$output" | grep -q "Status:"
}
