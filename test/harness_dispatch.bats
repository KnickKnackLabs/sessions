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
  export HARNESS_LIB_DIR="$REPO_DIR/lib/harness"
  source "$REPO_DIR/lib/harness/dispatch.sh"
}

teardown() {
  teardown_test_sessions
}

# --- Registry ---

@test "harness_list returns installed adapters" {
  run harness_list
  [ "$status" -eq 0 ]
  # Sorted output, one per line. Update this list as adapters land.
  [ "$output" = "claude
pi" ]
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
  # Two-adapter version: earlier entry is pi, later entry is claude.
  # Before claude existed, this test could only prove "pi→pi" (a
  # tautology). With two adapters registered, we can actually assert
  # the most-recent entry wins over an older one of a different kind.
  sf="$BATS_TEST_TMPDIR/session.jsonl"
  cat > "$sf" <<JSONL
{"type":"session","id":"abc"}
{"type":"harness","id":"h1","parentId":"abc","timestamp":"2026-04-22T10:00:00.000Z","name":"pi"}
{"type":"model_change","id":"mc1"}
{"type":"wake","id":"w1"}
{"type":"harness","id":"h2","parentId":"w1","timestamp":"2026-04-22T11:00:00.000Z","name":"claude"}
JSONL
  run harness_resolve --session "$sf"
  [ "$status" -eq 0 ]
  [ "$output" = "claude" ]
}

@test "resolver reads a claude harness entry from the session file" {
  sf="$BATS_TEST_TMPDIR/session.jsonl"
  cat > "$sf" <<JSONL
{"type":"session","version":3,"id":"abc","timestamp":"2026-04-22T10:00:00.000Z","cwd":"/tmp"}
{"type":"harness","id":"h1","parentId":"abc","timestamp":"2026-04-22T10:00:00.000Z","name":"claude"}
JSONL
  run harness_resolve --session "$sf"
  [ "$status" -eq 0 ]
  [ "$output" = "claude" ]
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
  # Now that a second adapter exists, we can verify this end-to-end
  # through `harness_resolve`: a path that looks pi-adjacent but
  # isn't under PI_DIR must fall through past path detection, past the
  # env default, and hit the compile-time default (pi). We can tell
  # path detection didn't fire because the sibling directory is never
  # claimed by any adapter — if the rule were loose, a claude-adjacent
  # path would resolve to claude, not pi. Use a claude-adjacent path
  # so the assertion bites.
  mkdir -p "${HOME}/.claude-alt"
  sf="${HOME}/.claude-alt/legacy.jsonl"
  cat > "$sf" <<JSONL
{"type":"session","id":"legacy"}
JSONL

  run harness_from_path "$sf"
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  rm -rf "${HOME}/.claude-alt"
}

@test "path-based detection claims \`\$CLAUDE_DIR/*\` for claude" {
  mkdir -p "$BATS_TEST_TMPDIR/claude-home/projects"
  sf="$BATS_TEST_TMPDIR/claude-home/projects/legacy.jsonl"
  : > "$sf"

  CLAUDE_DIR="$BATS_TEST_TMPDIR/claude-home" run harness_from_path "$sf"
  [ "$status" -eq 0 ]
  [ "$output" = "claude" ]
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
  # Two-adapter version: session file declares pi, flag says claude.
  # If the flag weren't consulted first we'd get pi. We get claude, so
  # the flag truly wins over the file.
  sf="$BATS_TEST_TMPDIR/session.jsonl"
  cat > "$sf" <<JSONL
{"type":"session","id":"abc"}
{"type":"harness","id":"h1","name":"pi"}
JSONL
  run harness_resolve --flag claude --session "$sf"
  [ "$status" -eq 0 ]
  [ "$output" = "claude" ]
}

@test "session file beats path-based detection" {
  # File lives under PI_DIR but declares claude in its harness entry.
  # The harness-entry rule must win over the path prefix.
  mkdir -p "${PI_DIR}/agent/sessions/--priority--"
  sf="${PI_DIR}/agent/sessions/--priority--/mixed.jsonl"
  cat > "$sf" <<JSONL
{"type":"session","id":"abc"}
{"type":"harness","id":"h1","name":"claude"}
JSONL
  run harness_resolve --session "$sf"
  [ "$status" -eq 0 ]
  [ "$output" = "claude" ]
}

@test "path-based detection beats env default" {
  # File under PI_DIR with no harness entry; env says claude.
  # Path rule should fire first and pick pi.
  mkdir -p "${PI_DIR}/agent/sessions/--priority--"
  sf="${PI_DIR}/agent/sessions/--priority--/legacy.jsonl"
  cat > "$sf" <<JSONL
{"type":"session","id":"legacy"}
JSONL
  SESSIONS_DEFAULT_HARNESS=claude run harness_resolve --session "$sf"
  [ "$status" -eq 0 ]
  [ "$output" = "pi" ]
}

@test "env default beats compile-time default when set" {
  # No session file, no flag, no path. Env override should win.
  SESSIONS_DEFAULT_HARNESS=claude run harness_resolve
  [ "$status" -eq 0 ]
  [ "$output" = "claude" ]
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

@test "new --harness claude exits UNSUPPORTED without side effects (step 3 acceptance)" {
  # Step 3 claude is a skeleton; session_file_path is UNSUPPORTED, so
  # `new` must fail before any directory is created. Uses \$CLAUDE_DIR
  # for isolation so we don't poke at the real ~/.claude.
  export CLAUDE_DIR="$BATS_TEST_TMPDIR/claude-home"

  run sessions new --cwd "$BATS_TMPDIR" --harness claude acceptance-foo
  [ "$status" -eq 10 ]
  echo "$output" | grep -q "'claude' harness does not support 'session_file_path'"

  # No artifacts: the claude projects dir should not have been created.
  [ ! -d "$CLAUDE_DIR/projects" ]
}

@test "wake on a claude-declared session routes to claude and errors UNSUPPORTED (step 3 acceptance)" {
  # Hand-craft a session file with a harness=claude entry. The file
  # lives under PI_DIR so pi's find_session locates it; the harness
  # entry then wins over path-based detection (see the priority test
  # above), so wake dispatches to claude — which errors UNSUPPORTED
  # when the Elixir run path asks claude for its default model.
  # Foreground wake (no --background) — execs mise run directly, so
  # `shell` isn't required.

  local sid="cccccccc-3333-3333-3333-333333333333"
  local sf="$PI_DIR/agent/sessions/--claude-acceptance--/2026-04-22T10-00-00-000Z_${sid}.jsonl"
  mkdir -p "$(dirname "$sf")"
  cat > "$sf" <<JSONL
{"type":"session","version":3,"id":"${sid}","timestamp":"2026-04-22T10:00:00.000Z","cwd":"$BATS_TMPDIR"}
{"type":"harness","id":"h1","parentId":"${sid}","timestamp":"2026-04-22T10:00:00.000Z","name":"claude"}
JSONL

  run sessions wake "${sid:0:8}" --message "acceptance"
  [ "$status" -eq 10 ]
  # The user-facing message should name the claude harness and the
  # specific unsupported op. Which op fires first depends on the
  # Elixir startup order; default_model is the earliest thing to need
  # claude knowledge.
  echo "$output" | grep -q "'claude' harness does not support"
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
  source "$REPO_DIR/lib/find.sh"
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

# --- UNSUPPORTED contract ---

@test "harness_unsupported returns the reserved exit code" {
  run bash -c '
    source "$1/lib/harness/dispatch.sh"
    harness_unsupported
  ' _ "$REPO_DIR"
  [ "$status" -eq 10 ]
  [ -z "$output" ]
}

@test "harness_call passes through on success" {
  run bash -c '
    source "$1/lib/harness/dispatch.sh"
    harness_fake_ok() { echo "hello from fake"; }
    harness_call fake ok
  ' _ "$REPO_DIR"
  [ "$status" -eq 0 ]
  [ "$output" = "hello from fake" ]
}

@test "harness_call prints clean UNSUPPORTED message and exits 10" {
  run bash -c '
    source "$1/lib/harness/dispatch.sh"
    harness_skel_header_entry() { harness_unsupported; }
    harness_call skel header_entry
    echo "should not reach"
  ' _ "$REPO_DIR"
  [ "$status" -eq 10 ]
  echo "$output" | grep -qi "'skel' harness does not support 'header_entry'"
  # Ensure we really exited, not just returned.
  ! echo "$output" | grep -q "should not reach"
}

@test "harness_call preserves stdout so callers can redirect it" {
  # Regression guard: `new` uses `harness_call ... > file`, which
  # requires the function's stdout to reach the caller's redirect.
  local tmp="$BATS_TEST_TMPDIR/captured"
  bash -c '
    source "$1/lib/harness/dispatch.sh"
    harness_fake_emit() { echo "payload"; }
    harness_call fake emit > "$2"
  ' _ "$REPO_DIR" "$tmp"
  [ "$(cat "$tmp")" = "payload" ]
}

@test "harness_call returns non-UNSUPPORTED exit codes instead of exiting" {
  # Adapters may fail for reasons other than UNSUPPORTED (e.g. a jq
  # parse failure). Those should propagate as ordinary return values
  # so callers can decide — not collapse into UNSUPPORTED's exit path.
  run bash -c '
    source "$1/lib/harness/dispatch.sh"
    harness_fake_boom() { return 3; }
    harness_call fake boom || echo "got rc=$?"
    echo "kept going"
  ' _ "$REPO_DIR"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "got rc=3"
  echo "$output" | grep -q "kept going"
}
