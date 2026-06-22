#!/usr/bin/env bats

load helpers

setup() {
  setup_test_sessions
  export EXPORT_DIR="$BATS_TEST_TMPDIR/import-test"
  mkdir -p "$EXPORT_DIR"

  # Export session 1 as a bundle to use for import tests
  sessions export "$SESSION_1" --output "$EXPORT_DIR" --format bundle

  # Remove original so we can test import (pi filename has timestamp prefix)
  rm -f "${PROJECT_DIR}"*"${SESSION_1}.jsonl"
}

teardown() {
  teardown_test_sessions
  rm -rf "$EXPORT_DIR"
}

@test "import bundle restores session" {
  run sessions import "$EXPORT_DIR/$SESSION_1"
  [ "$status" -eq 0 ]
  # Import writes as {session_id}.jsonl (no timestamp prefix)
  [ -f "${PROJECT_DIR}${SESSION_1}.jsonl" ]
}

@test "import bundle shows resume command" {
  run sessions import "$EXPORT_DIR/$SESSION_1"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "Resume with:"
}

@test "import bundle restores associated session files" {
  mkdir -p "$EXPORT_DIR/$SESSION_1/associated-sessions"
  echo '{}' > "$EXPORT_DIR/$SESSION_1/associated-sessions/related.jsonl"

  run sessions import "$EXPORT_DIR/$SESSION_1"

  [ "$status" -eq 0 ]
  [ -f "${PROJECT_DIR}${SESSION_1}/related.jsonl" ]
}

@test "import bundle accepts legacy associated-session directory" {
  legacy_dir="$EXPORT_DIR/$SESSION_1/sub""agents"
  mkdir -p "$legacy_dir"
  echo '{}' > "$legacy_dir/related.jsonl"

  run sessions import "$EXPORT_DIR/$SESSION_1"

  [ "$status" -eq 0 ]
  [ -f "${PROJECT_DIR}${SESSION_1}/related.jsonl" ]
}

@test "import errors when session already exists" {
  # Re-create the original (import writes without timestamp prefix)
  echo '{}' > "${PROJECT_DIR}${SESSION_1}.jsonl"
  run sessions import "$EXPORT_DIR/$SESSION_1"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "already exists"
}

@test "import standalone JSONL requires --project" {
  run sessions import "$EXPORT_DIR/$SESSION_1/$SESSION_1.jsonl"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "\-\-project"
}

@test "import standalone JSONL with --project works" {
  run sessions import "$EXPORT_DIR/$SESSION_1/$SESSION_1.jsonl" --project "--test-project--"
  [ "$status" -eq 0 ]
  [ -f "${PROJECT_DIR}${SESSION_1}.jsonl" ]
}

@test "import errors on nonexistent path" {
  run sessions import "/tmp/nonexistent-$$/foo"
  [ "$status" -eq 1 ]
}
