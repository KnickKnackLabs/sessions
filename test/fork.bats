#!/usr/bin/env bats

load helpers

setup() {
  setup_test_sessions
}

teardown() {
  teardown_test_sessions
}

@test "fork creates a new session file" {
  run sessions fork "$SESSION_1"
  [ "$status" -eq 0 ]
  # First line of output is the new session ID
  new_id=$(echo "$output" | head -1)
  # Should exist as a file in the project dir
  found=$(find "$PROJECT_DIR" -name "*${new_id}.jsonl" | wc -l | tr -d ' ')
  [ "$found" -eq 1 ]
}

@test "fork output includes new session ID" {
  run sessions fork "$SESSION_1"
  [ "$status" -eq 0 ]
  # First line is a UUID
  echo "$output" | head -1 | grep -qE '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
}

@test "fork shows source and fork filenames" {
  run sessions fork "$SESSION_1"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "Forked"
  echo "$output" | grep -q "Source:"
  echo "$output" | grep -q "Fork:"
}

@test "fork preserves original session content" {
  run sessions fork "$SESSION_1"
  [ "$status" -eq 0 ]
  new_id=$(echo "$output" | head -1)
  new_file=$(find "$PROJECT_DIR" -name "*${new_id}.jsonl")
  # Should contain the original user message
  grep -q "hello, can you help me" "$new_file"
}

@test "fork injects fork notification as last entry" {
  run sessions fork "$SESSION_1"
  [ "$status" -eq 0 ]
  new_id=$(echo "$output" | head -1)
  new_file=$(find "$PROJECT_DIR" -name "*${new_id}.jsonl")
  # Last entry should be the fork notification
  last_entry=$(tail -1 "$new_file")
  echo "$last_entry" | jq -e '.message.isForkNotification == true'
  echo "$last_entry" | jq -e '.message.sourceSessionId' | grep -q "$SESSION_1"
}

@test "fork updates session header with new ID" {
  run sessions fork "$SESSION_1"
  [ "$status" -eq 0 ]
  new_id=$(echo "$output" | head -1)
  new_file=$(find "$PROJECT_DIR" -name "*${new_id}.jsonl")
  # First entry should have the new session ID
  header_id=$(head -1 "$new_file" | jq -r '.id')
  [ "$header_id" = "$new_id" ]
}

@test "fork notification includes context when provided" {
  run sessions fork "$SESSION_1" --context "testing the pooper integration"
  [ "$status" -eq 0 ]
  new_id=$(echo "$output" | head -1)
  new_file=$(find "$PROJECT_DIR" -name "*${new_id}.jsonl")
  tail -1 "$new_file" | jq -r '.message.content[0].text' | grep -q "testing the pooper integration"
}

@test "fork notification includes name when provided" {
  run sessions fork "$SESSION_1" --name "pooper-okwai"
  [ "$status" -eq 0 ]
  new_id=$(echo "$output" | head -1)
  new_file=$(find "$PROJECT_DIR" -name "*${new_id}.jsonl")
  tail -1 "$new_file" | jq -r '.message.content[0].text' | grep -q "pooper-okwai"
}

@test "fork does not modify original session" {
  # Count lines in original before fork
  src_file=$(find "$PROJECT_DIR" -name "*${SESSION_1}.jsonl")
  before=$(wc -l < "$src_file")
  run sessions fork "$SESSION_1"
  [ "$status" -eq 0 ]
  after=$(wc -l < "$src_file")
  [ "$before" -eq "$after" ]
}

@test "fork notification has valid parentId chain" {
  run sessions fork "$SESSION_1"
  [ "$status" -eq 0 ]
  new_id=$(echo "$output" | head -1)
  new_file=$(find "$PROJECT_DIR" -name "*${new_id}.jsonl")
  # The fork notification's parentId should match the previous entry's id
  second_to_last_id=$(tail -2 "$new_file" | head -1 | jq -r '.id')
  fork_parent_id=$(tail -1 "$new_file" | jq -r '.parentId')
  [ "$second_to_last_id" = "$fork_parent_id" ]
}

@test "fork supports prefix match on session ID" {
  run sessions fork "${SESSION_1:0:8}"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "Forked"
}

@test "fork errors on nonexistent session" {
  run sessions fork "deadbeef-dead-beef-dead-beefdeadbeef"
  [ "$status" -eq 1 ]
  echo "$output" | grep -qi "no session"
}

@test "fork errors with no session ID" {
  run sessions fork
  [ "$status" -eq 1 ]
}

@test "fork creates file with pi naming convention" {
  run sessions fork "$SESSION_1"
  [ "$status" -eq 0 ]
  new_id=$(echo "$output" | head -1)
  new_file=$(find "$PROJECT_DIR" -name "*${new_id}.jsonl")
  # Filename should be: <timestamp>_<uuid>.jsonl
  basename=$(basename "$new_file" .jsonl)
  # Should contain both a timestamp part and the UUID
  echo "$basename" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T.*_[0-9a-f]{8}-'
}
