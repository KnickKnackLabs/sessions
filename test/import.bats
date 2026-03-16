#!/usr/bin/env bats

load helpers

setup() {
  setup_test_sessions
  export EXPORT_DIR="$BATS_TMPDIR/import-test-$$"
  mkdir -p "$EXPORT_DIR"

  # Export session 1 as a bundle to use for import tests
  export usage_session_id="$SESSION_1"
  export usage_output="$EXPORT_DIR"
  export usage_format="bundle"
  python3 "$TASKS_DIR/export"

  # Remove original so we can test import
  rm -f "${PROJECT_DIR}${SESSION_1}.jsonl"
}

teardown() {
  teardown_test_sessions
  rm -rf "$EXPORT_DIR"
}

@test "import bundle restores session" {
  export usage_path="$EXPORT_DIR/$SESSION_1"
  run python3 "$TASKS_DIR/import"
  [ "$status" -eq 0 ]
  [ -f "${PROJECT_DIR}${SESSION_1}.jsonl" ]
}

@test "import bundle shows resume command" {
  export usage_path="$EXPORT_DIR/$SESSION_1"
  run python3 "$TASKS_DIR/import"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "Resume with:"
}

@test "import errors when session already exists" {
  # Re-create the original
  echo '{}' > "${PROJECT_DIR}${SESSION_1}.jsonl"
  export usage_path="$EXPORT_DIR/$SESSION_1"
  run python3 "$TASKS_DIR/import"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "already exists"
}

@test "import standalone JSONL requires --project" {
  export usage_path="$EXPORT_DIR/$SESSION_1/$SESSION_1.jsonl"
  run python3 "$TASKS_DIR/import"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "\-\-project"
}

@test "import standalone JSONL with --project works" {
  export usage_path="$EXPORT_DIR/$SESSION_1/$SESSION_1.jsonl"
  export usage_project="-test-project"
  run python3 "$TASKS_DIR/import"
  [ "$status" -eq 0 ]
  [ -f "${PROJECT_DIR}${SESSION_1}.jsonl" ]
}

@test "import errors on nonexistent path" {
  export usage_path="/tmp/nonexistent-$$/foo"
  run python3 "$TASKS_DIR/import"
  [ "$status" -eq 1 ]
}
