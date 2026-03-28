#!/usr/bin/env bats

load helpers

setup() { setup_test_sessions; }
teardown() { teardown_test_sessions; }

@test "read shows session transcript" {
  run sessions read "$SESSION_1"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "hello.*help"
  echo "$output" | grep -q "Of course"
}

@test "read shows session header with ID and project" {
  run sessions read "$SESSION_1"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "${SESSION_1:0:8}"
  echo "$output" | grep -q "test/project"
}

@test "read shows model and duration in header" {
  run sessions read "$SESSION_1"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "claude-opus-4-6"
  echo "$output" | grep -q "30m"
}

@test "read shows role headers" {
  run sessions read "$SESSION_1"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "User"
  echo "$output" | grep -q "Assistant"
}

@test "read shows timestamps on role headers" {
  run sessions read "$SESSION_1"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "10:00"
}

@test "read hides tool blocks by default" {
  run sessions read "$SESSION_1"
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -q "\[tool_use:"
  ! echo "$output" | grep -q "\[tool_result:"
}

@test "read --tools shows tool blocks" {
  run sessions read "$SESSION_1" --tools
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "\[tool_use:.*bash"
  echo "$output" | grep -q "\[tool_result:.*bash"
}

@test "read --user-only shows only user messages" {
  run sessions read "$SESSION_1" --user-only
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "hello.*help"
  ! echo "$output" | grep -q "Of course"
}

@test "read --last limits to last N messages" {
  run sessions read "$SESSION_1" --last 2
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "messages.*of"
  # Should have the final messages, not the first
  echo "$output" | grep -q "wrap up\|sccache config looks good"
}

@test "read --last larger than message count shows all" {
  run sessions read "$SESSION_1" --last 100
  [ "$status" -eq 0 ]
  # Should not show window indicator when limit exceeds total
  ! echo "$output" | grep -q "messages.*of"
  echo "$output" | grep -q "hello.*help"
}

@test "read --from --to shows a window" {
  run sessions read "$SESSION_1" --from 2 --to 3
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "messages 2.3 of"
  # Message 2 is "Of course! What do you need help with?"
  echo "$output" | grep -q "Of course"
}

@test "read --from without --to shows from N to end" {
  run sessions read "$SESSION_1" --from 4
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "messages 4."
  # Should include the last message ("wrap up") but not the first ("hello")
  echo "$output" | grep -q "wrap up"
  ! echo "$output" | grep -q "hello.*help"
}

@test "read --to without --from shows from start to N" {
  run sessions read "$SESSION_1" --to 2
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "messages 1.2 of"
  echo "$output" | grep -q "hello.*help"
  echo "$output" | grep -q "Of course"
  ! echo "$output" | grep -q "wrap up"
}

@test "read negative --from counts from end" {
  run sessions read "$SESSION_1" --from -2
  [ "$status" -eq 0 ]
  # Should show last 2 messages
  echo "$output" | grep -q "wrap up\|sccache config looks good"
}

@test "read negative --from --to counts from end" {
  run sessions read "$SESSION_1" --from -3 --to -2
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "messages.*of"
}

@test "read --json outputs valid JSON" {
  run sessions read "$SESSION_1" --json
  [ "$status" -eq 0 ]
  echo "$output" | python3 -m json.tool > /dev/null
}

@test "read --json includes session metadata" {
  run sessions read "$SESSION_1" --json
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c "
import json, sys
data = json.load(sys.stdin)
assert data['session_id'] == '${SESSION_1}'
assert 'project' in data
assert 'model' in data
assert 'messages' in data
"
}

@test "read --json messages have expected fields" {
  run sessions read "$SESSION_1" --json
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c "
import json, sys
data = json.load(sys.stdin)
msgs = data['messages']
assert len(msgs) > 0
for m in msgs:
    assert 'index' in m
    assert 'role' in m
    assert 'timestamp' in m
    assert 'text' in m
"
}

@test "read --json respects --last" {
  run sessions read "$SESSION_1" --json --last 2
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c "
import json, sys
data = json.load(sys.stdin)
assert len(data['messages']) == 2
"
}

@test "read --json respects --user-only" {
  run sessions read "$SESSION_1" --json --user-only
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c "
import json, sys
data = json.load(sys.stdin)
msgs = data['messages']
assert all(m['role'] == 'user' for m in msgs)
"
}

@test "read skips synthetic no-response entries" {
  run sessions read "$SESSION_1"
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -q "No response requested"
}

@test "read errors with no session ID" {
  run sessions read
  [ "$status" -eq 1 ]
}

@test "read errors with nonexistent session" {
  run sessions read "deadbeef"
  [ "$status" -eq 1 ]
  echo "$output" | grep -qi "no session"
}
