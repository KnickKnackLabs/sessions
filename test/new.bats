#!/usr/bin/env bats

load helpers

setup() { setup_test_sessions; }
teardown() { teardown_test_sessions; }

# --- basic creation ---

@test "new creates a session file (cwd defaults to .)" {
  run sessions new --cwd "$BATS_TEST_TMPDIR"
  [ "$status" -eq 0 ]
  new_id=$(echo "$output" | head -1)
  found=$(find "$PI_DIR/agent/sessions" -name "*${new_id}.jsonl" | wc -l | tr -d ' ')
  [ "$found" -eq 1 ]
}

@test "new outputs a valid UUID" {
  run sessions new --cwd "$BATS_TEST_TMPDIR"
  [ "$status" -eq 0 ]
  echo "$output" | head -1 | grep -qE '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
}

@test "new creates valid session header" {
  run sessions new --cwd "$BATS_TEST_TMPDIR"
  [ "$status" -eq 0 ]
  new_id=$(echo "$output" | head -1)
  new_file=$(find "$PI_DIR/agent/sessions" -name "*${new_id}.jsonl")
  header=$(head -1 "$new_file")
  echo "$header" | jq -e '.type == "session"'
  echo "$header" | jq -e '.version == 3'
  echo "$header" | jq -e '.id' | grep -q "$new_id"
}

@test "new with no args uses current directory as cwd" {
  run sessions new
  [ "$status" -eq 0 ]
  new_id=$(echo "$output" | head -1)
  new_file=$(find "$PI_DIR/agent/sessions" -name "*${new_id}.jsonl")
  header=$(head -1 "$new_file")
  # cwd should be the test's working directory
  echo "$header" | jq -e '.cwd' | grep -q "/"
}

@test "new --cwd stores absolute path in header" {
  run sessions new --cwd "$BATS_TEST_TMPDIR"
  [ "$status" -eq 0 ]
  new_id=$(echo "$output" | head -1)
  new_file=$(find "$PI_DIR/agent/sessions" -name "*${new_id}.jsonl")
  header=$(head -1 "$new_file")
  echo "$header" | jq -r '.cwd' | grep -q "$BATS_TEST_TMPDIR"
}

@test "new --cwd errors on nonexistent directory" {
  run sessions new --cwd "/tmp/nonexistent-$$"
  [ "$status" -eq 1 ]
  echo "$output" | grep -qi "not found"
}

# --- naming ---

@test "new with name stores it in session header" {
  run sessions new pr-review-50 --cwd "$BATS_TEST_TMPDIR"
  [ "$status" -eq 0 ]
  new_id=$(echo "$output" | head -1)
  new_file=$(find "$PI_DIR/agent/sessions" -name "*${new_id}.jsonl")
  header=$(head -1 "$new_file")
  echo "$header" | jq -e '.name == "pr-review-50"'
}

@test "new without name has no name field in header" {
  run sessions new --cwd "$BATS_TEST_TMPDIR"
  [ "$status" -eq 0 ]
  new_id=$(echo "$output" | head -1)
  new_file=$(find "$PI_DIR/agent/sessions" -name "*${new_id}.jsonl")
  header=$(head -1 "$new_file")
  echo "$header" | jq -e 'has("name") | not'
}

@test "new with name shows name in output" {
  run sessions new scout-report --cwd "$BATS_TEST_TMPDIR"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "scout-report"
}

@test "named session is findable by name" {
  run sessions new find-me-by-name --cwd "$BATS_TEST_TMPDIR"
  [ "$status" -eq 0 ]
  run sessions meta find-me-by-name
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.name == "find-me-by-name"'
}

@test "name supports slashes for namespacing" {
  run sessions new feature/reddit/auth --cwd "$BATS_TEST_TMPDIR"
  [ "$status" -eq 0 ]
  new_id=$(echo "$output" | head -1)
  new_file=$(find "$PI_DIR/agent/sessions" -name "*${new_id}.jsonl")
  header=$(head -1 "$new_file")
  echo "$header" | jq -e '.name == "feature/reddit/auth"'
}

# --- harness ---

@test "new includes harness entry as line 2" {
  run sessions new --cwd "$BATS_TEST_TMPDIR"
  [ "$status" -eq 0 ]
  new_id=$(echo "$output" | head -1)
  new_file=$(find "$PI_DIR/agent/sessions" -name "*${new_id}.jsonl")
  sed -n '2p' "$new_file" | jq -e '.type == "harness" and .name == "pi"'
}

@test "new does not write a synthetic model_change entry" {
  run sessions new --cwd "$BATS_TEST_TMPDIR"
  [ "$status" -eq 0 ]
  new_id=$(echo "$output" | head -1)
  new_file=$(find "$PI_DIR/agent/sessions" -name "*${new_id}.jsonl")
  ! jq -e 'select(.type == "model_change")' "$new_file"
}

@test "new rejects --model" {
  run sessions new --cwd "$BATS_TEST_TMPDIR" --model "openai-codex/gpt-5.5"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "unexpected"
}

# --- context ---

@test "new injects context as user message" {
  run sessions new --cwd "$BATS_TEST_TMPDIR" --context "You are reviewing PR #42"
  [ "$status" -eq 0 ]
  new_id=$(echo "$output" | head -1)
  new_file=$(find "$PI_DIR/agent/sessions" -name "*${new_id}.jsonl")
  lines=$(wc -l < "$new_file" | tr -d ' ')
  # session + harness + message = 3 lines
  [ "$lines" -eq 3 ]
  tail -1 "$new_file" | jq -e '.type == "message"'
  tail -1 "$new_file" | jq -r '.message.content[0].text' | grep -q "PR #42"
}

@test "new without context creates 2-entry session" {
  run sessions new --cwd "$BATS_TEST_TMPDIR"
  [ "$status" -eq 0 ]
  new_id=$(echo "$output" | head -1)
  new_file=$(find "$PI_DIR/agent/sessions" -name "*${new_id}.jsonl")
  lines=$(wc -l < "$new_file" | tr -d ' ')
  # session + harness = 2 lines
  [ "$lines" -eq 2 ]
}

@test "new --context-file reads from file" {
  echo "You are agent Ikma. Review the following diff." > "$BATS_TEST_TMPDIR/ctx.md"
  run sessions new --cwd "$BATS_TEST_TMPDIR" --context-file "$BATS_TEST_TMPDIR/ctx.md"
  [ "$status" -eq 0 ]
  new_id=$(echo "$output" | head -1)
  new_file=$(find "$PI_DIR/agent/sessions" -name "*${new_id}.jsonl")
  tail -1 "$new_file" | jq -r '.message.content[0].text' | grep -q "agent Ikma"
}

@test "new errors with nonexistent context file" {
  run sessions new --cwd "$BATS_TEST_TMPDIR" --context-file "/tmp/nonexistent-$$"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "not found"
}

# --- pi naming ---

@test "new creates file with pi naming convention" {
  run sessions new --cwd "$BATS_TEST_TMPDIR"
  [ "$status" -eq 0 ]
  new_id=$(echo "$output" | head -1)
  new_file=$(find "$PI_DIR/agent/sessions" -name "*${new_id}.jsonl")
  basename=$(basename "$new_file" .jsonl)
  echo "$basename" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T.*_[0-9a-f]{8}-'
}

# --- integration ---

@test "new session is readable by sessions read" {
  run sessions new --cwd "$BATS_TEST_TMPDIR" --context "hello from new"
  [ "$status" -eq 0 ]
  new_id=$(echo "$output" | head -1)
  run sessions read "$new_id"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "hello from new"
}

@test "new stub session is omitted from default sessions list" {
  run sessions new --cwd "$BATS_TEST_TMPDIR" --context "list test"
  [ "$status" -eq 0 ]
  new_id=$(echo "$output" | head -1)
  run sessions list
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -q "${new_id:0:8}"
}
