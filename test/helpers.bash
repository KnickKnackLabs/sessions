# Shared test helpers for sessions BATS tests
#
# Provides:
#   - sessions() wrapper that calls tasks through mise
#   - PI_DIR override for test isolation
#   - Synthetic JSONL generation (pi format)
#   - Common setup/teardown

if [ -z "${MISE_CONFIG_ROOT:-}" ]; then
  echo "MISE_CONFIG_ROOT not set — run tests via: mise run test" >&2
  exit 1
fi

sessions() {
  cd "$MISE_CONFIG_ROOT" && PI_DIR="$PI_DIR" mise run -q "$@"
}
export -f sessions

# Fixed UUIDs for reproducible tests
SESSION_1="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
SESSION_2="11111111-2222-3333-4444-555555555555"

setup_test_sessions() {
  export PI_DIR="$BATS_TMPDIR/pi-test-$$"
  export PROJECT_DIR="$PI_DIR/agent/sessions/--test-project--/"
  mkdir -p "$PROJECT_DIR"

  # Session 1: a multi-turn conversation (pi format)
  # Filename: <timestamp>_<uuid>.jsonl
  cat > "${PROJECT_DIR}2026-03-14T10-00-00-000Z_${SESSION_1}.jsonl" <<JSONL
{"type":"session","version":3,"id":"${SESSION_1}","timestamp":"2026-03-14T10:00:00.000Z","cwd":"/test/project"}
{"type":"model_change","id":"mc1","parentId":null,"timestamp":"2026-03-14T10:00:00.001Z","provider":"anthropic","modelId":"claude-opus-4-6"}
{"type":"message","id":"u1","parentId":"mc1","timestamp":"2026-03-14T10:00:01.000Z","message":{"role":"user","content":[{"type":"text","text":"hello, can you help me?"}],"timestamp":1710403201000}}
{"type":"message","id":"a1","parentId":"u1","timestamp":"2026-03-14T10:00:02.000Z","message":{"role":"assistant","content":[{"type":"text","text":"Of course! What do you need help with?"}],"model":"claude-opus-4-6","provider":"anthropic","stopReason":"stop","timestamp":1710403202000}}
{"type":"message","id":"u2","parentId":"a1","timestamp":"2026-03-14T10:00:10.000Z","message":{"role":"user","content":[{"type":"text","text":"I need to fix the sccache configuration"}],"timestamp":1710403210000}}
{"type":"message","id":"a2","parentId":"u2","timestamp":"2026-03-14T10:00:15.000Z","message":{"role":"assistant","content":[{"type":"text","text":"Let me look at the sccache config."},{"type":"toolCall","id":"tc1","name":"bash","arguments":{"command":"cat ~/.config/sccache/config"}}],"model":"claude-opus-4-6","provider":"anthropic","stopReason":"toolUse","timestamp":1710403215000}}
{"type":"message","id":"tr1","parentId":"a2","timestamp":"2026-03-14T10:00:16.000Z","message":{"role":"toolResult","toolCallId":"tc1","toolName":"bash","content":[{"type":"text","text":"[cache]\ndir = /tmp/sccache"}],"isError":false,"timestamp":1710403216000}}
{"type":"message","id":"a3","parentId":"tr1","timestamp":"2026-03-14T10:00:20.000Z","message":{"role":"assistant","content":[{"type":"text","text":"The sccache config looks good. The cache directory is set to /tmp/sccache."}],"model":"claude-opus-4-6","provider":"anthropic","stopReason":"stop","timestamp":1710403220000}}
{"type":"message","id":"u4","parentId":"a3","timestamp":"2026-03-14T10:30:00.000Z","message":{"role":"user","content":[{"type":"text","text":"thanks, let's wrap up"}],"timestamp":1710405000000}}
JSONL

  # Session 2: a shorter conversation about something else
  cat > "${PROJECT_DIR}2026-03-15T14-00-00-000Z_${SESSION_2}.jsonl" <<JSONL
{"type":"session","version":3,"id":"${SESSION_2}","timestamp":"2026-03-15T14:00:00.000Z","cwd":"/test/project"}
{"type":"model_change","id":"mc1","parentId":null,"timestamp":"2026-03-15T14:00:00.001Z","provider":"anthropic","modelId":"claude-opus-4-6"}
{"type":"message","id":"u1","parentId":"mc1","timestamp":"2026-03-15T14:00:00.000Z","message":{"role":"user","content":[{"type":"text","text":"what is the weather like?"}],"timestamp":1710504000000}}
{"type":"message","id":"a1","parentId":"u1","timestamp":"2026-03-15T14:00:05.000Z","message":{"role":"assistant","content":[{"type":"text","text":"I don't have access to weather data, but I can help with coding tasks!"}],"model":"claude-opus-4-6","provider":"anthropic","stopReason":"stop","timestamp":1710504005000}}
JSONL

  # Touch session 2 to be newer
  sleep 0.1
  touch "${PROJECT_DIR}2026-03-15T14-00-00-000Z_${SESSION_2}.jsonl"

  # Session 3: has metadata
  SESSION_3="33333333-4444-5555-6666-777777777777"
  export SESSION_3
  cat > "${PROJECT_DIR}2026-03-16T10-00-00-000Z_${SESSION_3}.jsonl" <<JSONL
{"type":"session","version":3,"id":"${SESSION_3}","timestamp":"2026-03-16T10:00:00.000Z","cwd":"/test/project","meta":{"agent":{"name":"ikma","email":"ikma@ricon.family"},"purpose":"scout-report"}}
{"type":"model_change","id":"mc1","parentId":null,"timestamp":"2026-03-16T10:00:00.001Z","provider":"anthropic","modelId":"claude-sonnet-4-20250514"}
{"type":"message","id":"u1","parentId":"mc1","timestamp":"2026-03-16T10:00:01.000Z","message":{"role":"user","content":[{"type":"text","text":"scout the issues"}],"timestamp":1710576001000}}
{"type":"message","id":"a1","parentId":"u1","timestamp":"2026-03-16T10:00:05.000Z","message":{"role":"assistant","content":[{"type":"text","text":"Here are the issues."}],"model":"claude-sonnet-4-20250514","provider":"anthropic","stopReason":"stop","timestamp":1710576005000}}
JSONL
  sleep 0.1
  touch "${PROJECT_DIR}2026-03-16T10-00-00-000Z_${SESSION_3}.jsonl"

  # Session 4: has metadata + two wake events (for filter tests)
  SESSION_4="44444444-5555-6666-7777-888888888888"
  export SESSION_4
  cat > "${PROJECT_DIR}2026-03-17T10-00-00-000Z_${SESSION_4}.jsonl" <<JSONL
{"type":"session","version":3,"id":"${SESSION_4}","timestamp":"2026-03-17T10:00:00.000Z","cwd":"/test/project","meta":{"agent":{"name":"zeke"},"purpose":"review"}}
{"type":"model_change","id":"mc1","parentId":null,"timestamp":"2026-03-17T10:00:00.001Z","provider":"anthropic","modelId":"claude-opus-4-6"}
{"type":"wake","id":"w1","parentId":"mc1","timestamp":"2026-03-17T10:00:01.000Z","shell":"zeke-review","agent":"ikma","harness":"pi","headless":true,"meta":{"by":{"agent":{"name":"ikma","email":"ikma@ricon.family"}}}}
{"type":"message","id":"u1","parentId":"w1","timestamp":"2026-03-17T10:00:02.000Z","message":{"role":"user","content":[{"type":"text","text":"review the PR"}],"timestamp":1710662402000}}
{"type":"message","id":"a1","parentId":"u1","timestamp":"2026-03-17T10:00:10.000Z","message":{"role":"assistant","content":[{"type":"text","text":"PR looks good."}],"model":"claude-opus-4-6","provider":"anthropic","stopReason":"stop","timestamp":1710662410000}}
{"type":"wake","id":"w2","parentId":"a1","timestamp":"2026-03-17T11:00:00.000Z","shell":"zeke-review-2","agent":"brownie","harness":"pi","headless":true,"meta":{"by":{"agent":{"name":"brownie","email":"brownie@ricon.family"}}}}
{"type":"message","id":"u2","parentId":"w2","timestamp":"2026-03-17T11:00:01.000Z","message":{"role":"user","content":[{"type":"text","text":"anything else to check?"}],"timestamp":1710666001000}}
{"type":"message","id":"a2","parentId":"u2","timestamp":"2026-03-17T11:00:05.000Z","message":{"role":"assistant","content":[{"type":"text","text":"All clear."}],"model":"claude-opus-4-6","provider":"anthropic","stopReason":"stop","timestamp":1710666005000}}
JSONL
  sleep 0.1
  touch "${PROJECT_DIR}2026-03-17T10-00-00-000Z_${SESSION_4}.jsonl"
}

teardown_test_sessions() {
  rm -rf "$PI_DIR"
}
