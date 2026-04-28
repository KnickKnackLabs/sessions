#!/usr/bin/env bats

load helpers

setup() { setup_test_sessions; }
teardown() { teardown_test_sessions; }

# --- basic removal ---

@test "remove deletes a session file by ID prefix" {
  # SESSION_1 exists
  found=$(find "$PI_DIR/agent/sessions" -name "*${SESSION_1}.jsonl" | wc -l | tr -d ' ')
  [ "$found" -eq 1 ]

  run sessions remove --force "${SESSION_1:0:8}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Removed session"* ]]

  # Gone
  found=$(find "$PI_DIR/agent/sessions" -name "*${SESSION_1}.jsonl" | wc -l | tr -d ' ')
  [ "$found" -eq 0 ]
}

@test "remove deletes a session by name" {
  # Create a named session
  run sessions new --cwd "$BATS_TEST_TMPDIR" test-named
  [ "$status" -eq 0 ]
  new_id=$(echo "$output" | head -1)

  # Verify it exists
  found=$(find "$PI_DIR/agent/sessions" -name "*${new_id}.jsonl" | wc -l | tr -d ' ')
  [ "$found" -eq 1 ]

  run sessions remove --force test-named
  [ "$status" -eq 0 ]
  [[ "$output" == *"Removed session 'test-named'"* ]]

  # Gone
  found=$(find "$PI_DIR/agent/sessions" -name "*${new_id}.jsonl" | wc -l | tr -d ' ')
  [ "$found" -eq 0 ]
}

@test "remove fails for nonexistent session" {
  run sessions remove --force "nonexistent-id"
  [ "$status" -ne 0 ]
  [[ "$output" == *"No session matching"* ]]
}

@test "remove with full UUID works" {
  run sessions remove --force "$SESSION_1"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Removed session"* ]]

  found=$(find "$PI_DIR/agent/sessions" -name "*${SESSION_1}.jsonl" | wc -l | tr -d ' ')
  [ "$found" -eq 0 ]
}

@test "remove errors with no session ID" {
  run sessions remove --force
  [ "$status" -ne 0 ]
}

@test "remove shows display name for named sessions" {
  run sessions new --cwd "$BATS_TEST_TMPDIR" my-cool-session
  [ "$status" -eq 0 ]

  run sessions remove --force my-cool-session
  [ "$status" -eq 0 ]
  [[ "$output" == *"my-cool-session"* ]]
}

@test "remove shows truncated ID for unnamed sessions" {
  run sessions remove --force "${SESSION_1:0:8}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"${SESSION_1:0:8}"* ]]
}
