#!/usr/bin/env bats

load helpers

setup() { setup_test_sessions; }
teardown() { teardown_test_sessions; }

@test "search finds matching content" {
  export usage_query="sccache"
  run python3 "$TASKS_DIR/search"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "sccache"
}

@test "search finds content in user messages" {
  export usage_query="hello.*help"
  run python3 "$TASKS_DIR/search"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "hello"
}

@test "search is case insensitive" {
  export usage_query="SCCACHE"
  run python3 "$TASKS_DIR/search"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qi "sccache"
}

@test "search shows no results for non-matching query" {
  export usage_query="xyznonexistent123"
  run python3 "$TASKS_DIR/search"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'No matches'
}

@test "search searches tool inputs" {
  export usage_query="config/sccache"
  run python3 "$TASKS_DIR/search"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "config"
}

@test "search errors with no query" {
  export usage_query=""
  run python3 "$TASKS_DIR/search"
  [ "$status" -eq 1 ]
}

@test "search respects --limit" {
  export usage_query="."
  export usage_limit="1"
  run python3 "$TASKS_DIR/search"
  [ "$status" -eq 0 ]
  # Should only match 1 session
  count=$(echo "$output" | grep -c "^──" || true)
  [ "$count" -le 1 ]
}
