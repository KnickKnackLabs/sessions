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

@test "search includes sessions regardless of filename prefix" {
  cat > "${PROJECT_DIR}agent-search-visible.jsonl" <<JSONL
{"type":"session","version":3,"id":"agent-search-visible","timestamp":"2026-03-15T15:00:00.000Z","cwd":"/test/project"}
{"type":"model_change","id":"mc1","parentId":null,"timestamp":"2026-03-15T15:00:00.001Z","provider":"test","modelId":"test-model"}
{"type":"message","id":"u1","parentId":"mc1","timestamp":"2026-03-15T15:00:01.000Z","message":{"role":"user","content":[{"type":"text","text":"needle-agent-prefix-visible"}]}}
{"type":"message","id":"a1","parentId":"u1","timestamp":"2026-03-15T15:00:02.000Z","message":{"role":"assistant","content":[{"type":"text","text":"done"}],"model":"test-model","provider":"test"}}
JSONL

  run sessions search "needle-agent-prefix-visible" --json

  [ "$status" -eq 0 ]
  echo "$output" | python3 -c "
import json, sys
matches = json.load(sys.stdin)
assert len(matches) == 1, matches
assert matches[0]['session_id'] == 'agent-search-visible', matches
"
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

@test "search excludes tool content by default" {
  # "config/sccache" only appears in a tool_use input, not in text messages
  run sessions search "config/sccache"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "No matches"
}

@test "search --tools includes tool content" {
  run sessions search "config/sccache" --tools
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "config"
}

@test "search errors with no query" {
  run sessions search
  [ "$status" -eq 1 ]
}

@test "search respects --limit" {
  run sessions search "." --limit 2
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "2 matches"
}

@test "search shows role labels" {
  run sessions search "sccache"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "user\|assistant"
}

@test "search shows session identifier" {
  run sessions search "sccache"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qE "[a-f0-9]{8}"
}

@test "search shows match count" {
  run sessions search "sccache"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qE "[0-9]+ match"
}

@test "search --session filters to one session" {
  run sessions search "." --session "${SESSION_1:0:8}"
  [ "$status" -eq 0 ]
  # Should only contain matches from session 1
  # Session 2 content ("weather") should not appear
  ! echo "$output" | grep -q "weather"
}

@test "search --json outputs valid JSON" {
  run sessions search "sccache" --json
  [ "$status" -eq 0 ]
  echo "$output" | python3 -m json.tool > /dev/null
}

@test "search --json returns flat match array" {
  run sessions search "sccache" --json
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c "
import sys, json
matches = json.load(sys.stdin)
assert isinstance(matches, list)
assert len(matches) > 0
m = matches[0]
assert 'session_id' in m
assert 'role' in m
assert 'ts' in m
assert 'snippet' in m
"
}
