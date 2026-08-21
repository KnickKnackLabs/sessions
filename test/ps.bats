#!/usr/bin/env bats

load helpers
# shellcheck source=../lib/processes.sh
source "$REPO_DIR/lib/processes.sh"

setup() {
  setup_test_sessions
  sessions ps --json >/dev/null 2>&1
}
teardown() { teardown_test_sessions; }

process_start_token_for_pid() {
  sessions_process_start_time_token "$1"
}

make_proc_stat() {
  local comm="$1"
  printf '123 (%s) S' "$comm"
  printf ' %s' 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18
  printf ' 12345 999\n'
}

session_file_for() {
  local session_id="$1"
  find "$PROJECT_DIR" -name "*${session_id}.jsonl" | head -1
}

@test "Linux proc stat parser handles parenthesized process names" {
  [ "$(sessions_linux_proc_start_time_from_stat "$(make_proc_stat "sleep")")" = "12345" ]
  [ "$(sessions_linux_proc_start_time_from_stat "$(make_proc_stat "sleep space")")" = "12345" ]
  [ "$(sessions_linux_proc_start_time_from_stat "$(make_proc_stat "weird) name")")" = "12345" ]

  run sessions_linux_proc_start_time_from_stat "bad stat"
  [ "$status" -ne 0 ]

  local zero_stat
  zero_stat=$(make_proc_stat "zero")
  zero_stat="${zero_stat/12345/0}"
  run sessions_linux_proc_start_time_from_stat "$zero_stat"
  [ "$status" -ne 0 ]
}

@test "Python proc stat parser matches shell parser cases" {
  PYTHONPATH="$REPO_DIR/lib" python3 - <<'PY'
from processes import _linux_proc_stat_start_time

def proc_stat(comm, start="12345"):
    rest = "S " + " ".join(str(i) for i in range(1, 19)) + f" {start} 999"
    return f"123 ({comm}) {rest}"

assert _linux_proc_stat_start_time(proc_stat("sleep")) == "12345"
assert _linux_proc_stat_start_time(proc_stat("sleep space")) == "12345"
assert _linux_proc_stat_start_time(proc_stat("weird) name")) == "12345"
assert _linux_proc_stat_start_time("bad stat") == ""
assert _linux_proc_stat_start_time(proc_stat("zero", "0")) == ""
assert _linux_proc_stat_start_time(proc_stat("nondigit", "abc")) == ""
PY
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

@test "ps handles Linux process names containing spaces" {
  if [ ! -d /proc ]; then
    skip "Linux /proc-only regression"
  fi

  local session_file sleep_bin spaced_sleep pid token
  session_file=$(session_file_for "$SESSION_1")
  sleep_bin=$(command -v sleep)
  spaced_sleep="$BATS_TEST_TMPDIR/sleep space"
  ln -s "$sleep_bin" "$spaced_sleep"
  "$spaced_sleep" 5 &
  pid=$!
  token=$(process_start_token_for_pid "$pid")
  [[ "$token" =~ ^linux:[1-9][0-9]*$ ]]

  cat >> "$session_file" <<JSONL
{"type":"process_start","id":"p-spaced","parentId":"u4","timestamp":"2026-03-14T10:31:00.000Z","pid":$pid,"pid_start_time":"$token","cwd":"$BATS_TEST_TMPDIR","command":"sleep space","harness":"pi","model":"openai-codex/gpt-5.5","headless":false}
JSONL

  run sessions ps --json
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c '
import json, sys
rows = json.load(sys.stdin)
assert len(rows) == 1, rows
assert rows[0]["process_start_id"] == "p-spaced", rows
assert rows[0]["status"] == "live", rows
'

  if ! kill "$pid" 2>/dev/null; then
    :
  fi
  if ! wait "$pid" 2>/dev/null; then
    :
  fi
}

@test "ps hides dead missing-exit processes by default" {
  local session_file dead_pid
  session_file=$(session_file_for "$SESSION_1")
  sleep 0.01 &
  dead_pid=$!
  wait "$dead_pid"
  cat >> "$session_file" <<JSONL
{"type":"process_start","id":"p-dead","parentId":"u4","timestamp":"2026-03-14T10:31:00.000Z","pid":$dead_pid,"pid_start_time":"ps:not a real process","cwd":"$BATS_TEST_TMPDIR","command":"missing","harness":"pi","model":"openai-codex/gpt-5.5","headless":true}
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
  stub_mise_resolve_pi "$stub_dir"
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

@test "process roster scans lifecycle lines without decoding message bodies" {
  PYTHONPATH="$REPO_DIR/lib" python3 - <<'PY'
import json
import tempfile
from pathlib import Path
from unittest.mock import patch

import processes

with tempfile.TemporaryDirectory() as directory:
    path = Path(directory) / "2026-08-20T00-00-00-000Z_00000000-0000-4000-8000-000000000000.jsonl"
    entries = [
        {"type": "session", "id": "00000000-0000-4000-8000-000000000000", "timestamp": "2026-08-20T00:00:00.000Z"},
        {"type": "message", "message": {"role": "assistant", "content": [{"type": "text", "text": "unrelated"}]}},
        {"type": "process_start", "id": "start", "pid": 123, "pid_start_time": "ps:synthetic"},
    ]
    path.write_text("\n".join(json.dumps(entry) for entry in entries) + "\n", encoding="utf-8")

    original_loads = processes.json.loads
    def guarded_loads(raw):
        if '"type": "message"' in raw:
            raise AssertionError("message body was decoded")
        return original_loads(raw)

    with patch.object(processes.json, "loads", side_effect=guarded_loads):
        session = processes.load_process_session(str(path))

    assert [entry["type"] for entry in session.entries] == ["session", "process_start"]
PY
}

@test "process roster applies project filters before opening transcripts" {
  PYTHONPATH="$REPO_DIR/lib" python3 - <<'PY'
import json
import os
import tempfile
from pathlib import Path
from unittest.mock import patch

import processes

with tempfile.TemporaryDirectory() as directory:
    os.environ["PI_DIR"] = directory
    sessions = Path(directory) / "agent" / "sessions"
    for index, name in enumerate(("alpha", "beta"), start=1):
        project = sessions / f"--Users-test-{name}--"
        project.mkdir(parents=True)
        session_id = f"00000000-0000-4000-8000-{index:012d}"
        path = project / f"2026-08-20T00-00-00-000Z_{session_id}.jsonl"
        path.write_text(json.dumps({
            "type": "session",
            "id": session_id,
            "timestamp": "2026-08-20T00:00:00.000Z",
        }) + "\n", encoding="utf-8")

    opened = []
    original = processes.load_process_session
    def tracked_load(path):
        opened.append(path)
        return original(path)

    with patch.object(processes, "load_process_session", side_effect=tracked_load):
        rows = processes.collect_process_rows(project_filter="alpha", include_all=True)

assert rows == []
assert len(opened) == 1, opened
assert "alpha" in opened[0], opened
PY
}

@test "process roster batches fallback PID probes and preserves exact start tokens" {
  PYTHONPATH="$REPO_DIR/lib" python3 - <<'PY'
from types import SimpleNamespace
from unittest.mock import patch

import processes

completed = SimpleNamespace(returncode=0, stdout="101 Wed Aug 20 12:00:01 2026\n202 Wed Aug 20 12:00:02 2026\n", stderr="")
with patch("processes._linux_process_start_time_token", return_value="") as linux, \
     patch("processes.subprocess.run", return_value=completed) as run:
    probe = processes.probe_process_start_times([101, 202, 101])

assert probe.tokens == {
    101: "ps:Wed Aug 20 12:00:01 2026",
    202: "ps:Wed Aug 20 12:00:02 2026",
}
assert probe.unknown == set()
assert linux.call_count == 2
assert run.call_count == 1
args = run.call_args.args[0]
assert args[:3] == ["ps", "-p", "101,202"], args
assert processes._ps_start_time_tokens("unparseable") is None
PY
}

@test "process roster keeps failed PID probes visible as unknown" {
  PYTHONPATH="$REPO_DIR/lib" python3 - <<'PY'
import json
import subprocess
import tempfile
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

import processes

with tempfile.TemporaryDirectory() as directory:
    path = Path(directory) / "2026-08-20T00-00-00-000Z_00000000-0000-4000-8000-000000000000.jsonl"
    entries = [
        {"type": "session", "id": "00000000-0000-4000-8000-000000000000", "timestamp": "2026-08-20T00:00:00.000Z"},
        {"type": "process_start", "id": "start", "pid": 123, "pid_start_time": "ps:synthetic"},
    ]
    path.write_text("\n".join(json.dumps(entry) for entry in entries) + "\n", encoding="utf-8")

    with patch("processes._linux_process_start_time_token", return_value=""), \
         patch("processes.subprocess.run", side_effect=subprocess.TimeoutExpired("ps", 2)):
        rows = processes.session_process_rows(str(path))

assert len(rows) == 1, rows
assert rows[0].status == "unknown", rows

failed = SimpleNamespace(returncode=1, stdout="", stderr="ps: invalid process id")
with patch("processes._linux_process_start_time_token", return_value=""), \
     patch("processes.subprocess.run", return_value=failed):
    probe = processes.probe_process_start_times([123, 999999])
assert probe.tokens == {}
assert probe.unknown == {123, 999999}
PY
}
