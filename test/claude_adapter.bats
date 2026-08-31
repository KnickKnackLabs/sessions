#!/usr/bin/env bats
#
# Claude Code harness adapter tests (sessions#50 step 4).
#
# Covers the on-disk layout, lookup, entry builders and launch argv for
# claude sessions, plus the boundary where step 5 (headless `run`) is
# still UNSUPPORTED.

load helpers

setup() {
  setup_test_sessions
  setup_test_claude_dir
  export HARNESS_LIB_DIR="$REPO_DIR/lib/harness"
  # shellcheck source=/dev/null
  source "$REPO_DIR/lib/harness/dispatch.sh"
  # shellcheck source=/dev/null
  source "$REPO_DIR/lib/harness/claude.sh"
}

teardown() {
  teardown_test_sessions
}

# --- Location ---

@test "encode_cwd maps every non-alphanumeric character to a dash" {
  run harness_claude_encode_cwd /home/agent/Work
  [ "$status" -eq 0 ]
  [ "$output" = "-home-agent-Work" ]

  # Dots, underscores, spaces and symbols all collapse to a dash, case
  # is preserved, and repeats are not collapsed.
  run harness_claude_encode_cwd "/tmp/a.b_c/probe two+odd@x"
  [ "$status" -eq 0 ]
  [ "$output" = "-tmp-a-b-c-probe-two-odd-x" ]
}

@test "sessions_dir honours CLAUDE_DIR" {
  run harness_claude_sessions_dir
  [ "$status" -eq 0 ]
  [ "$output" = "$CLAUDE_DIR/projects" ]
}

@test "session_file_path is <projects>/<encoded-cwd>/<uuid>.jsonl" {
  run harness_claude_session_file_path /home/agent/Work "$SESSION_1" 2026-04-01T10:00:00.000Z
  [ "$status" -eq 0 ]
  [ "$output" = "$CLAUDE_DIR/projects/-home-agent-Work/${SESSION_1}.jsonl" ]
  [ -d "$CLAUDE_DIR/projects/-home-agent-Work" ]
}

# --- Trust and model translation ---

@test "project_trust_flag maps deny to --safe-mode and leaves approve native" {
  run harness_claude_project_trust_flag inherit
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  # Deliberate no-op: claude has no pre-trust flag, and shimmer passes
  # --project-trust approve on every wake.
  run harness_claude_project_trust_flag approve
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  run harness_claude_project_trust_flag deny
  [ "$status" -eq 0 ]
  [ "$output" = "--safe-mode" ]
}

@test "project_trust_flag rejects an unknown policy" {
  run harness_claude_project_trust_flag sideways
  [ "$status" -eq 2 ]
}

@test "model_arg strips the provider claude cannot see" {
  run harness_claude_model_arg anthropic/claude-opus-5
  [ "$status" -eq 0 ]
  [ "$output" = "claude-opus-5" ]

  run harness_claude_model_arg claude-code/opus
  [ "$status" -eq 0 ]
  [ "$output" = "opus" ]
}

@test "model_arg refuses a model from another provider" {
  run harness_claude_model_arg openai-codex/gpt-5.5
  [ "$status" -eq 1 ]
  [[ "$output" == *"cannot run model"* ]]
}

# --- new ---

@test "new --harness claude writes a launchable transcript" {
  local cwd="$BATS_TEST_TMPDIR/project"
  mkdir -p "$cwd"

  run sessions new claude-smoke --cwd "$cwd" --harness claude --meta agent.name=knack
  [ "$status" -eq 0 ]
  local session_id="${lines[0]}"

  local encoded expected
  encoded=$(harness_claude_encode_cwd "$(cd "$cwd" && pwd -P)")
  expected="$CLAUDE_DIR/projects/$encoded/${session_id}.jsonl"
  [ -f "$expected" ]

  # Line 1 is our own header, deliberately pi-shaped so `sessions meta`,
  # wake's id/name reads and name lookup work with no branching.
  run jq -r 'select(.type == "session") | "\(.id) \(.name) \(.meta.agent.name)"' "$expected"
  [ "$output" = "$session_id claude-smoke knack" ]

  run jq -r 'select(.type == "harness") | .name' "$expected"
  [ "$output" = "claude" ]

  # Claude refuses to resume a transcript with no native message entry,
  # so new seeds one.
  run jq -r 'select(.type == "user") | "\(.isMeta) \(.sessionId)"' "$expected"
  [ "$output" = "true $session_id" ]
}

@test "new --harness claude injects context as a claude-native user entry" {
  local cwd="$BATS_TEST_TMPDIR/project"
  mkdir -p "$cwd"

  run sessions new ctx --cwd "$cwd" --harness claude --context "read the queue"
  [ "$status" -eq 0 ]
  local session_id="${lines[0]}"
  local session_file
  session_file=$(harness_claude_find_session "$session_id")

  # The injected message must be claude-shaped, or the model never sees
  # it: full uuid, chained onto the seed entry, and not marked isMeta.
  run jq -r 'select(.type == "user" and .isMeta == false) | .message.content' "$session_file"
  [ "$output" = "read the queue" ]

  local seed_uuid parent_uuid
  seed_uuid=$(jq -r 'select(.type == "user" and .isMeta == true) | .uuid' "$session_file")
  parent_uuid=$(jq -r 'select(.type == "user" and .isMeta == false) | .parentUuid' "$session_file")
  [ "$parent_uuid" = "$seed_uuid" ]
}

@test "user_message_entry needs the session file" {
  run harness_claude_user_message_entry id parent 2026-04-01T10:00:00.000Z "text"
  [ "$status" -eq 1 ]
  [[ "$output" == *"needs the session file"* ]]
}

# --- Lookup ---

@test "find_session matches by uuid prefix and by name" {
  local cwd="$BATS_TEST_TMPDIR/project"
  mkdir -p "$cwd"
  run sessions new findable --cwd "$cwd" --harness claude
  [ "$status" -eq 0 ]
  local session_id="${lines[0]}"

  run harness_claude_find_session "${session_id:0:8}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"${session_id}.jsonl" ]]

  run harness_claude_find_session findable
  [ "$status" -eq 0 ]
  [[ "$output" == *"${session_id}.jsonl" ]]
}

@test "find_session reports no match without claiming an error" {
  run harness_claude_find_session nothing-here
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "find_session reports within-adapter ambiguity" {
  local dir="$CLAUDE_DIR/projects/-dup"
  mkdir -p "$dir"
  printf '%s\n' '{"type":"session","version":3,"id":"11111111-aaaa","timestamp":"t","cwd":"/x","name":"dup"}' > "$dir/11111111-aaaa.jsonl"
  printf '%s\n' '{"type":"session","version":3,"id":"22222222-bbbb","timestamp":"t","cwd":"/x","name":"dup"}' > "$dir/22222222-bbbb.jsonl"

  run harness_claude_find_session dup
  [ "$status" -eq 2 ]
  [[ "$output" == *"Ambiguous"* ]]
}

# --- Launch argv ---

@test "interactive_argv resumes the session and translates the model" {
  local cwd="$BATS_TEST_TMPDIR/project"
  mkdir -p "$cwd"
  run sessions new argv --cwd "$cwd" --harness claude
  [ "$status" -eq 0 ]
  local session_id="${lines[0]}"
  local session_file
  session_file=$(harness_claude_find_session "$session_id")

  harness_claude_interactive_argv \
    /usr/bin/claude anthropic/claude-opus-5 "" "$session_file" "" approve true true true
  [ "${HARNESS_INTERACTIVE_ARGV[0]}" = "/usr/bin/claude" ]
  [ "${HARNESS_INTERACTIVE_ARGV[1]}" = "--model" ]
  [ "${HARNESS_INTERACTIVE_ARGV[2]}" = "claude-opus-5" ]
  [ "${HARNESS_INTERACTIVE_ARGV[3]}" = "--resume" ]
  [ "${HARNESS_INTERACTIVE_ARGV[4]}" = "$session_id" ]
}

@test "interactive_argv passes prompt text, disables skills, and guards the message" {
  local cwd="$BATS_TEST_TMPDIR/project"
  mkdir -p "$cwd"
  run sessions new argv2 --cwd "$cwd" --harness claude
  local session_id="${lines[0]}"
  local session_file
  session_file=$(harness_claude_find_session "$session_id")

  local prompt="$BATS_TEST_TMPDIR/prompt.md"
  echo "You are knack." > "$prompt"

  harness_claude_interactive_argv \
    /usr/bin/claude anthropic/opus "$prompt" "$session_file" "-not-a-flag" deny true false true

  local argv
  argv=$(printf '%s\n' "${HARNESS_INTERACTIVE_ARGV[@]}")
  # claude takes prompt text, not a path.
  [[ "$argv" == *"You are knack."* ]]
  [[ "$argv" != *"$prompt"* ]]
  [[ "$argv" == *"--safe-mode"* ]]
  [[ "$argv" == *"--disable-slash-commands"* ]]

  # `--` keeps a message that starts with a dash out of flag parsing.
  local last=$(( ${#HARNESS_INTERACTIVE_ARGV[@]} - 1 ))
  [ "${HARNESS_INTERACTIVE_ARGV[$last]}" = "-not-a-flag" ]
  [ "${HARNESS_INTERACTIVE_ARGV[$((last - 1))]}" = "--" ]
}

@test "interactive_argv reports UNSUPPORTED for flags claude has no honest mapping for" {
  run harness_claude_interactive_argv \
    /usr/bin/claude anthropic/opus "" "" "" inherit false true true
  [ "$status" -eq "$HARNESS_UNSUPPORTED_EXIT" ]

  run harness_claude_interactive_argv \
    /usr/bin/claude anthropic/opus "" "" "" inherit true true false
  [ "$status" -eq "$HARNESS_UNSUPPORTED_EXIT" ]
}

# --- End to end through the tasks ---

@test "wake launches claude against the session it created" {
  local cwd="$BATS_TEST_TMPDIR/project"
  mkdir -p "$cwd"
  local expected_cwd
  expected_cwd=$(cd "$cwd" && pwd -P)

  run sessions new e2e --cwd "$cwd" --harness claude
  [ "$status" -eq 0 ]
  local session_id="${lines[0]}"

  local stub_dir="$BATS_TEST_TMPDIR/stub"
  local argv_capture="$BATS_TEST_TMPDIR/argv"
  local cwd_capture="$BATS_TEST_TMPDIR/cwd"
  stub_claude_capture_argv_cwd "$stub_dir" "$argv_capture" "$cwd_capture"

  PATH="$stub_dir:$PATH" run sessions wake e2e \
    --model anthropic/claude-opus-5 \
    --message "read the queue"
  [ "$status" -eq 0 ]

  [ "$(cat "$cwd_capture")" = "$expected_cwd" ]
  run cat "$argv_capture"
  [[ "$output" == *"--resume"* ]]
  [[ "$output" == *"$session_id"* ]]
  [[ "$output" == *"claude-opus-5"* ]]
  [[ "$output" == *"read the queue"* ]]

  # The wake is recorded in the same transcript claude just read.
  local session_file
  session_file=$(harness_claude_find_session "$session_id")
  run jq -r 'select(.type == "wake") | "\(.harness) \(.model)"' "$session_file"
  [ "$output" = "claude anthropic/claude-opus-5" ]
}

@test "headless wake stays UNSUPPORTED until the claude run engine lands" {
  local cwd="$BATS_TEST_TMPDIR/project"
  mkdir -p "$cwd"
  run sessions new headless --cwd "$cwd" --harness claude
  [ "$status" -eq 0 ]

  local stub_dir="$BATS_TEST_TMPDIR/stub"
  local argv_capture="$BATS_TEST_TMPDIR/argv"
  local cwd_capture="$BATS_TEST_TMPDIR/cwd"
  stub_claude_capture_argv_cwd "$stub_dir" "$argv_capture" "$cwd_capture"

  PATH="$stub_dir:$PATH" run sessions wake headless \
    --headless \
    --model anthropic/claude-opus-5 \
    --message "do the thing"
  [ "$status" -ne 0 ]
  # The Elixir command builder is step 5. Until it lands the failure has
  # to name the harness and the operation rather than looking like a
  # crash, and nothing may be launched.
  [[ "$output" == *"'claude' harness does not support 'build_command' yet"* ]]
  [ ! -f "$argv_capture" ]
}

# --- Python read surface (location and lookup only; step 5 owns the rest) ---

@test "read locates a claude session and names the unsupported operation" {
  local cwd="$BATS_TEST_TMPDIR/project"
  mkdir -p "$cwd"
  run sessions new readable --cwd "$cwd" --harness claude
  [ "$status" -eq 0 ]
  local session_id="${lines[0]}"

  # Lookup has to succeed, or the tool reports a session that plainly
  # exists as missing. Normalization is still UNSUPPORTED, and that has
  # to read as the documented clean error rather than a traceback.
  run sessions read "${session_id:0:8}"
  [ "$status" -ne 0 ]
  [[ "$output" == *"'claude' harness does not support"* ]]
  [[ "$output" != *"No session matching"* ]]
  [[ "$output" != *"Traceback"* ]]
}

@test "read finds a claude session by name too" {
  local cwd="$BATS_TEST_TMPDIR/project"
  mkdir -p "$cwd"
  run sessions new by-name --cwd "$cwd" --harness claude
  [ "$status" -eq 0 ]

  run sessions read by-name
  [ "$status" -ne 0 ]
  [[ "$output" == *"'claude' harness does not support"* ]]
  [[ "$output" != *"No session matching"* ]]
}
