#!/usr/bin/env bats

bats_require_minimum_version 1.5.0
load helpers

setup() {
  setup_test_sessions
  # Extend the shared synthetic fixture with empty/tool messages and a fork.
  # seq 13 follows u1, not a3: both branches deliberately remain in the query.
  cat >> "${PROJECT_DIR}2026-03-14T10-00-00-000Z_${SESSION_1}.jsonl" <<'JSONL'
{"type":"message","id":"tool-only","parentId":"u4","message":{"role":"assistant","content":[{"type":"toolCall","id":"tc2","name":"read","arguments":{"path":"example.txt"}}]}}
{"type":"message","id":"tool-result","parentId":"tool-only","message":{"role":"toolResult","toolCallId":"tc2","toolName":"read","content":[{"type":"text","text":"Tool output is not conversation."}]}}
{"type":"message","id":"blank","parentId":"tool-result","message":{"role":"assistant","content":[{"type":"text","text":" \t\n\r\f\u000b "}]}}
{"type":"message","id":"fork-reply","parentId":"u1","timestamp":"2026-03-14T10:31:00.000Z","message":{"role":"assistant","content":[{"type":"text","text":"Alternate reply.\nSecond line."}]}}
{"type":"message","id":"system","parentId":"fork-reply","message":{"role":"system","content":"Not a conversation role."}}
{"type":"message","id":"follow-up","parentId":"system","message":{"role":"user","content":"Follow-up"}}
{"type":"custom","id":"checkpoint","parentId":"follow-up"}
{"type":"message","id":"newest","parentId":"checkpoint","timestamp":"2026-03-14T10:32:00.000Z","message":{"role":"assistant","content":[{"type":"text","text":"Newest reply."}]}}
{"type":"message","id":"later-user","parentId":"newest","message":{"role":"user","content":"Later user"}}
{"type":"message","id":"thinking-only","parentId":"later-user","message":{"role":"assistant","content":[{"type":"thinking","thinking":"No visible text."}]}}
{"type":"message","id":"trailing-blank","parentId":"thinking-only","message":{"role":"assistant","content":"\n\t "}}
JSONL
}

teardown() { teardown_test_sessions; }

@test "last assistant example defaults to one text message through packaged lookup" {
  export SESSIONS_CALLER_PWD="$BATS_TEST_TMPDIR"
  run sessions query "$SESSION_1" --text full \
    --sql-file queries/last-assistant-messages.sql --format json
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c '
import json, sys
rows = json.load(sys.stdin)
assert rows == [{
    "session_id": sys.argv[1], "seq": 17,
    "timestamp": "2026-03-14T10:32:00.000Z", "role": "assistant",
    "text_chars": 13, "text": "Newest reply.",
}], rows
' "$SESSION_1"
}

@test "last assistant example selects last N or all then orders by recorded sequence" {
  for count in 2 99 NULL; do
    sql="$BATS_TEST_TMPDIR/last.sql"
    sed "s/values (1)/values ($count)/" \
      "$REPO_DIR/queries/last-assistant-messages.sql" > "$sql"
    run sessions query "$SESSION_1" --text full --sql-file "$sql" --format json
    [ "$status" -eq 0 ]
    echo "$output" | python3 -c '
import json, sys
rows = json.load(sys.stdin)
expected = [13, 17] if sys.argv[1] == "2" else [4, 6, 8, 13, 17]
assert [r["seq"] for r in rows] == expected, rows
assert all(r["role"] == "assistant" for r in rows), rows
assert rows[-2]["text"] == "Alternate reply.\nSecond line.", rows
assert rows[-1]["text"] == "Newest reply.", rows
' "$count"
  done
}

@test "conversation example returns recorded user and assistant text only" {
  export SESSIONS_CALLER_PWD="$BATS_TEST_TMPDIR"
  run sessions query "$SESSION_1" --text full \
    --sql-file queries/conversation-since.sql --format json
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c '
import json, sys
rows = json.load(sys.stdin)
assert [(r["seq"], r["role"]) for r in rows] == [
    (3, "user"), (4, "assistant"), (5, "user"), (6, "assistant"),
    (8, "assistant"), (9, "user"), (13, "assistant"),
    (15, "user"), (17, "assistant"), (18, "user"),
], rows
assert rows[-1]["text"] == "Later user", rows
'
}

@test "conversation example uses an exclusive checkpoint and earliest row limit" {
  sql="$BATS_TEST_TMPDIR/since.sql"
  sed 's/values (0, 20)/values (6, 2)/' \
    "$REPO_DIR/queries/conversation-since.sql" > "$sql"
  run sessions query "$SESSION_1" --text full --sql-file "$sql" --format json
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c '
import json, sys
rows = json.load(sys.stdin)
assert [r["seq"] for r in rows] == [8, 9], rows
'

  # A checkpoint can be a non-message entry. NULL deliberately removes the cap.
  sed 's/values (0, 20)/values (16, NULL)/' \
    "$REPO_DIR/queries/conversation-since.sql" > "$sql"
  run sessions query "$SESSION_1" --text full --sql-file "$sql" --format json
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c '
import json, sys
rows = json.load(sys.stdin)
assert [r["seq"] for r in rows] == [17, 18], rows
'
}

@test "conversation example returns no rows after the last matching message" {
  sql="$BATS_TEST_TMPDIR/since.sql"
  sed 's/values (0, 20)/values (18, 20)/' \
    "$REPO_DIR/queries/conversation-since.sql" > "$sql"
  run sessions query "$SESSION_1" --text full --sql-file "$sql" --format json
  [ "$status" -eq 0 ]
  [ "$output" = '[]' ]
}

@test "conversation examples require text and exactly one projected session" {
  for preset in last-assistant-messages conversation-since; do
    for mode in none commands; do
      run sessions query "$SESSION_1" --text "$mode" \
        --sql-file "queries/$preset.sql" --format json
      [ "$status" -eq 0 ]
      [ "$output" = '[]' ]
    done

    run sessions query "$SESSION_1" "$SESSION_2" --text full \
      --sql-file "queries/$preset.sql" --format json
    [ "$status" -eq 0 ]
    [ "$output" = '[]' ]

    run sessions query --project no-such-project --text full \
      --sql-file "queries/$preset.sql" --format json
    [ "$status" -eq 0 ]
    [ "$output" = '[]' ]
  done
}

@test "last assistant example preserves compact text budget and original length" {
  run sessions query "$SESSION_1" --text compact --max-message-chars 6 \
    --sql-file queries/last-assistant-messages.sql --format json
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c '
import json, sys
rows = json.load(sys.stdin)
assert len(rows) == 1, rows
assert rows[0]["seq"] == 17, rows
assert rows[0]["text_chars"] == 13, rows
assert rows[0]["text"] == "New\n[... compacted 7 chars ...]\nly.", rows
'
}
