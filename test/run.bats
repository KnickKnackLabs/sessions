#!/usr/bin/env bats

load helpers

setup() {
  setup_test_sessions
}

teardown() {
  teardown_test_sessions
}

@test "run interactive without message execs pi without print mode" {
  local stub_dir="$BATS_TEST_TMPDIR/stub-pi"
  local argv_capture="$BATS_TEST_TMPDIR/pi-argv"
  local cwd_capture="$BATS_TEST_TMPDIR/pi-cwd"
  stub_pi_capture_argv_cwd "$stub_dir" "$argv_capture" "$cwd_capture"

  local prompt="$BATS_TEST_TMPDIR/prompt.md"
  echo "test prompt" > "$prompt"

  local run_cwd="$BATS_TEST_TMPDIR/run-cwd"
  mkdir -p "$run_cwd"
  local expected_cwd
  expected_cwd=$(cd "$run_cwd" && pwd -P)

  local session_file
  session_file=$(find "$PROJECT_DIR" -name "*${SESSION_1}.jsonl")

  export usage_message="stale inherited message"
  export usage_headless=true

  PATH="$stub_dir:$PATH" run sessions run \
    --system-prompt-file "$prompt" \
    --cwd "$run_cwd" \
    --model "openai-codex/gpt-5.5" \
    --session "$session_file"
  [ "$status" -eq 0 ]
  [ -f "$argv_capture" ]
  [ -f "$cwd_capture" ]

  [ "$(cat "$cwd_capture")" = "$expected_cwd" ]
  grep -qx -- "--append-system-prompt" "$argv_capture"
  grep -qx -- "$prompt" "$argv_capture"
  grep -qx -- "--model" "$argv_capture"
  [ "$(awk '/^--model$/ { getline; print; exit }' "$argv_capture")" = "openai-codex/gpt-5.5" ]
  grep -qx -- "--session" "$argv_capture"
  [ "$(awk '/^--session$/ { getline; print; exit }' "$argv_capture")" = "$session_file" ]

  ! grep -qx -- "-p" "$argv_capture"
  ! grep -qx -- "--print" "$argv_capture"
  ! grep -qx -- "--no-extensions" "$argv_capture"
  ! grep -qx -- "--no-skills" "$argv_capture"
  ! grep -qx -- "--no-prompt-templates" "$argv_capture"
  ! grep -qx '' "$argv_capture"
}

@test "run interactive without message scrubs stale harness environment" {
  local mise_data="${MISE_DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/mise}"
  local stale_bin="$mise_data/installs/sessions-test-stale/bin"
  local fresh_bin="$mise_data/installs/sessions-test-fresh/bin"
  local shim_bin="$mise_data/shims"
  local pi_bin="$BATS_TEST_TMPDIR/pi-bin"
  local env_capture="$BATS_TEST_TMPDIR/pi-env"
  stub_pi_capture_env "$pi_bin" "$env_capture"

  local prompt="$BATS_TEST_TMPDIR/prompt.md"
  echo "test prompt" > "$prompt"

  export CALLER_PWD="/stale/caller"
  export SESSIONS_CALLER_PWD="/stale/sessions"
  export OTHER_CALLER_PWD="/stale/other"

  PATH="$stale_bin:$pi_bin:$shim_bin:$fresh_bin:$PATH" run sessions run \
    --system-prompt-file "$prompt" \
    --cwd "$BATS_TEST_TMPDIR" \
    --model "openai-codex/gpt-5.5"
  [ "$status" -eq 0 ]
  [ -f "$env_capture" ]

  grep -q '^CALLER_PWD=$' "$env_capture"
  grep -q '^SESSIONS_CALLER_PWD=$' "$env_capture"
  grep -q '^OTHER_CALLER_PWD=$' "$env_capture"
  grep -q "$shim_bin" "$env_capture"
  grep -q "$pi_bin" "$env_capture"
  ! grep -q "$stale_bin" "$env_capture"
  ! grep -q "$fresh_bin" "$env_capture"
}

@test "run --headless requires a message" {
  local prompt="$BATS_TEST_TMPDIR/prompt.md"
  echo "test prompt" > "$prompt"

  run sessions run --headless --system-prompt-file "$prompt" --model "openai-codex/gpt-5.5"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q -- "--headless requires a message"
}
