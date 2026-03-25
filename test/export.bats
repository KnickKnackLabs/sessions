#!/usr/bin/env bats

load helpers

setup() {
  setup_test_sessions
  export EXPORT_DIR="$BATS_TMPDIR/export-test-$$"
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
  # Verify same content
  diff "${PROJECT_DIR}${SESSION_1}.jsonl" "$EXPORT_DIR/$SESSION_1.jsonl"
}

@test "export errors on unknown format" {
  run sessions export "$SESSION_1" --output "$EXPORT_DIR" --format xml
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "Unknown format"
}
