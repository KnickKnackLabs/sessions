#!/usr/bin/env bats

load helpers

setup() {
  setup_test_sessions
  # Intentional guard probes must not poison the real suite's failure log.
  export SESSIONS_TEST_GUARD_LOG="$BATS_TEST_TMPDIR/guard.log"
}

teardown() {
  teardown_test_sessions
}

prepend_decoys() {
  local dir="$BATS_TEST_TMPDIR/path-decoys"
  mkdir -p "$dir"
  local tool
  for tool in pi mix shell; do
    ln -s "$REPO_DIR/test/fixtures/blocked-command" "$dir/$tool"
  done
  export PATH="$dir:$PATH"
}

@test "isolation: explicit Shell and Pi mocks survive nested Mise activation" {
  local stub_dir="$BATS_TEST_TMPDIR/explicit mocks"
  local argv="$BATS_TEST_TMPDIR/pi-argv"
  local cwd="$BATS_TEST_TMPDIR/pi-cwd"
  stub_shell_exec_payload "$stub_dir" "$BATS_TEST_TMPDIR/shell-argv"
  stub_pi_capture_argv_cwd "$stub_dir" "$argv" "$cwd"
  prepend_decoys

  run sessions new --cwd "$BATS_TEST_TMPDIR" isolated-wake
  [ "$status" -eq 0 ]
  run sessions wake isolated-wake --background --model test/model --message "fixture only"
  [ "$status" -eq 0 ]
  [ "$(tail -1 "$argv")" = "fixture only" ]
  [ "$(cat "$cwd")" = "$(cd "$BATS_TEST_TMPDIR" && pwd -P)" ]
  [ ! -e "$SESSIONS_TEST_GUARD_LOG" ]
}

@test "isolation: explicit Mix mock survives task activation through execution" {
  local stub_dir="$BATS_TEST_TMPDIR/explicit mocks"
  mkdir -p "$stub_dir"
  export SESSIONS_MIX="$stub_dir/mix"
  local log="$BATS_TEST_TMPDIR/mix.log"
  cat > "$SESSIONS_MIX" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$log"
STUB
  chmod +x "$SESSIONS_MIX"
  prepend_decoys

  run sessions run --cwd "$BATS_TEST_TMPDIR" --model test/model "fixture only"
  [ "$status" -eq 0 ]
  [ "$(sed -n '1p' "$log")" = "local.hex --force --if-missing" ]
  [ "$(sed -n '2p' "$log")" = "deps.loadpaths --no-compile" ]
  [[ "$(sed -n '3p' "$log")" == sessions\ --cwd\ * ]]
  [ ! -e "$SESSIONS_TEST_GUARD_LOG" ]
}

@test "isolation: an unmocked Pi launch is blocked and logged" {
  run sessions run --cwd "$BATS_TEST_TMPDIR" --model test/model
  [ "$status" -eq 97 ]
  [[ "$output" == *"test isolation: unmocked pi:"* ]]
  grep -q 'unmocked pi:' "$SESSIONS_TEST_GUARD_LOG"
}

@test "isolation: unmocked Mix setup is blocked and logged" {
  run sessions cli:build
  [ "$status" -ne 0 ]
  grep -q 'unmocked mix: local.hex' "$SESSIONS_TEST_GUARD_LOG"
}

@test "isolation: an unmocked Shell launch is blocked and logged" {
  run sessions wake "$SESSION_1" --background --model test/model
  [ "$status" -eq 97 ]
  grep -q 'unmocked shell: run' "$SESSIONS_TEST_GUARD_LOG"
}

@test "isolation: swallowed Shell status failure still fails suite teardown" {
  run sessions remove --force "$SESSION_1"
  [ "$status" -eq 0 ]
  grep -q 'unmocked shell: status' "$SESSIONS_TEST_GUARD_LOG"

  source "$REPO_DIR/test/setup_suite.bash"
  run teardown_suite
  [ "$status" -eq 1 ]
  [[ "$output" == *"unmocked shell: status"* ]]
}

@test "isolation: invalid executable overrides never fall back to PATH" {
  local invalid="$BATS_TEST_TMPDIR/not-executable"
  printf 'exit 0\n' > "$invalid"
  prepend_decoys

  SESSIONS_TEST_PI_EXECUTABLE="$invalid" run sessions run --cwd "$BATS_TEST_TMPDIR" --model test/model
  [ "$status" -ne 0 ]
  SESSIONS_MIX="$invalid" run sessions cli:build
  [ "$status" -ne 0 ]
  SESSIONS_SHELL="$BATS_TEST_TMPDIR/missing-shell" run sessions wake "$SESSION_1" --background --model test/model
  [ "$status" -ne 0 ]
  [ ! -e "$SESSIONS_TEST_GUARD_LOG" ]
}
