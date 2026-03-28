#!/usr/bin/env bats

load helpers

setup() { setup_test_sessions; }
teardown() { teardown_test_sessions; }

# --- sessions meta (read) ---

@test "meta shows full session header" {
  run sessions meta "$SESSION_1"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.type == "session"'
  echo "$output" | jq -e '.id == "'"$SESSION_1"'"'
  echo "$output" | jq -e '.cwd == "/test/project"'
}

@test "meta supports prefix match" {
  run sessions meta "${SESSION_1:0:8}"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.id == "'"$SESSION_1"'"'
}

@test "meta --field extracts a specific field" {
  run sessions meta "$SESSION_1" --field .cwd
  [ "$status" -eq 0 ]
  [ "$output" = "/test/project" ]
}

@test "meta --field extracts nested fields" {
  # Create a session with meta
  run sessions new "$BATS_TMPDIR/test-project" --meta "agent.name=ikma"
  [ "$status" -eq 0 ]
  ID=$(echo "$output" | head -1)

  run sessions meta "$ID" --field .meta.agent.name
  [ "$status" -eq 0 ]
  [ "$output" = "ikma" ]
}

@test "meta --field errors on missing field" {
  run sessions meta "$SESSION_1" --field .nonexistent
  [ "$status" -eq 1 ]
  echo "$output" | grep -qi "not found"
}

@test "meta errors on nonexistent session" {
  run sessions meta "deadbeef"
  [ "$status" -eq 1 ]
  echo "$output" | grep -qi "no session"
}

# --- sessions new --meta (dotted paths) ---

@test "new --meta sets a flat key" {
  run sessions new "$BATS_TMPDIR/test-project" --meta "purpose=scout"
  [ "$status" -eq 0 ]
  ID=$(echo "$output" | head -1)

  run sessions meta "$ID" --field .meta.purpose
  [ "$status" -eq 0 ]
  [ "$output" = "scout" ]
}

@test "new --meta sets a dotted nested key" {
  run sessions new "$BATS_TMPDIR/test-project" --meta "agent.name=ikma"
  [ "$status" -eq 0 ]
  ID=$(echo "$output" | head -1)

  run sessions meta "$ID"
  echo "$output" | jq -e '.meta.agent.name == "ikma"'
}

@test "new --meta supports multiple dotted keys" {
  run sessions new "$BATS_TMPDIR/test-project" \
    --meta "agent.name=ikma" \
    --meta "agent.email=ikma@ricon.family" \
    --meta "purpose=test"
  [ "$status" -eq 0 ]
  ID=$(echo "$output" | head -1)

  run sessions meta "$ID"
  echo "$output" | jq -e '.meta.agent.name == "ikma"'
  echo "$output" | jq -e '.meta.agent.email == "ikma@ricon.family"'
  echo "$output" | jq -e '.meta.purpose == "test"'
}

@test "new --meta supports deeply nested keys" {
  run sessions new "$BATS_TMPDIR/test-project" --meta "a.b.c.d=deep"
  [ "$status" -eq 0 ]
  ID=$(echo "$output" | head -1)

  run sessions meta "$ID" --field .meta.a.b.c.d
  [ "$status" -eq 0 ]
  [ "$output" = "deep" ]
}

@test "new --meta values can contain spaces" {
  run sessions new "$BATS_TMPDIR/test-project" --meta "label=hello world"
  [ "$status" -eq 0 ]
  ID=$(echo "$output" | head -1)

  run sessions meta "$ID" --field .meta.label
  [ "$status" -eq 0 ]
  [ "$output" = "hello world" ]
}

@test "new --meta errors on missing equals sign" {
  run sessions new "$BATS_TMPDIR/test-project" --meta "noequalssign"
  [ "$status" -eq 1 ]
  echo "$output" | grep -qi "invalid"
}

# --- sessions new --meta (jq expressions) ---

@test "new --meta accepts a jq expression" {
  run sessions new "$BATS_TMPDIR/test-project" --meta '{purpose: "review"}'
  [ "$status" -eq 0 ]
  ID=$(echo "$output" | head -1)

  run sessions meta "$ID" --field .meta.purpose
  [ "$status" -eq 0 ]
  [ "$output" = "review" ]
}

@test "new --meta jq expression with nested object" {
  run sessions new "$BATS_TMPDIR/test-project" \
    --meta '{agent: {name: "ikma", email: "ikma@ricon.family"}}'
  [ "$status" -eq 0 ]
  ID=$(echo "$output" | head -1)

  run sessions meta "$ID"
  echo "$output" | jq -e '.meta.agent.name == "ikma"'
  echo "$output" | jq -e '.meta.agent.email == "ikma@ricon.family"'
}

@test "new --meta jq expression reads env vars" {
  export TEST_AGENT_NAME="from-env"
  run sessions new "$BATS_TMPDIR/test-project" \
    --meta '{agent: {name: $ENV.TEST_AGENT_NAME}}'
  [ "$status" -eq 0 ]
  ID=$(echo "$output" | head -1)

  run sessions meta "$ID" --field .meta.agent.name
  [ "$status" -eq 0 ]
  [ "$output" = "from-env" ]
}

@test "new --meta jq expression errors on invalid syntax" {
  run sessions new "$BATS_TMPDIR/test-project" --meta '{bad json???}'
  [ "$status" -eq 1 ]
  echo "$output" | grep -qi "invalid jq"
}

# --- mixing formats ---

@test "new --meta merges dotted paths and jq expressions" {
  run sessions new "$BATS_TMPDIR/test-project" \
    --meta '{agent: {name: "ikma"}}' \
    --meta "purpose=scout"
  [ "$status" -eq 0 ]
  ID=$(echo "$output" | head -1)

  run sessions meta "$ID"
  echo "$output" | jq -e '.meta.agent.name == "ikma"'
  echo "$output" | jq -e '.meta.purpose == "scout"'
}

# --- no meta ---

@test "new without --meta produces no meta field" {
  run sessions new "$BATS_TMPDIR/test-project"
  [ "$status" -eq 0 ]
  ID=$(echo "$output" | head -1)

  run sessions meta "$ID"
  echo "$output" | jq -e 'has("meta") | not'
}
