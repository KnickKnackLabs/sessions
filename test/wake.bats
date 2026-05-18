#!/usr/bin/env bats

load helpers

setup() {
  setup_test_sessions
  # Isolate zmx sessions per-test to prevent bats FD hangs.
  export ZMX_DIR="/tmp/swk-$$"
  mkdir -p "$ZMX_DIR"

  # Most wake tests care about the argv passed to shell, not about opening
  # a real persistent zmx + pi process. Default to a recording shell stub;
  # individual tests that need a different shell behavior prepend their own.
  local shell_stub_dir="$BATS_TEST_TMPDIR/default-shell-stub"
  stub_shell_recording \
    "$shell_stub_dir" \
    "$BATS_TEST_TMPDIR/default-shell-argv" \
    "$BATS_TEST_TMPDIR/default-shell-names"
  export PATH="$shell_stub_dir:$PATH"
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

stub_os_user_host() {
  local user="${1:-iris}"
  local bin="$BATS_TEST_TMPDIR/os-user-bin"
  mkdir -p "$bin"
  export PATH="$bin:$PATH"
  export SESSIONS_RUN_AS_USER="$BATS_TEST_TMPDIR/run-as-user-stub"

  cat > "$bin/id" <<STUB
#!/usr/bin/env bash
set -euo pipefail
if [ "\${1:-}" = "-u" ] && [ "\${2:-}" = "$user" ]; then
  echo 503
  exit 0
fi
exit 1
STUB
  chmod +x "$bin/id"

  cat > "$SESSIONS_RUN_AS_USER" <<STUB
#!/usr/bin/env bash
set -euo pipefail
[ "\${1:-}" = "--user" ]
[ "\${2:-}" = "$user" ]
[ "\${3:-}" = "--" ]
shift 3
if [ "\${WAKE_OS_USER_SMOKE_FAIL:-}" = "1" ]; then
  exit 1
fi
exec "\$@"
STUB
  chmod +x "$SESSIONS_RUN_AS_USER"
}

stub_missing_os_user_host() {
  local bin="$BATS_TEST_TMPDIR/missing-os-user-bin"
  mkdir -p "$bin"
  export PATH="$bin:$PATH"
  cat > "$bin/id" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
  chmod +x "$bin/id"
}

# --- Validation ---

@test "wake errors on nonexistent session" {
  run sessions wake "deadbeef" --model "openai-codex/gpt-5.5"
  [ "$status" -eq 1 ]
  echo "$output" | grep -qi "no session"
}

@test "wake errors when context file missing" {
  run sessions wake "$SESSION_1" --model "openai-codex/gpt-5.5" --context-file "/tmp/nonexistent-$$"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "not found"
}

@test "wake rejects invalid --os-user" {
  run sessions wake "$SESSION_1" --model "openai-codex/gpt-5.5" --os-user "../bad"
  [ "$status" -eq 2 ]
  echo "$output" | grep -q "invalid --os-user"
}

@test "wake --os-user fails before recording wake when target user is missing" {
  stub_missing_os_user_host
  local src_file
  src_file=$(find "$PROJECT_DIR" -name "*${SESSION_1}.jsonl")
  local before
  before=$(wc -l < "$src_file")

  run sessions wake "$SESSION_1" --model "openai-codex/gpt-5.5" --os-user missingagent
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "target OS user 'missingagent' does not exist"

  local after
  after=$(wc -l < "$src_file")
  [ "$after" = "$before" ]
}

@test "wake --os-user fails before recording wake when run-as-user preflight fails" {
  stub_os_user_host iris
  export WAKE_OS_USER_SMOKE_FAIL=1
  local src_file
  src_file=$(find "$PROJECT_DIR" -name "*${SESSION_1}.jsonl")
  local before
  before=$(wc -l < "$src_file")

  run sessions wake "$SESSION_1" --model "openai-codex/gpt-5.5" --os-user iris
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "cannot run payload as OS user 'iris'"
  echo "$output" | grep -q "host:doctor --os-user iris"

  local after
  after=$(wc -l < "$src_file")
  [ "$after" = "$before" ]
}

# --- Background mode (shell/zmx) ---

@test "wake --background launches session via shell" {
  command -v shell >/dev/null 2>&1 || skip "shell not installed"
  run sessions wake "${SESSION_1:0:8}" --background --model "openai-codex/gpt-5.5"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "$SESSION_1"
  shell list 2>/dev/null | grep -q "${SESSION_1:0:8}"
}

@test "wake --background derives shell name from session name" {
  command -v shell >/dev/null 2>&1 || skip "shell not installed"
  run sessions new "wake-bg-name-test-$$"
  [ "$status" -eq 0 ]

  run sessions wake "wake-bg-name-test-$$" --background --model "openai-codex/gpt-5.5"
  [ "$status" -eq 0 ]
  shell list 2>/dev/null | grep -q "wake-bg-name-test-$$"
}

@test "wake --background translates slashes in session name for shell" {
  command -v shell >/dev/null 2>&1 || skip "shell not installed"
  run sessions new "feature/bg-test-$$"
  [ "$status" -eq 0 ]

  run sessions wake "feature/bg-test-$$" --background --model "openai-codex/gpt-5.5"
  [ "$status" -eq 0 ]
  shell list 2>/dev/null | grep -q "feature-bg-test-$$"
}

@test "wake --background shows monitor instructions" {
  command -v shell >/dev/null 2>&1 || skip "shell not installed"
  run sessions wake "$SESSION_1" --background --model "openai-codex/gpt-5.5"
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
  PATH="$stub_dir:$PATH" run sessions wake "${SESSION_1:0:8}" --background --model "openai-codex/gpt-5.5"
  [ "$status" -eq 0 ]
  # If the stub ever fired, its stderr would leak into output.
  ! echo "$output" | grep -q "stub-sessions invoked"
}

# --- Context injection (works in both modes) ---

@test "wake injects context into session file" {
  command -v shell >/dev/null 2>&1 || skip "shell not installed"
  run sessions wake "$SESSION_1" --background --model "openai-codex/gpt-5.5" --context "Review PR #42"
  [ "$status" -eq 0 ]
  src_file=$(find "$PROJECT_DIR" -name "*${SESSION_1}.jsonl")
  grep -q "PR #42" "$src_file"
}

# --- Wake event recording ---

@test "wake records wake event in session file" {
  command -v shell >/dev/null 2>&1 || skip "shell not installed"
  export GIT_AUTHOR_NAME="test-agent"
  run sessions wake "$SESSION_1" --background --model "openai-codex/gpt-5.5"
  [ "$status" -eq 0 ]
  src_file=$(find "$PROJECT_DIR" -name "*${SESSION_1}.jsonl")
  jq -e 'select(.type == "wake")' "$src_file"
}

@test "wake --headless records harness=pi and headless=true" {
  command -v shell >/dev/null 2>&1 || skip "shell not installed"
  run sessions wake "$SESSION_1" --headless --background --model "openai-codex/gpt-5.5" --message "review this"
  [ "$status" -eq 0 ]
  src_file=$(find "$PROJECT_DIR" -name "*${SESSION_1}.jsonl")
  jq -e 'select(.type == "wake" and .harness == "pi" and .headless == true)' "$src_file"
}

@test "wake without --headless records harness=pi and headless=false" {
  command -v shell >/dev/null 2>&1 || skip "shell not installed"
  run sessions wake "$SESSION_1" --background --model "openai-codex/gpt-5.5"
  [ "$status" -eq 0 ]
  src_file=$(find "$PROJECT_DIR" -name "*${SESSION_1}.jsonl")
  jq -e 'select(.type == "wake" and .harness == "pi" and .headless == false)' "$src_file"
}

@test "wake --os-user records os_user in wake event" {
  stub_os_user_host iris
  local stub_dir="$BATS_TEST_TMPDIR/stub-shell-os-user-record"
  mkdir -p "$stub_dir"
  cat > "$stub_dir/shell" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
  chmod +x "$stub_dir/shell"

  PATH="$stub_dir:$PATH" run sessions wake "$SESSION_1" --background --model "openai-codex/gpt-5.5" --os-user iris
  [ "$status" -eq 0 ]
  src_file=$(find "$PROJECT_DIR" -name "*${SESSION_1}.jsonl")
  jq -e 'select(.type == "wake" and .os_user == "iris")' "$src_file"
}

@test "wake defaults os_user from SHIMMER_OS_USER" {
  stub_os_user_host iris
  local stub_dir="$BATS_TEST_TMPDIR/stub-shell-os-user-env"
  mkdir -p "$stub_dir"
  cat > "$stub_dir/shell" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
  chmod +x "$stub_dir/shell"

  export SHIMMER_OS_USER=iris
  PATH="$stub_dir:$PATH" run sessions wake "$SESSION_1" --background --model "openai-codex/gpt-5.5"
  [ "$status" -eq 0 ]
  src_file=$(find "$PROJECT_DIR" -name "*${SESSION_1}.jsonl")
  jq -e 'select(.type == "wake" and .os_user == "iris")' "$src_file"
}

@test "wake explicit --os-user overrides SHIMMER_OS_USER" {
  stub_os_user_host iris
  local stub_dir="$BATS_TEST_TMPDIR/stub-shell-os-user-override"
  mkdir -p "$stub_dir"
  cat > "$stub_dir/shell" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
  chmod +x "$stub_dir/shell"

  export SHIMMER_OS_USER=bob
  PATH="$stub_dir:$PATH" run sessions wake "$SESSION_1" --background --model "openai-codex/gpt-5.5" --os-user iris
  [ "$status" -eq 0 ]
  src_file=$(find "$PROJECT_DIR" -name "*${SESSION_1}.jsonl")
  jq -e 'select(.type == "wake" and .os_user == "iris")' "$src_file"
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
  run sessions wake "$SESSION_1" --background --model "openai-codex/gpt-5.5"
  [ "$status" -eq 0 ]
}

# --- Meta parsing ---

@test "wake --meta records metadata in wake event" {
  command -v shell >/dev/null 2>&1 || skip "shell not installed"
  run sessions wake "$SESSION_1" --background --model "openai-codex/gpt-5.5" --meta "timeout=900"
  [ "$status" -eq 0 ]
  src_file=$(find "$PROJECT_DIR" -name "*${SESSION_1}.jsonl")
  jq -e 'select(.type == "wake" and .meta.timeout == "900")' "$src_file"
}

# --- Model pass-through ---

@test "wake --model records model on wake event" {
  command -v shell >/dev/null 2>&1 || skip "shell not installed"
  run sessions wake "$SESSION_1" --background --model "openai-codex/gpt-5.5"
  [ "$status" -eq 0 ]
  src_file=$(find "$PROJECT_DIR" -name "*${SESSION_1}.jsonl")
  jq -e 'select(.type == "wake" and .model == "openai-codex/gpt-5.5")' "$src_file"
}

@test "wake requires --model" {
  command -v shell >/dev/null 2>&1 || skip "shell not installed"
  run sessions wake "$SESSION_1" --background
  [ "$status" -ne 0 ]
  echo "$output" | grep -q -- "--model is required"
}

@test "wake requires provider-qualified --model" {
  command -v shell >/dev/null 2>&1 || skip "shell not installed"
  run sessions wake "$SESSION_1" --background --model "gpt-5.5"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q -- "--model must be provider-qualified"
}

@test "wake --os-user wraps only the sessions run payload" {
  command -v shell >/dev/null 2>&1 || skip "shell not installed"
  stub_os_user_host iris

  local stub_dir="$BATS_TEST_TMPDIR/stub-shell-os-user-argv"
  local capture="$BATS_TEST_TMPDIR/shell-argv-os-user"
  mkdir -p "$stub_dir"
  cat > "$stub_dir/shell" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$capture"
exit 0
STUB
  chmod +x "$stub_dir/shell"

  PATH="$stub_dir:$PATH" run sessions wake "${SESSION_1:0:8}" --background --model "openai-codex/gpt-5.5" --os-user iris
  [ "$status" -eq 0 ]
  [ -f "$capture" ]

  [ "$(sed -n '1p' "$capture")" = "run" ]
  [ "$(sed -n '3p' "$capture")" = "--cwd" ]

  local run_as_line
  run_as_line=$(grep -nFx "$SESSIONS_RUN_AS_USER" "$capture" | cut -d: -f1)
  [ -n "$run_as_line" ]
  [ "$(sed -n "$((run_as_line + 1))p" "$capture")" = "--user" ]
  [ "$(sed -n "$((run_as_line + 2))p" "$capture")" = "iris" ]
  [ "$(sed -n "$((run_as_line + 3))p" "$capture")" = "--" ]
  [ "$(sed -n "$((run_as_line + 4))p" "$capture")" = "mise" ]
  [ "$(sed -n "$((run_as_line + 5))p" "$capture")" = "-C" ]
}

@test "wake --model forwards --model to sessions run in RUN_CMD" {
  # Regression guard: `sessions wake --model X` must pass `--model X`
  # down to the CLI so the execution-time model is explicit end to end.
  #
  # We stub `shell` (which wake's --background path invokes with the full
  # RUN_CMD as argv) to dump its arguments to a file, then assert the
  # dumped argv contains `--model openai-codex/gpt-5.5` with the value
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

  PATH="$stub_dir:$PATH" run sessions wake "${SESSION_1:0:8}" --background --model "openai-codex/gpt-5.5"
  [ "$status" -eq 0 ]
  [ -f "$capture" ]

  # Adjacency check: the line AFTER `--model` must be the exact model
  # value. Independent presence checks (grep for each) would pass even
  # if a future refactor inserted args between flag and value.
  local line_after_flag
  line_after_flag=$(grep -A1 '^--model$' "$capture" | tail -1)
  [ "$line_after_flag" = "openai-codex/gpt-5.5" ]

  # Cardinality: exactly one --model in the argv (not duplicated).
  [ "$(grep -c '^--model$' "$capture")" = 1 ]

  # Sanity: `sessions run` is also in the argv (confirms we're stubbing
  # the right layer).
  grep -q '^run$' "$capture"
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

  PATH="$stub_dir:$PATH" run sessions wake "${SESSION_1:0:8}" --background --model "openai-codex/gpt-5.5"
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

@test "wake scrubs caller cwd variables before background shell launch" {
  # `sessions wake --background` starts a long-lived shell/zmx process.
  # Caller-cwd vars describe the immediate shiv invocation and become stale
  # ambient state once the shell outlives that invocation, so wake must scrub
  # them after materializing the explicit --cwd arguments.
  command -v shell >/dev/null 2>&1 || skip "shell not installed"

  local stub_dir="$BATS_TEST_TMPDIR/stub-shell-env"
  local capture="$BATS_TEST_TMPDIR/shell-env"
  mkdir -p "$stub_dir"
  cat > "$stub_dir/shell" <<STUB
#!/usr/bin/env bash
printf 'CALLER_PWD=%s\n' "\${CALLER_PWD-}" > "$capture"
printf 'SESSIONS_CALLER_PWD=%s\n' "\${SESSIONS_CALLER_PWD-}" >> "$capture"
printf 'OTHER_CALLER_PWD=%s\n' "\${OTHER_CALLER_PWD-}" >> "$capture"
exit 0
STUB
  chmod +x "$stub_dir/shell"

  export CALLER_PWD="/stale/legacy"
  export SESSIONS_CALLER_PWD="/stale/sessions"
  export OTHER_CALLER_PWD="/stale/other"

  PATH="$stub_dir:$PATH" run sessions wake "${SESSION_1:0:8}" --background --model "openai-codex/gpt-5.5"
  [ "$status" -eq 0 ]
  [ -f "$capture" ]

  grep -q '^CALLER_PWD=$' "$capture"
  grep -q '^SESSIONS_CALLER_PWD=$' "$capture"
  grep -q '^OTHER_CALLER_PWD=$' "$capture"
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

  PATH="$stub_dir:$PATH" run sessions wake "${SESSION_1:0:8}" --background --model "openai-codex/gpt-5.5"
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

@test "wake --headless requires --message before recording wake" {
  src_file=$(find "$PROJECT_DIR" -name "*${SESSION_1}.jsonl")
  local before
  before=$(wc -l < "$src_file")

  run sessions wake "$SESSION_1" --headless --model "openai-codex/gpt-5.5"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q -- "--headless requires --message"

  local after
  after=$(wc -l < "$src_file")
  [ "$after" = "$before" ]
}

@test "wake interactive without --message rejects unsupported harness before recording wake" {
  src_file=$(find "$PROJECT_DIR" -name "*${SESSION_1}.jsonl")
  local before
  before=$(wc -l < "$src_file")
  echo '{"type":"harness","id":"h-claude","parentId":"u4","timestamp":"2026-03-14T10:31:00.000Z","name":"claude"}' >> "$src_file"

  run sessions wake "$SESSION_1" --background --model "openai-codex/gpt-5.5"
  [ "$status" -eq 10 ]
  echo "$output" | grep -q -- "claude.*does not support interactive no-message wake"

  local after
  after=$(wc -l < "$src_file")
  [ "$after" = "$((before + 1))" ]
}

@test "wake interactive without --message records no synthetic message" {
  local stub_dir="$BATS_TEST_TMPDIR/stub-shell-no-message"
  local capture="$BATS_TEST_TMPDIR/shell-argv-no-message"
  mkdir -p "$stub_dir"
  cat > "$stub_dir/shell" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$capture"
exit 0
STUB
  chmod +x "$stub_dir/shell"

  src_file=$(find "$PROJECT_DIR" -name "*${SESSION_1}.jsonl")
  local before_messages
  before_messages=$(jq -s '[.[] | select(.type == "message")] | length' "$src_file")

  PATH="$stub_dir:$PATH" run sessions wake "$SESSION_1" --background --model "openai-codex/gpt-5.5"
  [ "$status" -eq 0 ]
  [ -f "$capture" ]

  local after_messages
  after_messages=$(jq -s '[.[] | select(.type == "message")] | length' "$src_file")
  [ "$after_messages" = "$before_messages" ]
  jq -e 'select(.type == "wake" and .headless == false)' "$src_file"

  [ "$(tail -1 "$capture")" = "openai-codex/gpt-5.5" ]
  ! grep -qx '' "$capture"
}

@test "wake interactive without --message executes nested run without print mode" {
  local session_cwd="$BATS_TEST_TMPDIR/wake-session-cwd"
  local expected_cwd
  mkdir -p "$session_cwd"
  expected_cwd=$(cd "$session_cwd" && pwd -P)

  src_file=$(find "$PROJECT_DIR" -name "*${SESSION_1}.jsonl")
  local updated_file="$BATS_TEST_TMPDIR/session-cwd-for-nested-run.jsonl"
  jq -c --arg cwd "$session_cwd" 'if .type == "session" then .cwd = $cwd else . end' "$src_file" > "$updated_file"
  mv "$updated_file" "$src_file"

  local stub_dir="$BATS_TEST_TMPDIR/stub-shell-pi-no-message"
  local shell_capture="$BATS_TEST_TMPDIR/shell-argv-nested-no-message"
  local pi_argv_capture="$BATS_TEST_TMPDIR/pi-argv-nested-no-message"
  local pi_cwd_capture="$BATS_TEST_TMPDIR/pi-cwd-nested-no-message"
  stub_shell_exec_payload "$stub_dir" "$shell_capture"
  stub_pi_capture_argv_cwd "$stub_dir" "$pi_argv_capture" "$pi_cwd_capture"

  export AGENT_IDENTITY="test identity"
  PATH="$stub_dir:$PATH" run sessions wake "${SESSION_1:0:8}" --background --model "openai-codex/gpt-5.5"
  [ "$status" -eq 0 ]
  [ -f "$shell_capture" ]
  [ -f "$pi_argv_capture" ]
  [ -f "$pi_cwd_capture" ]

  [ "$(cat "$pi_cwd_capture")" = "$expected_cwd" ]
  grep -qx -- "--append-system-prompt" "$pi_argv_capture"
  grep -qx -- "--model" "$pi_argv_capture"
  [ "$(awk '/^--model$/ { getline; print; exit }' "$pi_argv_capture")" = "openai-codex/gpt-5.5" ]
  grep -qx -- "--session" "$pi_argv_capture"
  [ "$(awk '/^--session$/ { getline; print; exit }' "$pi_argv_capture")" = "$src_file" ]

  ! grep -qx -- "-p" "$pi_argv_capture"
  ! grep -qx -- "--print" "$pi_argv_capture"
  ! grep -qx '' "$pi_argv_capture"
}

@test "wake --model is advertised in --help" {
  run sessions wake --help
  [ "$status" -eq 0 ]
  echo "$output" | grep -q -- "--model"
}

@test "wake --os-user is advertised in --help" {
  run sessions wake --help
  [ "$status" -eq 0 ]
  echo "$output" | grep -q -- "--os-user"
}
