#!/usr/bin/env bash
# Claude harness adapter for sessions (step 3 skeleton).
#
# This file is the authoritative home for claude-specific knowledge.
# At step 3 it's a skeleton: every function that depends on claude's
# on-disk layout or JSONL schema returns UNSUPPORTED. Step 4 (claude
# new + wake) will fill in the real behaviour.
#
# What's structural (not UNSUPPORTED) at step 3:
#   - harness_claude_find_session — the cross-adapter find aggregator
#     walks every registered adapter; UNSUPPORTED here would break
#     lookup for pi sessions. Returns "no match" unconditionally until
#     step 4 knows what to look at.
#
# Everything else (sessions_dir, encode_cwd, session_file_path, and
# the native entry builders) is UNSUPPORTED. `sessions new --harness
# claude` therefore fails fast at session_file_path — before any
# directory creation or file write — with a clean UNSUPPORTED message.
#
# Usage (from task scripts, where $MISE_CONFIG_ROOT is set by mise):
#   source "$MISE_CONFIG_ROOT/lib/harness/claude.sh"

# --- Location ---

harness_claude_sessions_dir() {
  harness_unsupported
}

harness_claude_encode_cwd() {
  harness_unsupported
}

harness_claude_session_file_path() {
  harness_unsupported
}

# --- Lookup ---

# Contract matches pi's: stdout = match path, exit 0 = unique match,
# exit 1 = no match, exit 2 = within-adapter ambiguity. Step 3 always
# returns "no match" — no claude sessions exist yet.
harness_claude_find_session() {
  return 1
}

# --- Entry builders ---

harness_claude_header_entry() {
  harness_unsupported
}

harness_claude_model_change_entry() {
  harness_unsupported
}

harness_claude_user_message_entry() {
  harness_unsupported
}
