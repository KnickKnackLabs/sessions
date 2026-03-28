#!/usr/bin/env bats

load helpers

setup() { setup_test_sessions; }
teardown() { teardown_test_sessions; }

@test "new creates a session file" {
  run sessions new "$BATS_TMPDIR"
  [ "$status" -eq 0 ]
  new_id=$(echo "$output" | head -1)
  # Should exist somewhere under sessions dir
  found=$(find "$PI_DIR/agent/sessions" -name "*${new_id}.jsonl" | wc -l | tr -d ' ')
  [ "$found" -eq 1 ]
}

@test "new outputs a valid UUID" {
  run sessions new "$BATS_TMPDIR"
  [ "$status" -eq 0 ]
  echo "$output" | head -1 | grep -qE '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
}

@test "new creates valid session header" {
  run sessions new "$BATS_TMPDIR"
  [ "$status" -eq 0 ]
  new_id=$(echo "$output" | head -1)
  new_file=$(find "$PI_DIR/agent/sessions" -name "*${new_id}.jsonl")
  header=$(head -1 "$new_file")
  echo "$header" | jq -e '.type == "session"'
  echo "$header" | jq -e '.version == 3'
  echo "$header" | jq -e '.id' | grep -q "$new_id"
}

@test "new includes model_change entry" {
  run sessions new "$BATS_TMPDIR"
  [ "$status" -eq 0 ]
  new_id=$(echo "$output" | head -1)
  new_file=$(find "$PI_DIR/agent/sessions" -name "*${new_id}.jsonl")
  sed -n '2p' "$new_file" | jq -e '.type == "model_change"'
}

@test "new respects --model flag" {
  run sessions new "$BATS_TMPDIR" --model "claude-opus-4-6"
  [ "$status" -eq 0 ]
  new_id=$(echo "$output" | head -1)
  new_file=$(find "$PI_DIR/agent/sessions" -name "*${new_id}.jsonl")
  sed -n '2p' "$new_file" | jq -e '.modelId == "claude-opus-4-6"'
}

@test "new injects context as user message" {
  run sessions new "$BATS_TMPDIR" --context "You are reviewing PR #42"
  [ "$status" -eq 0 ]
  new_id=$(echo "$output" | head -1)
  new_file=$(find "$PI_DIR/agent/sessions" -name "*${new_id}.jsonl")
  # Should have 3 entries: session header, model_change, user message
  lines=$(wc -l < "$new_file" | tr -d ' ')
  [ "$lines" -eq 3 ]
  tail -1 "$new_file" | jq -e '.type == "message"'
  tail -1 "$new_file" | jq -r '.message.content[0].text' | grep -q "PR #42"
}

@test "new without context creates 2-entry session" {
  run sessions new "$BATS_TMPDIR"
  [ "$status" -eq 0 ]
  new_id=$(echo "$output" | head -1)
  new_file=$(find "$PI_DIR/agent/sessions" -name "*${new_id}.jsonl")
  lines=$(wc -l < "$new_file" | tr -d ' ')
  [ "$lines" -eq 2 ]
}

@test "new --context-file reads from file" {
  echo "You are agent Ikma. Review the following diff." > "$BATS_TMPDIR/ctx.md"
  run sessions new "$BATS_TMPDIR" --context-file "$BATS_TMPDIR/ctx.md"
  [ "$status" -eq 0 ]
  new_id=$(echo "$output" | head -1)
  new_file=$(find "$PI_DIR/agent/sessions" -name "*${new_id}.jsonl")
  tail -1 "$new_file" | jq -r '.message.content[0].text' | grep -q "agent Ikma"
}

@test "new errors with no project" {
  run sessions new
  [ "$status" -eq 1 ]
}

@test "new errors with nonexistent context file" {
  run sessions new "$BATS_TMPDIR" --context-file "/tmp/nonexistent-$$"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "not found"
}

@test "new creates file with pi naming convention" {
  run sessions new "$BATS_TMPDIR"
  [ "$status" -eq 0 ]
  new_id=$(echo "$output" | head -1)
  new_file=$(find "$PI_DIR/agent/sessions" -name "*${new_id}.jsonl")
  basename=$(basename "$new_file" .jsonl)
  echo "$basename" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T.*_[0-9a-f]{8}-'
}

@test "new session is readable by sessions read" {
  run sessions new "$BATS_TMPDIR" --context "hello from new"
  [ "$status" -eq 0 ]
  new_id=$(echo "$output" | head -1)
  run sessions read "$new_id"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "hello from new"
}

@test "new session appears in sessions list" {
  run sessions new "$BATS_TMPDIR" --context "list test"
  [ "$status" -eq 0 ]
  new_id=$(echo "$output" | head -1)
  run sessions list
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "${new_id:0:8}"
}
