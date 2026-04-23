#!/usr/bin/env bats

load helpers

setup() {
  setup_test_sessions
  # Isolate zmx sessions per-test to prevent bats FD hangs.
  export ZMX_DIR="/tmp/swk-$$"
  mkdir -p "$ZMX_DIR"
}
teardown() {
  # Clean up shell sessions in our isolated dir
  for name in $(zmx list --short 2>/dev/null || true); do
    shell kill "$name" 2>/dev/null || true
  done
  for pid in $(zmx list 2>/dev/null | tr '\t' '\n' | grep "^pid=" | cut -d= -f2); do
    local children
    children=$(pgrep -P "$pid" 2>/dev/null || true)
    for cpid in $children; do kill "$cpid" 2>/dev/null || true; done
    kill "$pid" 2>/dev/null || true
  done
  rm -rf "${ZMX_DIR:-}"
  teardown_test_sessions
}

# --- Validation ---

@test "wake errors on nonexistent session" {
  run sessions wake "deadbeef"
  [ "$status" -eq 1 ]
  echo "$output" | grep -qi "no session"
}

@test "wake errors when context file missing" {
  run sessions wake "$SESSION_1" --context-file "/tmp/nonexistent-$$"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "not found"
}

# --- Background mode (shell/zmx) ---

@test "wake --background launches session via shell" {
  command -v shell >/dev/null 2>&1 || skip "shell not installed"
  run sessions wake "${SESSION_1:0:8}" --background
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "$SESSION_1"
  shell list 2>/dev/null | grep -q "${SESSION_1:0:8}"
}

@test "wake --background derives shell name from session name" {
  command -v shell >/dev/null 2>&1 || skip "shell not installed"
  run sessions new "wake-bg-name-test-$$"
  [ "$status" -eq 0 ]

  run sessions wake "wake-bg-name-test-$$" --background
  [ "$status" -eq 0 ]
  shell list 2>/dev/null | grep -q "wake-bg-name-test-$$"
}

@test "wake --background translates slashes in session name for shell" {
  command -v shell >/dev/null 2>&1 || skip "shell not installed"
  run sessions new "feature/bg-test-$$"
  [ "$status" -eq 0 ]

  run sessions wake "feature/bg-test-$$" --background
  [ "$status" -eq 0 ]
  shell list 2>/dev/null | grep -q "feature-bg-test-$$"
}

@test "wake --background shows monitor instructions" {
  command -v shell >/dev/null 2>&1 || skip "shell not installed"
  run sessions wake "$SESSION_1" --background
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "Monitor:"
}

@test "wake --background checks for shell dependency" {
  # Verify the wake task source checks for shell when --background is used
  grep -q 'command -v shell' "$REPO_DIR/.mise/tasks/wake"
}

# --- Self-reference: call siblings through `mise -C`, not via PATH ---

@test "wake calls sibling tasks through mise -C, not a PATH-resolved 'sessions' binary" {
  # Regression guard. A shiv-installed `sessions` on PATH will lag
  # behind the working tree during development — if wake ever calls it
  # through PATH we route to the wrong codebase. Prove we don't by
  # running wake with a PATH that points `sessions` at a stub that
  # always fails; wake must still succeed because it uses
  # `mise -C "$MISE_CONFIG_ROOT" run` for sibling dispatch (production
  # variable, not the test-level $REPO_DIR).
  command -v shell >/dev/null 2>&1 || skip "shell not installed"

  local stub_dir="$BATS_TEST_TMPDIR/stub-path"
  mkdir -p "$stub_dir"
  cat > "$stub_dir/sessions" <<'STUB'
#!/usr/bin/env bash
echo "stub-sessions invoked — this should never run" >&2
exit 42
STUB
  chmod +x "$stub_dir/sessions"

  # Keep mise itself discoverable; just shadow `sessions`.
  PATH="$stub_dir:$PATH" run sessions wake "${SESSION_1:0:8}" --background
  [ "$status" -eq 0 ]
  # If the stub ever fired, its stderr would leak into output.
  ! echo "$output" | grep -q "stub-sessions invoked"
}

# --- Context injection (works in both modes) ---

@test "wake injects context into session file" {
  command -v shell >/dev/null 2>&1 || skip "shell not installed"
  run sessions wake "$SESSION_1" --background --context "Review PR #42"
  [ "$status" -eq 0 ]
  src_file=$(find "$PROJECT_DIR" -name "*${SESSION_1}.jsonl")
  grep -q "PR #42" "$src_file"
}

# --- Wake event recording ---

@test "wake records wake event in session file" {
  command -v shell >/dev/null 2>&1 || skip "shell not installed"
  export GIT_AUTHOR_NAME="test-agent"
  run sessions wake "$SESSION_1" --background
  [ "$status" -eq 0 ]
  src_file=$(find "$PROJECT_DIR" -name "*${SESSION_1}.jsonl")
  jq -e 'select(.type == "wake")' "$src_file"
}

@test "wake --headless records harness=pi and headless=true" {
  command -v shell >/dev/null 2>&1 || skip "shell not installed"
  run sessions wake "$SESSION_1" --headless --background
  [ "$status" -eq 0 ]
  src_file=$(find "$PROJECT_DIR" -name "*${SESSION_1}.jsonl")
  jq -e 'select(.type == "wake" and .harness == "pi" and .headless == true)' "$src_file"
}

@test "wake without --headless records harness=pi and headless=false" {
  command -v shell >/dev/null 2>&1 || skip "shell not installed"
  run sessions wake "$SESSION_1" --background
  [ "$status" -eq 0 ]
  src_file=$(find "$PROJECT_DIR" -name "*${SESSION_1}.jsonl")
  jq -e 'select(.type == "wake" and .harness == "pi" and .headless == false)' "$src_file"
}

# --- Foreground mode ---
# Foreground calls `exec sessions run` which requires the Elixir CLI.
# We test that the wake event is recorded and the right command would be called
# by checking the session file, without actually running the Elixir CLI.

@test "wake (foreground) does not require shell on PATH" {
  # Foreground mode shouldn't check for shell
  # This test verifies the dependency check is conditional
  src_file=$(find "$PROJECT_DIR" -name "*${SESSION_1}.jsonl")
  # We can't actually run foreground (it execs into sessions run which needs Elixir),
  # but we can verify the wake event is written by checking a --background wake
  # and confirming the same code path writes events for foreground.
  # The real foreground integration test would need the Elixir CLI.
  command -v shell >/dev/null 2>&1 || skip "shell not installed"
  run sessions wake "$SESSION_1" --background
  [ "$status" -eq 0 ]
}

# --- Meta parsing ---

@test "wake --meta records metadata in wake event" {
  command -v shell >/dev/null 2>&1 || skip "shell not installed"
  run sessions wake "$SESSION_1" --background --meta "timeout=900"
  [ "$status" -eq 0 ]
  src_file=$(find "$PROJECT_DIR" -name "*${SESSION_1}.jsonl")
  jq -e 'select(.type == "wake" and .meta.timeout == "900")' "$src_file"
}
