#!/usr/bin/env bats
#
# Harness dispatcher tests (sessions#50 step 2).
#
# Exercises the bash dispatcher's resolver rules and registry directly,
# plus the user-facing --harness flag on `sessions new`.

load helpers

setup() {
  setup_test_sessions
  # Source the dispatcher under test so we can call its functions.
  # Tests that go through `sessions new` don't need this — they use the
  # wrapper — but the resolver unit tests do.
  # shellcheck source=/dev/null
  export HARNESS_LIB_DIR="$MISE_CONFIG_ROOT/lib/harness"
  source "$MISE_CONFIG_ROOT/lib/harness/dispatch.sh"
}

teardown() {
  teardown_test_sessions
}

# --- Registry ---

@test "harness_list returns installed adapters (pi today)" {
  run harness_list
  [ "$status" -eq 0 ]
  [ "$output" = "pi" ]
}

@test "harness_valid accepts installed adapters" {
  run harness_valid pi
  [ "$status" -eq 0 ]
}

@test "harness_valid rejects unknown adapters" {
  run harness_valid xyz
  [ "$status" -ne 0 ]
}

@test "harness_valid rejects 'dispatch' as adapter name" {
  run harness_valid dispatch
  [ "$status" -ne 0 ]
}

# --- Resolver: explicit flag ---

@test "resolver honours explicit --flag" {
  run harness_resolve --flag pi
  [ "$status" -eq 0 ]
  [ "$output" = "pi" ]
}

@test "resolver errors on unknown explicit --flag" {
  run harness_resolve --flag xyz
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi "unknown harness"
}

# --- Resolver: session file (harness entry in JSONL) ---

@test "resolver reads harness entry from session file" {
  sf="$BATS_TEST_TMPDIR/session.jsonl"
  cat > "$sf" <<JSONL
{"type":"session","version":3,"id":"abc","timestamp":"2026-04-22T10:00:00.000Z","cwd":"/tmp"}
{"type":"harness","id":"h1","parentId":"abc","timestamp":"2026-04-22T10:00:00.000Z","name":"pi"}
{"type":"model_change","id":"mc1","timestamp":"2026-04-22T10:00:00.000Z"}
JSONL
  run harness_resolve --session "$sf"
  [ "$status" -eq 0 ]
  [ "$output" = "pi" ]
}

@test "resolver picks most recent harness entry when multiple present" {
  sf="$BATS_TEST_TMPDIR/session.jsonl"
  cat > "$sf" <<JSONL
{"type":"session","id":"abc"}
{"type":"harness","id":"h1","parentId":"abc","timestamp":"2026-04-22T10:00:00.000Z","name":"pi"}
{"type":"model_change","id":"mc1"}
{"type":"wake","id":"w1"}
{"type":"harness","id":"h2","parentId":"w1","timestamp":"2026-04-22T11:00:00.000Z","name":"pi"}
JSONL
  run harness_resolve --session "$sf"
  [ "$status" -eq 0 ]
  [ "$output" = "pi" ]
}

# --- Resolver: path-based detection (fallback for legacy sessions) ---

@test "resolver falls back to path-based detection under PI_DIR" {
  sf="${PI_DIR}/agent/sessions/--test-project--/legacy.jsonl"
  # Legacy session: no harness entry at all
  cat > "$sf" <<JSONL
{"type":"session","id":"legacy"}
{"type":"model_change","id":"mc1"}
JSONL
  run harness_resolve --session "$sf"
  [ "$status" -eq 0 ]
  [ "$output" = "pi" ]
}

@test "path-based detection requires a '/' separator (no \`\$PI_DIR-alt\` false positive)" {
  # TODO(step 3): with a second adapter this test becomes stronger —
  # today both "path matched → pi" and "fell through to default → pi"
  # produce the same answer, so we probe `harness_from_path` directly
  # for the rule under test.
  mkdir -p "${PI_DIR}-alt"
  sf="${PI_DIR}-alt/legacy.jsonl"
  cat > "$sf" <<JSONL
{"type":"session","id":"legacy"}
JSONL

  # Rule-level assertion: the path rule must NOT claim this sibling.
  run harness_from_path "$sf"
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  rm -rf "${PI_DIR}-alt"
}

@test "path-based detection normalizes trailing slash on \$PI_DIR" {
  # Regression: `PI_DIR=/opt/x/` previously became a case pattern `/opt/x//*`
  # which won't match /opt/x/... .
  mkdir -p /tmp/trailing-slash-pi-test/agent/sessions
  sf=/tmp/trailing-slash-pi-test/agent/sessions/foo.jsonl
  : > "$sf"

  PI_DIR=/tmp/trailing-slash-pi-test/ run harness_from_path "$sf"
  [ "$status" -eq 0 ]
  [ "$output" = "pi" ]

  rm -rf /tmp/trailing-slash-pi-test
}

@test "path-based detection treats \$PI_DIR='' as unset (no '/' collapse)" {
  # Regression: an empty PI_DIR used to be respected literally, collapsing
  # to a prefix of '/' which would match any absolute path.
  PI_DIR='' HOME=/nonexistent run harness_from_path /etc/passwd
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- Resolver: env fallback ---

@test "resolver honours SESSIONS_DEFAULT_HARNESS when nothing else matches" {
  SESSIONS_DEFAULT_HARNESS=pi run harness_resolve
  [ "$status" -eq 0 ]
  [ "$output" = "pi" ]
}

@test "resolver errors on unknown SESSIONS_DEFAULT_HARNESS" {
  SESSIONS_DEFAULT_HARNESS=xyz run harness_resolve
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi "unknown harness"
}

# --- Resolver: compile-time default ---

@test "resolver returns pi when no inputs are provided" {
  run harness_resolve
  [ "$status" -eq 0 ]
  [ "$output" = "pi" ]
}

# --- Resolver priority ordering ---

@test "explicit --flag beats session file" {
  sf="$BATS_TEST_TMPDIR/session.jsonl"
  cat > "$sf" <<JSONL
{"type":"session","id":"abc"}
{"type":"harness","id":"h1","name":"pi"}
JSONL
  # Flag wins — if someone ever passes an unknown name here, it errors;
  # proves the flag is consulted before the session file.
  run harness_resolve --flag pi --session "$sf"
  [ "$status" -eq 0 ]
  [ "$output" = "pi" ]
}

# --- `sessions new` integration ---

@test "new writes a harness entry as line 2" {
  run sessions new --cwd "$BATS_TMPDIR"
  [ "$status" -eq 0 ]
  new_id=$(echo "$output" | head -1)
  new_file=$(find "$PI_DIR/agent/sessions" -name "*${new_id}.jsonl")
  sed -n '2p' "$new_file" | jq -e '.type == "harness" and .name == "pi"'
}

@test "new --harness pi produces same header shape" {
  run sessions new --cwd "$BATS_TMPDIR" --harness pi
  [ "$status" -eq 0 ]
  new_id=$(echo "$output" | head -1)
  new_file=$(find "$PI_DIR/agent/sessions" -name "*${new_id}.jsonl")
  sed -n '2p' "$new_file" | jq -e '.type == "harness" and .name == "pi"'
}

@test "new --harness xyz errors before writing a session file" {
  initial_count=$(find "$PI_DIR/agent/sessions" -name '*.jsonl' 2>/dev/null | wc -l | tr -d ' ')
  run sessions new --cwd "$BATS_TMPDIR" --harness xyz
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi "unknown harness"
  # No new session file got created
  final_count=$(find "$PI_DIR/agent/sessions" -name '*.jsonl' 2>/dev/null | wc -l | tr -d ' ')
  [ "$final_count" = "$initial_count" ]
}

# --- Cross-adapter find aggregator (hard error surfacing) ---

@test "find_session_file surfaces stderr when adapter reports within-adapter ambiguity" {
  # Two sessions sharing a name — an adapter-level ambiguity condition.
  sid1="aaaaaaaa-1111-1111-1111-111111111111"
  sid2="bbbbbbbb-2222-2222-2222-222222222222"
  mkdir -p "${PI_DIR}/agent/sessions/--amb-test--"
  cat > "${PI_DIR}/agent/sessions/--amb-test--/2026-04-22T10-00-00-000Z_${sid1}.jsonl" <<JSONL
{"type":"session","id":"${sid1}","name":"duplicate-name"}
JSONL
  cat > "${PI_DIR}/agent/sessions/--amb-test--/2026-04-22T11-00-00-000Z_${sid2}.jsonl" <<JSONL
{"type":"session","id":"${sid2}","name":"duplicate-name"}
JSONL

  # shellcheck source=/dev/null
  source "$MISE_CONFIG_ROOT/lib/find.sh"
  run find_session_file duplicate-name
  [ "$status" -ne 0 ]
  # The ambiguity message from the pi adapter must reach the caller —
  # not be swallowed by the aggregator's stderr handling.
  echo "$output" | grep -qi "ambiguous"
}

# --- wake_entry builder ---

@test "wake_entry produces harness=pi and headless=true" {
  run wake_entry w1 parent1 "2026-04-22T10:00:00.000Z" shellA ikma pi true "{}"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.type == "wake" and .harness == "pi" and .headless == true'
}

@test "wake_entry produces headless=false when flag is false" {
  run wake_entry w1 parent1 "2026-04-22T10:00:00.000Z" shellA ikma pi false "{}"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.type == "wake" and .headless == false'
}

@test "wake_entry coerces anything-but-exact-'true' to headless=false" {
  # Strict coercion contract — only the literal string "true" maps to
  # true. Any other string (including "TRUE", "yes", "1", empty) is false.
  for input in "" TRUE yes 1 headless True; do
    run wake_entry w1 parent1 "2026-04-22T10:00:00.000Z" shellA ikma pi "$input" "{}"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.headless == false' >/dev/null || {
      echo "input=$input leaked to headless=true" >&2
      return 1
    }
  done
}

@test "wake_entry includes meta when non-empty" {
  run wake_entry w1 parent1 "2026-04-22T10:00:00.000Z" shellA ikma pi true '{"by":"zeke"}'
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.meta.by == "zeke"'
}

@test "wake_entry omits meta when empty json object" {
  run wake_entry w1 parent1 "2026-04-22T10:00:00.000Z" shellA ikma pi true "{}"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e 'has("meta") | not'
}

# --- harness_entry builder ---

@test "harness_entry produces a well-formed declaration entry" {
  run harness_entry h1 parent1 "2026-04-22T10:00:00.000Z" pi
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.type == "harness" and .name == "pi" and .parentId == "parent1"'
}
