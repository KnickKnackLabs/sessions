#!/usr/bin/env bats

load helpers

setup() { setup_test_sessions; }
teardown() { teardown_test_sessions; }

@test "search finds matching content" {
  run sessions search "sccache"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "sccache"
}

@test "search finds content in user messages" {
  run sessions search "hello.*help"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "hello"
}

@test "search is case insensitive" {
  run sessions search "SCCACHE"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qi "sccache"
}

@test "search shows no results for non-matching query" {
  run sessions search "xyznonexistent123"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'No matches'
}

@test "search searches tool inputs" {
  run sessions search "config/sccache"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "config"
}

@test "search errors with no query" {
  run sessions search
  [ "$status" -eq 1 ]
}

@test "search respects --limit" {
  run sessions search "." --limit 1
  [ "$status" -eq 0 ]
  # Should only match 1 session
  count=$(echo "$output" | grep -c "^──" || true)
  [ "$count" -le 1 ]
}
