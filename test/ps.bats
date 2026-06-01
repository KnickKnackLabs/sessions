#!/usr/bin/env bats

load helpers

setup() {
  setup_test_sessions
  sessions ps --json >/dev/null 2>&1
}
teardown() { teardown_test_sessions; }

process_start_token_for_pid() {
  local pid="$1"
  local token=""
  if [ -r "/proc/$pid/stat" ]; then
    token=$(awk '{print $22}' "/proc/$pid/stat")
    if [ -n "$token" ]; then
      printf 'linux:%s\n' "$token"
      return 0
    fi
  fi
  token=$(ps -p "$pid" -o lstart= 2>/dev/null | awk '{$1=$1; print}')
  if [ -n "$token" ]; then
    printf 'ps:%s\n' "$token"
  fi
}

session_file_for() {
  local session_id="$1"
  find "$PROJECT_DIR" -name "*${session_id}.jsonl" | head -1
}

@test "ps --json shows live process with matching pid start time" {
  local session_file token
  session_file=$(session_file_for "$SESSION_1")
  token=$(process_start_token_for_pid "$$")
  [ -n "$token" ]

  cat >> "$session_file" <<JSONL
{"type":"process_start","id":"p-live","parentId":"u4","timestamp":"2026-03-14T10:31:00.000Z","pid":$$,"pid_start_time":"$token","cwd":"$BATS_TEST_TMPDIR","command":"bash","harness":"pi","model":"openai-codex/gpt-5.5","headless":false}
JSONL

  run sessions ps --json
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c '
import json, sys
rows = json.load(sys.stdin)
assert len(rows) == 1, rows
row = rows[0]
assert row["process_start_id"] == "p-live", row
assert row["status"] == "live", row
assert row["pid"] > 0, row
'
}

@test "ps hides dead missing-exit processes by default" {
  local session_file
  session_file=$(session_file_for "$SESSION_1")
  cat >> "$session_file" <<JSONL
{"type":"process_start","id":"p-dead","parentId":"u4","timestamp":"2026-03-14T10:31:00.000Z","pid":999999,"pid_start_time":"ps:not a real process","cwd":"$BATS_TEST_TMPDIR","command":"missing","harness":"pi","model":"openai-codex/gpt-5.5","headless":true}
JSONL

  run sessions ps --json
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c 'import json, sys; assert json.load(sys.stdin) == []'

  run sessions ps --all --json
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c '
import json, sys
rows = json.load(sys.stdin)
assert len(rows) == 1, rows
assert rows[0]["process_start_id"] == "p-dead", rows
assert rows[0]["status"] == "dead", rows
'
}

@test "ps treats exited process records as not live even if pid still exists" {
  local session_file token
  session_file=$(session_file_for "$SESSION_1")
  token=$(process_start_token_for_pid "$$")
  [ -n "$token" ]

  cat >> "$session_file" <<JSONL
{"type":"process_start","id":"p-exited","parentId":"u4","timestamp":"2026-03-14T10:31:00.000Z","pid":$$,"pid_start_time":"$token","cwd":"$BATS_TEST_TMPDIR","command":"bash","harness":"pi","model":"openai-codex/gpt-5.5","headless":false}
{"type":"process_exit","id":"x-exited","parentId":"p-exited","timestamp":"2026-03-14T10:32:00.000Z","process_start_id":"p-exited","pid":$$,"exit_code":0}
JSONL

  run sessions ps --json
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c 'import json, sys; assert json.load(sys.stdin) == []'

  run sessions ps --all --json
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c '
import json, sys
rows = json.load(sys.stdin)
assert len(rows) == 1, rows
assert rows[0]["process_start_id"] == "p-exited", rows
assert rows[0]["status"] == "exited", rows
assert rows[0]["exit_code"] == 0, rows
'
}

@test "run writes process_start and process_exit for managed sessions" {
  local stub_dir="$BATS_TEST_TMPDIR/stub-pi-process-events"
  local prompt="$BATS_TEST_TMPDIR/prompt.md"
  local session_file
  mkdir -p "$stub_dir"
  echo "test prompt" > "$prompt"
  cat > "$stub_dir/pi" <<'STUB'
#!/usr/bin/env bash
sleep 0.2
exit 0
STUB
  chmod +x "$stub_dir/pi"
  session_file=$(session_file_for "$SESSION_1")

  PATH="$stub_dir:$PATH" run sessions run \
    --system-prompt-file "$prompt" \
    --cwd "$BATS_TEST_TMPDIR" \
    --model "openai-codex/gpt-5.5" \
    --session "$session_file"
  [ "$status" -eq 0 ]

  jq -s -e 'any(.[]; .type == "process_start" and .pid > 0 and (.pid_start_time | length > 0) and .harness == "pi" and (.argv | length > 0))' "$session_file" >/dev/null
  jq -s -e 'any(.[]; .type == "process_exit" and .exit_code == 0)' "$session_file" >/dev/null
}
