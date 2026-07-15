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

@test "run interactive resolves pi through sessions mise root by default" {
  local stub_dir="$BATS_TEST_TMPDIR/stub-mise-pi"
  local argv_capture="$BATS_TEST_TMPDIR/pi-argv-owned"
  local cwd_capture="$BATS_TEST_TMPDIR/pi-cwd-owned"
  local mise_capture="$BATS_TEST_TMPDIR/mise-argv-owned"
  local real_mise
  real_mise=$(command -v mise)

  stub_pi_capture_argv_cwd "$stub_dir" "$argv_capture" "$cwd_capture"
  cat > "$stub_dir/mise" <<STUB
#!/usr/bin/env bash
set -euo pipefail
if [ "\${1:-}" = "-C" ] && [ "\${3:-}" = "exec" ] && [ "\${4:-}" = "--" ] && [ "\${5:-}" = "pi" ]; then
  printf '%s\n' "\$@" > "$mise_capture"
  shift 5
  exec pi "\$@"
fi
exec "$real_mise" "\$@"
STUB
  chmod +x "$stub_dir/mise"

  local run_cwd="$BATS_TEST_TMPDIR/run-cwd-owned"
  mkdir -p "$run_cwd"

  PATH="$stub_dir:$PATH" run "$real_mise" -C "$REPO_DIR" run -q run \
    --cwd "$run_cwd" \
    --model "openai-codex/gpt-5.5"
  [ "$status" -eq 0 ]
  [ -f "$mise_capture" ]
  [ -f "$argv_capture" ]

  [ "$(awk 'NR == 1 { print }' "$mise_capture")" = "-C" ]
  [ "$(awk 'NR == 2 { print }' "$mise_capture")" = "$REPO_DIR" ]
  [ "$(awk 'NR == 3 { print }' "$mise_capture")" = "exec" ]
  [ "$(awk 'NR == 4 { print }' "$mise_capture")" = "--" ]
  [ "$(awk 'NR == 5 { print }' "$mise_capture")" = "pi" ]
  grep -qx -- "--model" "$argv_capture"
}

@test "run --interactive with message execs pi without print mode" {
  local stub_dir="$BATS_TEST_TMPDIR/stub-pi-interactive-message"
  local argv_capture="$BATS_TEST_TMPDIR/pi-argv-interactive-message"
  local cwd_capture="$BATS_TEST_TMPDIR/pi-cwd-interactive-message"
  stub_pi_capture_argv_cwd "$stub_dir" "$argv_capture" "$cwd_capture"

  local run_cwd="$BATS_TEST_TMPDIR/run-cwd-interactive-message"
  mkdir -p "$run_cwd"
  local expected_cwd
  expected_cwd=$(cd "$run_cwd" && pwd -P)

  local session_file
  session_file=$(find "$PROJECT_DIR" -name "*${SESSION_1}.jsonl")

  PATH="$stub_dir:$PATH" run sessions run \
    --interactive \
    --cwd "$run_cwd" \
    --model "openai-codex/gpt-5.5" \
    --session "$session_file" \
    "stay attached"
  [ "$status" -eq 0 ]
  [ -f "$argv_capture" ]
  [ -f "$cwd_capture" ]

  [ "$(cat "$cwd_capture")" = "$expected_cwd" ]
  grep -qx -- "--model" "$argv_capture"
  [ "$(awk '/^--model$/ { getline; print; exit }' "$argv_capture")" = "openai-codex/gpt-5.5" ]
  grep -qx -- "--session" "$argv_capture"
  [ "$(awk '/^--session$/ { getline; print; exit }' "$argv_capture")" = "$session_file" ]
  [ "$(tail -1 "$argv_capture")" = "stay attached" ]

  ! grep -qx -- "-p" "$argv_capture"
  ! grep -qx -- "--print" "$argv_capture"
  ! grep -qx -- "--mode" "$argv_capture"
}

@test "run interactive without message works without any system prompt" {
  local stub_dir="$BATS_TEST_TMPDIR/stub-pi-no-prompt"
  local argv_capture="$BATS_TEST_TMPDIR/pi-argv-no-prompt"
  local cwd_capture="$BATS_TEST_TMPDIR/pi-cwd-no-prompt"
  stub_pi_capture_argv_cwd "$stub_dir" "$argv_capture" "$cwd_capture"

  local run_cwd="$BATS_TEST_TMPDIR/run-cwd-no-prompt"
  mkdir -p "$run_cwd"
  local expected_cwd
  expected_cwd=$(cd "$run_cwd" && pwd -P)

  PATH="$stub_dir:$PATH" run sessions run \
    --cwd "$run_cwd" \
    --model "openai-codex/gpt-5.5"
  [ "$status" -eq 0 ]
  [ -f "$argv_capture" ]
  [ -f "$cwd_capture" ]

  [ "$(cat "$cwd_capture")" = "$expected_cwd" ]
  ! grep -qx -- "--append-system-prompt" "$argv_capture"
  grep -qx -- "--model" "$argv_capture"
  [ "$(awk '/^--model$/ { getline; print; exit }' "$argv_capture")" = "openai-codex/gpt-5.5" ]
  grep -qx -- "--no-session" "$argv_capture"
  ! grep -qx -- "-p" "$argv_capture"
  ! grep -qx -- "--print" "$argv_capture"
  ! grep -qx '' "$argv_capture"
}

@test "run with message works without any system prompt" {
  local stub_dir="$BATS_TEST_TMPDIR/stub-mix-no-prompt"
  local argv_capture="$BATS_TEST_TMPDIR/mix-argv-no-prompt"
  mkdir -p "$stub_dir"
  cat > "$stub_dir/mix" <<STUB
#!/usr/bin/env bash
set -euo pipefail
case "\$*" in
  "local.hex --force --if-missing"|"deps.loadpaths --no-compile"|"deps.get") exit 0 ;;
esac
printf '%s\n' "\$@" > "$argv_capture"
exit 0
STUB
  chmod +x "$stub_dir/mix"

  PATH="$stub_dir:$PATH" run sessions run \
    --cwd "$BATS_TEST_TMPDIR" \
    --model "openai-codex/gpt-5.5" \
    "do work"
  [ "$status" -eq 0 ]
  [ -f "$argv_capture" ]

  ! grep -qx -- "--system-prompt-file" "$argv_capture"
  grep -qx -- "--model" "$argv_capture"
  [ "$(awk '/^--model$/ { getline; print; exit }' "$argv_capture")" = "openai-codex/gpt-5.5" ]
  grep -qx -- "--project-trust" "$argv_capture"
  [ "$(awk '/^--project-trust$/ { getline; print; exit }' "$argv_capture")" = "inherit" ]
  ! grep -qx -- "--no-extensions" "$argv_capture"
  ! grep -qx -- "--no-skills" "$argv_capture"
  ! grep -qx -- "--no-prompt-templates" "$argv_capture"
}

@test "run forwards explicit resource disables and project approval" {
  local stub_dir="$BATS_TEST_TMPDIR/stub-mix-resource-policy"
  local argv_capture="$BATS_TEST_TMPDIR/mix-argv-resource-policy"
  mkdir -p "$stub_dir"
  cat > "$stub_dir/mix" <<STUB
#!/usr/bin/env bash
set -euo pipefail
case "\$*" in
  "local.hex --force --if-missing"|"deps.loadpaths --no-compile"|"deps.get") exit 0 ;;
esac
printf '%s\n' "\$@" > "$argv_capture"
exit 0
STUB
  chmod +x "$stub_dir/mix"

  PATH="$stub_dir:$PATH" run sessions run \
    --cwd "$BATS_TEST_TMPDIR" \
    --model "openai-codex/gpt-5.5" \
    --project-trust approve \
    --no-extensions \
    --no-skills \
    --no-prompt-templates \
    "do work"
  [ "$status" -eq 0 ]
  [ -f "$argv_capture" ]

  [ "$(awk '/^--project-trust$/ { getline; print; exit }' "$argv_capture")" = "approve" ]
  grep -qx -- "--no-extensions" "$argv_capture"
  grep -qx -- "--no-skills" "$argv_capture"
  grep -qx -- "--no-prompt-templates" "$argv_capture"
}

@test "run rejects conflicting resource flags" {
  run sessions run \
    --model "openai-codex/gpt-5.5" \
    --extensions \
    --no-extensions \
    "do work"

  [ "$status" -eq 1 ]
  echo "$output" | grep -q -- "--extensions cannot be combined with --no-extensions"
}

@test "run rejects an invalid project trust policy" {
  run sessions run \
    --model "openai-codex/gpt-5.5" \
    --project-trust sometimes \
    "do work"

  [ "$status" -eq 1 ]
  echo "$output" | grep -q -- "--project-trust must be inherit, approve, or deny"
}

@test "run interactive maps project trust and explicit resource disables to pi" {
  local stub_dir="$BATS_TEST_TMPDIR/stub-pi-interactive-policy"
  local argv_capture="$BATS_TEST_TMPDIR/pi-argv-interactive-policy"
  local cwd_capture="$BATS_TEST_TMPDIR/pi-cwd-interactive-policy"
  stub_pi_capture_argv_cwd "$stub_dir" "$argv_capture" "$cwd_capture"

  PATH="$stub_dir:$PATH" run sessions run \
    --cwd "$BATS_TEST_TMPDIR" \
    --model "openai-codex/gpt-5.5" \
    --project-trust deny \
    --no-extensions \
    --no-skills \
    --no-prompt-templates
  [ "$status" -eq 0 ]

  grep -qx -- "--no-approve" "$argv_capture"
  grep -qx -- "--no-extensions" "$argv_capture"
  grep -qx -- "--no-skills" "$argv_capture"
  grep -qx -- "--no-prompt-templates" "$argv_capture"
}

@test "run with message prepares CLI deps before mix sessions" {
  local stub_dir="$BATS_TEST_TMPDIR/stub-mix-readiness-order"
  local command_log="$BATS_TEST_TMPDIR/mix-readiness-order.log"
  mkdir -p "$stub_dir"
  cat > "$stub_dir/mix" <<STUB
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "\$*" >> "$command_log"
case "\$*" in
  "local.hex --force --if-missing"|"deps.loadpaths --no-compile") exit 0 ;;
  sessions*) exit 0 ;;
esac
exit 43
STUB
  chmod +x "$stub_dir/mix"

  PATH="$stub_dir:$PATH" run sessions run \
    --cwd "$BATS_TEST_TMPDIR" \
    --model "openai-codex/gpt-5.5" \
    "do work"

  [ "$status" -eq 0 ]
  [ "$(sed -n '1p' "$command_log")" = "local.hex --force --if-missing" ]
  [ "$(sed -n '2p' "$command_log")" = "deps.loadpaths --no-compile" ]
  [[ "$(sed -n '3p' "$command_log")" == sessions\ --cwd\ * ]]
  ! grep -q '^deps.get$' "$command_log"
}

@test "run rejects a missing explicit system prompt file before launch" {
  local stub_dir="$BATS_TEST_TMPDIR/stub-pi-missing-prompt"
  local invoked_capture="$BATS_TEST_TMPDIR/pi-missing-prompt-invoked"
  mkdir -p "$stub_dir"
  cat > "$stub_dir/pi" <<STUB
#!/usr/bin/env bash
printf invoked > "$invoked_capture"
exit 0
STUB
  chmod +x "$stub_dir/pi"

  PATH="$stub_dir:$PATH" run sessions run \
    --system-prompt-file "$BATS_TEST_TMPDIR/missing-prompt.md" \
    --cwd "$BATS_TEST_TMPDIR" \
    --model "openai-codex/gpt-5.5"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "System prompt file not found"
  [ ! -e "$invoked_capture" ]
}

@test "run interactive without message preserves stdin for pi" {
  local stub_dir="$BATS_TEST_TMPDIR/stub-pi-stdin"
  local stdin_capture="$BATS_TEST_TMPDIR/pi-stdin-capture"
  local prompt="$BATS_TEST_TMPDIR/prompt.md"
  mkdir -p "$stub_dir"
  echo "test prompt" > "$prompt"
  cat > "$stub_dir/pi" <<STUB
#!/usr/bin/env bash
set -euo pipefail
if read -r line; then
  printf '%s' "\$line" > "$stdin_capture"
else
  printf 'stdin closed' > "$stdin_capture"
  exit 1
fi
STUB
  chmod +x "$stub_dir/pi"
  stub_mise_exec_pi "$stub_dir"

  run bash -c 'printf "%s\n" "typed input" | PATH="$1" PI_DIR="$2" mise -C "$3" run -q run --system-prompt-file "$4" --cwd "$5" --model "openai-codex/gpt-5.5"' \
    bash \
    "$stub_dir:$PATH" \
    "$PI_DIR" \
    "$REPO_DIR" \
    "$prompt" \
    "$BATS_TEST_TMPDIR"
  [ "$status" -eq 0 ]
  [ "$(cat "$stdin_capture")" = "typed input" ]
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
  stub_mise_exec_pi "$stub_dir"

  run sessions new --cwd "$BATS_TEST_TMPDIR" --system-prompt "baked prompt from session"
  [ "$status" -eq 0 ]
  new_id=$(echo "$output" | head -1)
  session_file=$(find "$PI_DIR/agent/sessions" -name "*${new_id}.jsonl")

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
case "\$*" in
  "local.hex --force --if-missing"|"deps.loadpaths --no-compile"|"deps.get") exit 0 ;;
esac
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

@test "run headless with message creates runtime context prompt without profile prompt" {
  local stub_dir="$BATS_TEST_TMPDIR/stub-mix-headless-no-profile"
  local argv_capture="$BATS_TEST_TMPDIR/mix-argv-headless-no-profile"
  local prompt_capture="$BATS_TEST_TMPDIR/mix-prompt-headless-no-profile"
  mkdir -p "$stub_dir"
  cat > "$stub_dir/mix" <<STUB
#!/usr/bin/env bash
set -euo pipefail
case "\$*" in
  "local.hex --force --if-missing"|"deps.loadpaths --no-compile"|"deps.get") exit 0 ;;
esac
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

  PATH="$stub_dir:$PATH" run sessions run \
    --headless \
    --cwd "$BATS_TEST_TMPDIR" \
    --model "openai-codex/gpt-5.5" \
    "do work"
  [ "$status" -eq 0 ]
  [ -f "$argv_capture" ]
  [ -f "$prompt_capture" ]

  grep -qx -- "--system-prompt-file" "$argv_capture"
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
  stub_mise_exec_pi "$stub_dir"

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

@test "run interactive without message treats an empty baked prompt as present" {
  local stub_dir="$BATS_TEST_TMPDIR/stub-pi-empty-baked-prompt"
  local prompt_capture="$BATS_TEST_TMPDIR/pi-prompt-empty-baked-prompt"
  local prompt_path_capture="$BATS_TEST_TMPDIR/pi-prompt-path-empty-baked-prompt"
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
printf '%s\n' "\$prompt_file" > "$prompt_path_capture"
cat "\$prompt_file" > "$prompt_capture"
exit 0
STUB
  chmod +x "$stub_dir/pi"
  stub_mise_exec_pi "$stub_dir"

  : > "$BATS_TEST_TMPDIR/empty-prompt.md"
  run sessions new --cwd "$BATS_TEST_TMPDIR" --system-prompt-file "$BATS_TEST_TMPDIR/empty-prompt.md"
  [ "$status" -eq 0 ]
  new_id=$(echo "$output" | head -1)
  session_file=$(find "$PI_DIR/agent/sessions" -name "*${new_id}.jsonl")

  PATH="$stub_dir:$PATH" run sessions run \
    --cwd "$BATS_TEST_TMPDIR" \
    --model "openai-codex/gpt-5.5" \
    --session "$session_file"
  [ "$status" -eq 0 ]
  [ -f "$prompt_capture" ]
  [ -f "$prompt_path_capture" ]
  [ ! -e "$(cat "$prompt_path_capture")" ]
}

@test "run with malformed session fails before launch" {
  local stub_dir="$BATS_TEST_TMPDIR/stub-pi-malformed-session"
  local invoked_capture="$BATS_TEST_TMPDIR/pi-malformed-session-invoked"
  local bad_session="$BATS_TEST_TMPDIR/malformed-session.jsonl"
  mkdir -p "$stub_dir"
  cat > "$stub_dir/pi" <<STUB
#!/usr/bin/env bash
printf invoked > "$invoked_capture"
exit 0
STUB
  chmod +x "$stub_dir/pi"
  printf '{"type":"session"\n' > "$bad_session"

  PATH="$stub_dir:$PATH" run sessions run \
    --cwd "$BATS_TEST_TMPDIR" \
    --model "openai-codex/gpt-5.5" \
    --session "$bad_session"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "failed to read session system prompt"
  echo "$output" | grep -q "parse error"
  [ ! -e "$invoked_capture" ]
}

@test "run forwards SIGTERM to child before cleaning generated prompt" {
  local stub_dir="$BATS_TEST_TMPDIR/stub-pi-sigterm"
  local pid_capture="$BATS_TEST_TMPDIR/pi-sigterm-pid"
  local term_capture="$BATS_TEST_TMPDIR/pi-sigterm-seen"
  local prompt_path_capture="$BATS_TEST_TMPDIR/pi-sigterm-prompt-path"
  local stdout_capture="$BATS_TEST_TMPDIR/run-sigterm-stdout"
  local stderr_capture="$BATS_TEST_TMPDIR/run-sigterm-stderr"
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
printf '%s\n' "\$prompt_file" > "$prompt_path_capture"
printf '%s\n' "\$\$" > "$pid_capture"
trap 'printf term > "$term_capture"; exit 143' TERM
while :; do sleep 1; done
STUB
  chmod +x "$stub_dir/pi"
  stub_mise_exec_pi "$stub_dir"

  PATH="$stub_dir:$PATH" DISPATCH_CONTEXT="generated prompt" PI_DIR="$PI_DIR" \
    mise -C "$REPO_DIR" run -q run --cwd "$BATS_TEST_TMPDIR" --model "openai-codex/gpt-5.5" \
    >"$stdout_capture" 2>"$stderr_capture" &
  local mise_pid=$!

  for _ in $(seq 1 50); do
    [ -s "$pid_capture" ] && [ -s "$prompt_path_capture" ] && break
    sleep 0.1
  done
  [ -s "$pid_capture" ]
  [ -s "$prompt_path_capture" ]

  local child_pid
  child_pid=$(cat "$pid_capture")
  local runner_pid
  runner_pid=$(ps -o ppid= -p "$child_pid" | tr -d ' ')
  [ -n "$runner_pid" ]
  local prompt_path
  prompt_path=$(cat "$prompt_path_capture")
  [ -e "$prompt_path" ]

  kill -TERM "$runner_pid"
  set +e
  wait "$mise_pid"
  local rc=$?
  set -e

  [ "$rc" -eq 143 ]
  [ -f "$term_capture" ]
  if kill -0 "$child_pid" 2>/dev/null; then
    kill "$child_pid" 2>/dev/null || true
    return 1
  fi
  [ ! -e "$prompt_path" ]
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

@test "run rejects --headless with --interactive" {
  run sessions run --headless --interactive --model "openai-codex/gpt-5.5" "do work"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q -- "--headless cannot be combined with --interactive"
}

@test "run --headless requires a message" {
  local prompt="$BATS_TEST_TMPDIR/prompt.md"
  echo "test prompt" > "$prompt"

  run sessions run --headless --system-prompt-file "$prompt" --model "openai-codex/gpt-5.5"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q -- "--headless requires a message"
}
