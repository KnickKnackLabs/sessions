#!/usr/bin/env bats

load helpers

setup() {
  setup_test_sessions
  export EXPORT_DIR="$BATS_TEST_TMPDIR/export-test"
  mkdir -p "$EXPORT_DIR"
}

teardown() {
  teardown_test_sessions
  rm -rf "$EXPORT_DIR"
}

@test "export bundle creates directory with JSONL and metadata" {
  run sessions export "$SESSION_1" --output "$EXPORT_DIR" --format bundle
  [ "$status" -eq 0 ]
  [ -d "$EXPORT_DIR/$SESSION_1" ]
  [ -f "$EXPORT_DIR/$SESSION_1/$SESSION_1.jsonl" ]
  [ -f "$EXPORT_DIR/$SESSION_1/metadata.json" ]
}

@test "export bundle metadata is valid JSON with required fields" {
  sessions export "$SESSION_1" --output "$EXPORT_DIR" --format bundle
  python3 -c "
import json
with open('$EXPORT_DIR/$SESSION_1/metadata.json') as f:
    m = json.load(f)
assert m['session_id'] == '$SESSION_1'
assert m['export_version'] == 'sessions-export-1.0'
assert 'exported_at' in m
assert 'source_machine' in m
"
}

@test "export bundle includes associated session files" {
  source_file=$(find "$PROJECT_DIR" -name "*${SESSION_1}.jsonl")
  associated_dir="${source_file%.jsonl}"
  mkdir -p "$associated_dir"
  echo '{}' > "$associated_dir/related.jsonl"

  run sessions export "$SESSION_1" --output "$EXPORT_DIR" --format bundle

  [ "$status" -eq 0 ]
  [ -f "$EXPORT_DIR/$SESSION_1/associated-sessions/related.jsonl" ]
  echo "$output" | grep -q "associated-sessions/ (1 sessions)"
}

@test "export bundle output does not invent special agent session categories" {
  source_file=$(find "$PROJECT_DIR" -name "*${SESSION_1}.jsonl")
  associated_dir="${source_file%.jsonl}"
  mkdir -p "$associated_dir"
  echo '{}' > "$associated_dir/related.jsonl"

  run sessions export "$SESSION_1" --output "$EXPORT_DIR" --format bundle

  [ "$status" -eq 0 ]
  ! echo "$output" | grep -qi "sub""agent"
}

@test "export markdown creates .md file" {
  run sessions export "$SESSION_1" --output "$EXPORT_DIR" --format markdown
  [ "$status" -eq 0 ]
  [ -f "$EXPORT_DIR/$SESSION_1.md" ]
  grep -q "hello, can you help me?" "$EXPORT_DIR/$SESSION_1.md"
  grep -q "sccache config looks good" "$EXPORT_DIR/$SESSION_1.md"
}

@test "export jsonl creates a copy" {
  run sessions export "$SESSION_1" --output "$EXPORT_DIR" --format jsonl
  [ "$status" -eq 0 ]
  [ -f "$EXPORT_DIR/$SESSION_1.jsonl" ]
  # Verify same content — find the source file (pi filename has timestamp prefix)
  src=$(find "$PROJECT_DIR" -name "*${SESSION_1}.jsonl")
  diff "$src" "$EXPORT_DIR/$SESSION_1.jsonl"
}

@test "export errors on unknown format" {
  run sessions export "$SESSION_1" --output "$EXPORT_DIR" --format xml
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "Unknown format"
}
