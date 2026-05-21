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

@test "run interactive without message uses baked session system prompt" {
  local stub_dir="$BATS_TEST_TMPDIR/stub-pi-baked-prompt"
  local argv_capture="$BATS_TEST_TMPDIR/pi-argv-baked-prompt"
  local prompt_capture="$BATS_TEST_TMPDIR/pi-prompt-baked-prompt"
  mkdir -p "$stub_dir"
  cat > "$stub_dir/pi" <<STUB
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "\$@" > "$argv_capture"
prompt_file=""
while [ "\$#" -gt 0 ]; do
  if [ "\$1" = "--append-system-prompt" ]; then
    prompt_file="\$2"
    break
  fi
  shift
done
[ -n "\$prompt_file" ]
cat "\$prompt_file" > "$prompt_capture"
exit 0
STUB
  chmod +x "$stub_dir/pi"

  run sessions new --cwd "$BATS_TEST_TMPDIR" --system-prompt "baked prompt from session"
  [ "$status" -eq 0 ]
  new_id=$(echo "$output" | head -1)
  session_file=$(find "$PI_DIR/agent/sessions" -name "*${new_id}.jsonl")

  unset AGENT_IDENTITY
  PATH="$stub_dir:$PATH" run sessions run \
    --cwd "$BATS_TEST_TMPDIR" \
    --model "openai-codex/gpt-5.5" \
    --session "$session_file"
  [ "$status" -eq 0 ]
  [ -f "$argv_capture" ]
  [ -f "$prompt_capture" ]

  grep -qx -- "--append-system-prompt" "$argv_capture"
  grep -q "baked prompt from session" "$prompt_capture"
  prompt_path=$(awk '/^--append-system-prompt$/ { getline; print; exit }' "$argv_capture")
  [ -n "$prompt_path" ]
  [ ! -e "$prompt_path" ]
}

@test "run headless with message uses baked session system prompt" {
  local stub_dir="$BATS_TEST_TMPDIR/stub-mix-baked-prompt"
  local argv_capture="$BATS_TEST_TMPDIR/mix-argv-baked-prompt"
  local prompt_capture="$BATS_TEST_TMPDIR/mix-prompt-baked-prompt"
  mkdir -p "$stub_dir"
  cat > "$stub_dir/mix" <<STUB
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "\$@" > "$argv_capture"
prompt_file=""
while [ "\$#" -gt 0 ]; do
  if [ "\$1" = "--system-prompt-file" ]; then
    prompt_file="\$2"
    break
  fi
  shift
done
[ -n "\$prompt_file" ]
cat "\$prompt_file" > "$prompt_capture"
exit 0
STUB
  chmod +x "$stub_dir/mix"

  run sessions new --cwd "$BATS_TEST_TMPDIR" --system-prompt "headless baked prompt"
  [ "$status" -eq 0 ]
  new_id=$(echo "$output" | head -1)
  session_file=$(find "$PI_DIR/agent/sessions" -name "*${new_id}.jsonl")

  unset AGENT_IDENTITY
  PATH="$stub_dir:$PATH" run sessions run \
    --headless \
    --cwd "$BATS_TEST_TMPDIR" \
    --model "openai-codex/gpt-5.5" \
    --session "$session_file" \
    "do work"
  [ "$status" -eq 0 ]
  [ -f "$argv_capture" ]
  [ -f "$prompt_capture" ]

  grep -q "headless baked prompt" "$prompt_capture"
  grep -q "This is a headless session" "$prompt_capture"
  prompt_path=$(awk '/^--system-prompt-file$/ { getline; print; exit }' "$argv_capture")
  [ -n "$prompt_path" ]
  [ ! -e "$prompt_path" ]
}

@test "run interactive without message prefers explicit prompt file over baked prompt" {
  local stub_dir="$BATS_TEST_TMPDIR/stub-pi-explicit-prompt"
  local prompt_capture="$BATS_TEST_TMPDIR/pi-prompt-explicit-prompt"
  mkdir -p "$stub_dir"
  cat > "$stub_dir/pi" <<STUB
#!/usr/bin/env bash
set -euo pipefail
prompt_file=""
while [ "\$#" -gt 0 ]; do
  if [ "\$1" = "--append-system-prompt" ]; then
    prompt_file="\$2"
    break
  fi
  shift
done
[ -n "\$prompt_file" ]
cat "\$prompt_file" > "$prompt_capture"
exit 0
STUB
  chmod +x "$stub_dir/pi"

  run sessions new --cwd "$BATS_TEST_TMPDIR" --system-prompt "baked prompt"
  [ "$status" -eq 0 ]
  new_id=$(echo "$output" | head -1)
  session_file=$(find "$PI_DIR/agent/sessions" -name "*${new_id}.jsonl")
  echo "explicit prompt" > "$BATS_TEST_TMPDIR/explicit.md"

  PATH="$stub_dir:$PATH" run sessions run \
    --system-prompt-file "$BATS_TEST_TMPDIR/explicit.md" \
    --cwd "$BATS_TEST_TMPDIR" \
    --model "openai-codex/gpt-5.5" \
    --session "$session_file"
  [ "$status" -eq 0 ]
  grep -q "explicit prompt" "$prompt_capture"
  ! grep -q "baked prompt" "$prompt_capture"
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
