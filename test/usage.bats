#!/usr/bin/env bats

load helpers

setup() {
  setup_test_sessions
  USAGE_SESSION="99999999-aaaa-bbbb-cccc-dddddddddddd"
  export USAGE_SESSION
  USAGE_SESSION_2="88888888-aaaa-bbbb-cccc-dddddddddddd"
  export USAGE_SESSION_2
  CLAUDE_USAGE_SESSION="77777777-aaaa-bbbb-cccc-dddddddddddd"
  export CLAUDE_USAGE_SESSION

  cat > "${PROJECT_DIR}2026-03-14T12-00-00-000Z_${USAGE_SESSION}.jsonl" <<JSONL
{"type":"session","version":3,"id":"${USAGE_SESSION}","timestamp":"2026-03-14T12:00:00.000Z","cwd":"/test/project","meta":{"agent":{"name":"usage-tester"}}}
{"type":"model_change","id":"mc1","parentId":null,"timestamp":"2026-03-14T12:00:00.001Z","provider":"openai","modelId":"model-a"}
{"type":"message","id":"a1","parentId":"mc1","timestamp":"2026-03-14T12:00:01.000Z","message":{"role":"assistant","content":[{"type":"text","text":"first"}],"provider":"openai","stopReason":"stop","usage":{"input":100,"output":20,"cacheRead":1000,"cacheWrite":0,"totalTokens":1120,"cost":{"input":0.10,"output":0.20,"cacheRead":0.01,"cacheWrite":0,"total":0.31}}}}
{"type":"model_change","id":"mc2","parentId":"a1","timestamp":"2026-03-14T12:01:00.000Z","provider":"local","modelId":"model-b"}
{"type":"message","id":"a2","parentId":"mc2","timestamp":"2026-03-14T12:01:01.000Z","message":{"role":"assistant","content":[{"type":"text","text":"second"}],"stopReason":"stop","usage":{"input":50,"output":10,"cacheRead":0,"cacheWrite":0,"totalTokens":60,"cost":{"input":0.05,"output":0.01,"cacheRead":0,"cacheWrite":0,"total":0.06}}}}
{"type":"message","id":"a3","parentId":"a2","timestamp":"2026-03-14T12:02:01.000Z","message":{"role":"assistant","content":[{"type":"text","text":"third"}],"provider":"explicit-provider","model":"explicit-c","stopReason":"stop","usage":{"input":25,"output":5,"cacheRead":0,"cacheWrite":0,"totalTokens":30,"cost":{"input":0.02,"output":0.01,"cacheRead":0,"cacheWrite":0,"total":0.03}}}}
JSONL

  cat > "${PROJECT_DIR}2026-03-15T12-00-00-000Z_${USAGE_SESSION_2}.jsonl" <<JSONL
{"type":"session","version":3,"id":"${USAGE_SESSION_2}","timestamp":"2026-03-15T12:00:00.000Z","cwd":"/test/project"}
{"type":"model_change","id":"mc1","parentId":null,"timestamp":"2026-03-15T12:00:00.001Z","provider":"openai","modelId":"model-a"}
{"type":"message","id":"a1","parentId":"mc1","timestamp":"2026-03-15T12:00:01.000Z","message":{"role":"assistant","content":[{"type":"text","text":"aggregate"}],"model":"model-a","provider":"openai","stopReason":"stop","usage":{"input":7,"output":3,"cacheRead":0,"cacheWrite":0,"totalTokens":10,"cost":{"input":0.007,"output":0.003,"cacheRead":0,"cacheWrite":0,"total":0.01}}}}
JSONL

  cat > "${PROJECT_DIR}2026-03-16T12-00-00-000Z_${CLAUDE_USAGE_SESSION}.jsonl" <<JSONL
{"type":"session","version":3,"id":"${CLAUDE_USAGE_SESSION}","timestamp":"2026-03-16T12:00:00.000Z","cwd":"/test/project"}
{"type":"harness","name":"claude","timestamp":"2026-03-16T12:00:00.001Z"}
JSONL
}

teardown() { teardown_test_sessions; }

@test "usage summarizes a single session as JSON" {
  run sessions usage "$USAGE_SESSION" --json

  [ "$status" -eq 0 ]
  echo "$output" | python3 -c "
import json, sys
obj = json.load(sys.stdin)
assert obj['session_id'] == '$USAGE_SESSION'
assert obj['totals']['calls'] == 3
assert obj['totals']['input'] == 175
assert obj['totals']['output'] == 35
assert obj['totals']['cacheRead'] == 1000
assert obj['totals']['totalTokens'] == 1210
assert abs(obj['totals']['cost']['total'] - 0.40) < 0.000001
"
}

@test "usage attributes records across model switches" {
  run sessions usage "$USAGE_SESSION" --json

  [ "$status" -eq 0 ]
  echo "$output" | python3 -c "
import json, sys
by = json.load(sys.stdin)['by_model']
assert by['openai/model-a']['calls'] == 1
assert by['local/model-b']['calls'] == 1
assert by['explicit-provider/explicit-c']['calls'] == 1
assert by['openai/model-a']['totalTokens'] == 1120
assert by['local/model-b']['totalTokens'] == 60
assert by['explicit-provider/explicit-c']['totalTokens'] == 30
"
}

@test "usage --turns includes per-turn records" {
  run sessions usage "$USAGE_SESSION" --json --turns

  [ "$status" -eq 0 ]
  echo "$output" | python3 -c "
import json, sys
turns = json.load(sys.stdin)['turns']
assert len(turns) == 3
assert turns[0]['model'] == 'model-a'
assert turns[1]['model'] == 'model-b'
assert turns[2]['model'] == 'explicit-c'
"
}

@test "usage reports sessions with no recorded usage" {
  run sessions usage "$SESSION_1"

  [ "$status" -eq 0 ]
  echo "$output" | grep -q "No recorded usage"
}

@test "usage aggregates date-filtered sessions" {
  run sessions usage --after 2026-03-15 --before 2026-03-15 --project test-project --json

  [ "$status" -eq 0 ]
  echo "$output" | python3 -c "
import json, sys
obj = json.load(sys.stdin)
assert obj['totals']['calls'] == 1
assert obj['totals']['input'] == 7
assert obj['totals']['output'] == 3
assert obj['totals']['totalTokens'] == 10
assert len(obj['sessions']) == 1
assert obj['sessions'][0]['session_id'] == '$USAGE_SESSION_2'
"
}

@test "usage applies metadata filters before the default aggregate limit" {
  for i in $(seq -w 1 20); do
    cat > "${PROJECT_DIR}2026-03-16T12-${i}-00-000Z_other-${i}.jsonl" <<JSONL
{"type":"session","version":3,"id":"other-${i}","timestamp":"2026-03-16T12:${i}:00.000Z","cwd":"/test/project","meta":{"agent":{"name":"other"}}}
{"type":"model_change","id":"mc1","parentId":null,"timestamp":"2026-03-16T12:${i}:00.001Z","provider":"openai","modelId":"model-a"}
{"type":"message","id":"a1","parentId":"mc1","timestamp":"2026-03-16T12:${i}:01.000Z","message":{"role":"assistant","content":[{"type":"text","text":"other"}],"provider":"openai","model":"model-a","stopReason":"stop","usage":{"input":1,"output":1,"cacheRead":0,"cacheWrite":0,"totalTokens":2,"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"total":0}}}}
JSONL
    touch "${PROJECT_DIR}2026-03-16T12-${i}-00-000Z_other-${i}.jsonl"
  done

  run sessions usage --filter session.meta.agent.name=usage-tester --json

  [ "$status" -eq 0 ]
  echo "$output" | python3 -c "
import json, sys
obj = json.load(sys.stdin)
assert len(obj['sessions']) == 1
assert obj['sessions'][0]['session_id'] == '$USAGE_SESSION'
assert obj['totals']['calls'] == 3
"
}

@test "usage clears inherited optional usage defaults" {
  run env \
    usage_today=true \
    usage_after=2099-01-01 \
    usage_before=2099-01-01 \
    usage_limit=1 \
    usage_project=no-such-project \
    usage_filter='session.meta.agent.name=nope' \
    usage_all=true \
    usage_turns=true \
    usage_json=true \
    bash -c 'sessions usage "$1"' _ "$USAGE_SESSION"

  [ "$status" -eq 0 ]
  echo "$output" | grep -q "Totals"
  echo "$output" | grep -q "1,210"
  ! echo "$output" | python3 -m json.tool >/dev/null 2>&1
}

@test "usage reports unsupported harness cleanly" {
  run sessions usage "$CLAUDE_USAGE_SESSION"

  [ "$status" -eq 10 ]
  echo "$output" | grep -q "claude.*does not support.*usage"
}
