# Shared test helpers for sessions BATS tests
#
# Provides:
#   - CLAUDE_DIR override for test isolation
#   - Synthetic JSONL generation
#   - Common setup/teardown

TASKS_DIR="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/.mise/tasks"

# Fixed UUIDs for reproducible tests
SESSION_1="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
SESSION_2="11111111-2222-3333-4444-555555555555"

setup_test_sessions() {
  export CLAUDE_DIR="$BATS_TMPDIR/claude-test-$$"
  export PROJECT_DIR="$CLAUDE_DIR/projects/-test-project/"
  mkdir -p "$PROJECT_DIR"

  # Session 1: a multi-turn conversation
  cat > "${PROJECT_DIR}${SESSION_1}.jsonl" <<JSONL
{"type":"queue-operation","operation":"enqueue","timestamp":"2026-03-14T10:00:00.000Z","sessionId":"${SESSION_1}"}
{"type":"user","message":{"role":"user","content":"hello, can you help me?"},"uuid":"u1","parentUuid":null,"sessionId":"${SESSION_1}","timestamp":"2026-03-14T10:00:01.000Z"}
{"type":"assistant","message":{"role":"assistant","model":"claude-opus-4-6","content":[{"type":"text","text":"Of course! What do you need help with?"}]},"uuid":"a1","parentUuid":"u1","sessionId":"${SESSION_1}","timestamp":"2026-03-14T10:00:02.000Z"}
{"type":"user","message":{"role":"user","content":"I need to fix the sccache configuration"},"uuid":"u2","parentUuid":"a1","sessionId":"${SESSION_1}","timestamp":"2026-03-14T10:00:10.000Z"}
{"type":"assistant","message":{"role":"assistant","model":"claude-opus-4-6","content":[{"type":"text","text":"Let me look at the sccache config."},{"type":"tool_use","id":"tu1","name":"Bash","input":{"command":"cat ~/.config/sccache/config"}}]},"uuid":"a2","parentUuid":"u2","sessionId":"${SESSION_1}","timestamp":"2026-03-14T10:00:15.000Z"}
{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tu1","content":"[cache]\ndir = /tmp/sccache"}]},"uuid":"u3","parentUuid":"a2","sessionId":"${SESSION_1}","timestamp":"2026-03-14T10:00:16.000Z"}
{"type":"assistant","message":{"role":"assistant","model":"claude-opus-4-6","content":[{"type":"text","text":"The sccache config looks good. The cache directory is set to /tmp/sccache."}]},"uuid":"a3","parentUuid":"u3","sessionId":"${SESSION_1}","timestamp":"2026-03-14T10:00:20.000Z"}
{"type":"user","message":{"role":"user","content":"thanks, let's wrap up"},"uuid":"u4","parentUuid":"a3","sessionId":"${SESSION_1}","timestamp":"2026-03-14T10:30:00.000Z"}
{"type":"assistant","message":{"role":"assistant","model":"<synthetic>","content":[{"type":"text","text":"No response requested."}]},"uuid":"s1","parentUuid":"u4","sessionId":"${SESSION_1}","timestamp":"2026-03-14T10:30:01.000Z"}
JSONL

  # Session 2: a shorter conversation about something else
  cat > "${PROJECT_DIR}${SESSION_2}.jsonl" <<JSONL
{"type":"user","message":{"role":"user","content":"what is the weather like?"},"uuid":"u1","parentUuid":null,"sessionId":"${SESSION_2}","timestamp":"2026-03-15T14:00:00.000Z"}
{"type":"assistant","message":{"role":"assistant","model":"claude-opus-4-6","content":[{"type":"text","text":"I don't have access to weather data, but I can help with coding tasks!"}]},"uuid":"a1","parentUuid":"u1","sessionId":"${SESSION_2}","timestamp":"2026-03-15T14:00:05.000Z"}
JSONL

  # Touch session 2 to be newer
  sleep 0.1
  touch "${PROJECT_DIR}${SESSION_2}.jsonl"
}

teardown_test_sessions() {
  rm -rf "$CLAUDE_DIR"
}
