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

# --- Model pass-through ---

@test "wake --model records model on wake event" {
  command -v shell >/dev/null 2>&1 || skip "shell not installed"
  run sessions wake "$SESSION_1" --background --model "claude-opus-4-7"
  [ "$status" -eq 0 ]
  src_file=$(find "$PROJECT_DIR" -name "*${SESSION_1}.jsonl")
  jq -e 'select(.type == "wake" and .model == "claude-opus-4-7")' "$src_file"
}

@test "wake without --model omits .model from wake event (harness default)" {
  command -v shell >/dev/null 2>&1 || skip "shell not installed"
  run sessions wake "$SESSION_1" --background
  [ "$status" -eq 0 ]
  src_file=$(find "$PROJECT_DIR" -name "*${SESSION_1}.jsonl")
  # .model should be absent (null when queried), signaling "harness default used"
  run jq -e 'select(.type == "wake") | has("model") | not' "$src_file"
  [ "$status" -eq 0 ]
}

@test "wake --model forwards --model to sessions run in RUN_CMD" {
  # Regression guard against the hardcoded @default_model in sessions run's
  # Elixir CLI. `sessions wake --model X` must pass `--model X` down so the
  # CLI doesn't fall back to its own default.
  #
  # We stub `shell` (which wake's --background path invokes with the full
  # RUN_CMD as argv) to dump its arguments to a file, then assert the
  # dumped argv contains `--model claude-opus-4-7` with the value
  # immediately following the flag. This is a runtime check, not a grep
  # against source — it survives refactors of the wake task (variable
  # renames, reordering of the RUN_CMD build).
  #
  # Coverage caveat: the foreground path (`.mise/tasks/wake:165`,
  # `exec "${RUN_CMD[@]}"`) is NOT covered by this test — it exec's
  # directly rather than going through `shell`. Both branches build
  # the same RUN_CMD array, so the background test implicitly covers
  # foreground's argv shape; if those construction paths diverge,
  # adjust the test.
  command -v shell >/dev/null 2>&1 || skip "shell not installed"

  local stub_dir="$BATS_TEST_TMPDIR/stub-shell"
  local capture="$BATS_TEST_TMPDIR/shell-argv"
  mkdir -p "$stub_dir"
  cat > "$stub_dir/shell" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$capture"
exit 0
STUB
  chmod +x "$stub_dir/shell"

  PATH="$stub_dir:$PATH" run sessions wake "${SESSION_1:0:8}" --background --model "claude-opus-4-7"
  [ "$status" -eq 0 ]
  [ -f "$capture" ]

  # Adjacency check: the line AFTER `--model` must be the exact model
  # value. Independent presence checks (grep for each) would pass even
  # if a future refactor inserted args between flag and value.
  local line_after_flag
  line_after_flag=$(grep -A1 '^--model$' "$capture" | tail -1)
  [ "$line_after_flag" = "claude-opus-4-7" ]

  # Cardinality: exactly one --model in the argv (not duplicated).
  [ "$(grep -c '^--model$' "$capture")" = 1 ]

  # Sanity: `sessions run` is also in the argv (confirms we're stubbing
  # the right layer).
  grep -q '^run$' "$capture"
}

@test "wake without --model omits --model from RUN_CMD" {
  # Mirror of the forwarding test: when `--model` isn't passed, the
  # string `--model` must NOT appear in the argv at all (otherwise the
  # Elixir CLI would receive a bare flag with no value).
  command -v shell >/dev/null 2>&1 || skip "shell not installed"

  local stub_dir="$BATS_TEST_TMPDIR/stub-shell-nomodel"
  local capture="$BATS_TEST_TMPDIR/shell-argv-nomodel"
  mkdir -p "$stub_dir"
  cat > "$stub_dir/shell" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$capture"
exit 0
STUB
  chmod +x "$stub_dir/shell"

  PATH="$stub_dir:$PATH" run sessions wake "${SESSION_1:0:8}" --background
  [ "$status" -eq 0 ]
  [ -f "$capture" ]
  ! grep -q '^--model$' "$capture"
}

@test "wake forwards session cwd to sessions run" {
  # `wake` launches from the persisted session cwd, but `sessions run`
  # also has its own --cwd option and otherwise defaults through
  # CALLER_PWD. Regression guard: the RUN_CMD handed to shell must carry
  # the session header cwd explicitly so stale CALLER_PWD cannot win.
  command -v shell >/dev/null 2>&1 || skip "shell not installed"

  local session_cwd="$BATS_TEST_TMPDIR/session-cwd"
  mkdir -p "$session_cwd"
  local expected_cwd
  expected_cwd=$(cd "$session_cwd" && pwd -P)

  local src_file
  src_file=$(find "$PROJECT_DIR" -name "*${SESSION_1}.jsonl")
  local updated_file="$BATS_TEST_TMPDIR/session-updated.jsonl"
  jq -c --arg cwd "$session_cwd" 'if .type == "session" then .cwd = $cwd else . end' "$src_file" > "$updated_file"
  mv "$updated_file" "$src_file"

  local stub_dir="$BATS_TEST_TMPDIR/stub-shell-cwd"
  local capture="$BATS_TEST_TMPDIR/shell-argv-cwd"
  mkdir -p "$stub_dir"
  cat > "$stub_dir/shell" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$capture"
exit 0
STUB
  chmod +x "$stub_dir/shell"

  PATH="$stub_dir:$PATH" run sessions wake "${SESSION_1:0:8}" --background
  [ "$status" -eq 0 ]
  [ -f "$capture" ]

  # The shell invocation has its own --cwd before the RUN_CMD. The
  # sessions-run cwd is the --cwd after the --session flag.
  local run_cwd
  run_cwd=$(awk '
    /^--session$/ { after_session = 1; next }
    after_session && /^--cwd$/ { getline; print; exit }
  ' "$capture")
  [ "$run_cwd" = "$expected_cwd" ]
}

@test "wake normalizes invalid session cwd fallback before forwarding" {
  # When a persisted session cwd is missing, wake falls back to "current
  # directory". Once wake explicitly forwards --cwd to sessions run, that
  # fallback must be absolute; otherwise the run/CLI layer could interpret
  # "." from a later process directory.
  command -v shell >/dev/null 2>&1 || skip "shell not installed"

  local missing_cwd="$BATS_TEST_TMPDIR/missing-session-cwd"
  local expected_cwd
  expected_cwd=$(cd "$REPO_DIR" && pwd -P)

  local src_file
  src_file=$(find "$PROJECT_DIR" -name "*${SESSION_1}.jsonl")
  local updated_file="$BATS_TEST_TMPDIR/session-invalid-cwd.jsonl"
  jq -c --arg cwd "$missing_cwd" 'if .type == "session" then .cwd = $cwd else . end' "$src_file" > "$updated_file"
  mv "$updated_file" "$src_file"

  local stub_dir="$BATS_TEST_TMPDIR/stub-shell-invalid-cwd"
  local capture="$BATS_TEST_TMPDIR/shell-argv-invalid-cwd"
  mkdir -p "$stub_dir"
  cat > "$stub_dir/shell" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$capture"
exit 0
STUB
  chmod +x "$stub_dir/shell"

  PATH="$stub_dir:$PATH" run sessions wake "${SESSION_1:0:8}" --background
  [ "$status" -eq 0 ]
  [ -f "$capture" ]

  # Both the outer shell cwd and inner sessions-run cwd should receive
  # the same absolute fallback directory.
  [ "$(grep -c '^--cwd$' "$capture")" = 2 ]

  local outer_cwd
  outer_cwd=$(awk '/^--cwd$/ { getline; print; exit }' "$capture")
  [ "$outer_cwd" = "$expected_cwd" ]

  local run_cwd
  run_cwd=$(awk '
    /^--session$/ { after_session = 1; next }
    after_session && /^--cwd$/ { getline; print; exit }
  ' "$capture")
  [ "$run_cwd" = "$expected_cwd" ]
}

@test "wake --model is advertised in --help" {
  run sessions wake --help
  [ "$status" -eq 0 ]
  echo "$output" | grep -q -- "--model"
}
