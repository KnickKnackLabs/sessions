#!/usr/bin/env bash
# Harness dispatch layer: registry, resolver, and the JSONL entries that
# belong to the sessions tool itself (not to any particular harness).
#
# Step 2 of multi-harness support (sessions#50). This file is harness-
# agnostic — it knows about the dispatch protocol, not about pi or claude
# specifically.
#
# A "harness" is an adapter (pi, claude, ...) that knows how to lay out
# sessions on disk, parse a harness's streaming output, and launch a
# process. Each adapter lives in `lib/harness/<name>.sh` (plus .py / .ex
# for the python and elixir surfaces).
#
# Two categories of JSONL entry live in our session files:
#
#   1. Harness-native entries (session header, model_change, message) —
#      their shape is dictated by what the harness binary reads/writes.
#      Builders for these live in `lib/harness/<name>.sh`.
#
#   2. Sessions-tool entries (wake, harness) — we invented them and the
#      harness binaries ignore them. Their shape is uniform across
#      adapters. Builders for these live here.
#
#
# Resolver priority (highest first):
#   1. Explicit flag on the invoking command (passed in)
#   2. Most recent {"type":"harness"} entry in the session JSONL
#   3. Path-based detection (session file under ~/.pi/... → pi, etc.)
#   4. $SESSIONS_DEFAULT_HARNESS environment variable
#   5. Compile-time default: "pi"
#
# Usage:
#   source "$MISE_CONFIG_ROOT/lib/harness/dispatch.sh"
#   name=$(harness_resolve --session "$SESSION_FILE" --flag "$HARNESS_FLAG")
#   source "$MISE_CONFIG_ROOT/lib/harness/$name.sh"

HARNESS_LIB_DIR="${HARNESS_LIB_DIR:-$MISE_CONFIG_ROOT/lib/harness}"
HARNESS_DEFAULT="pi"

# --- Registry ---

# List available harnesses (sorted, one per line). An adapter is
# considered available if `lib/harness/<name>.sh` exists.
harness_list() {
  local f
  for f in "$HARNESS_LIB_DIR"/*.sh; do
    [ -f "$f" ] || continue
    local base
    base=$(basename "$f" .sh)
    # dispatch.sh is the dispatcher itself, not an adapter.
    [ "$base" = "dispatch" ] && continue
    echo "$base"
  done | sort
}

# Return 0 if <name> is a known harness, non-zero otherwise.
harness_valid() {
  local name="$1"
  [ -n "$name" ] || return 1
  [ "$name" = "dispatch" ] && return 1
  [ -f "$HARNESS_LIB_DIR/$name.sh" ]
}

# --- Session-file introspection ---

# Print the most recent harness entry's name from a session JSONL file,
# or empty if no such entry is present. Never fails — missing/unreadable
# file returns empty.
harness_of_session() {
  local session_file="$1"
  [ -f "$session_file" ] || return 0
  jq -r 'select(.type == "harness") | .name // empty' "$session_file" 2>/dev/null | tail -1
}

# Path-based detection. Given a session file path, guess the harness
# from a path prefix. Prints the harness name or empty if no rule
# matches.
harness_from_path() {
  local path="$1"
  [ -n "$path" ] || return 0
  # Pi sessions live under ~/.pi/agent/sessions (or $PI_DIR/agent/sessions).
  # Strip any trailing slash so `PI_DIR=/opt/custom-pi/` still matches
  # `/opt/custom-pi/agent/sessions/...` (case pattern `//*` wouldn't).
  # `${PI_DIR:-...}` also protects against `PI_DIR=""` silently becoming
  # `/` — an empty value is treated the same as unset.
  local pi_dir="${PI_DIR:-$HOME/.pi}"
  pi_dir="${pi_dir%/}"
  case "$path" in
    "$pi_dir"/*|"$HOME"/.pi/*) echo "pi"; return 0 ;;
  esac
  # Future: ~/.claude/... → claude
  return 0
}

# --- Resolver ---

# Resolve the harness name using the priority stack. Prints the name on
# stdout; exits non-zero with a clean error on stderr if the result is
# invalid.
#
# Flags:
#   --session <file>   session JSONL path (for rules 2 and 3)
#   --flag <name>      explicit --harness flag from the caller (rule 1)
harness_resolve() {
  local session_file="" flag="" name=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --session) session_file="$2"; shift 2 ;;
      --flag)    flag="$2";         shift 2 ;;
      *) echo "harness_resolve: unknown arg '$1'" >&2; return 2 ;;
    esac
  done

  # 1. Explicit flag
  if [ -n "$flag" ]; then
    name="$flag"
  fi

  # 2. Most recent harness entry in the session file
  if [ -z "$name" ] && [ -n "$session_file" ]; then
    name=$(harness_of_session "$session_file")
  fi

  # 3. Path-based detection
  if [ -z "$name" ] && [ -n "$session_file" ]; then
    name=$(harness_from_path "$session_file")
  fi

  # 4. Env default
  if [ -z "$name" ]; then
    name="${SESSIONS_DEFAULT_HARNESS:-}"
  fi

  # 5. Compile-time default
  if [ -z "$name" ]; then
    name="$HARNESS_DEFAULT"
  fi

  if ! harness_valid "$name"; then
    echo "Error: unknown harness '$name'" >&2
    echo "Available: $(harness_list | paste -sd, -)" >&2
    return 1
  fi

  echo "$name"
}

# --- Entry builders (sessions-tool entries) ---

# Harness declaration entry — states that from this point forward the
# active harness is <name>. Written at `sessions new` and whenever a
# wake switches harnesses.
#
#   $1 entry_id, $2 parent_id, $3 timestamp_iso, $4 harness_name
harness_entry() {
  local entry_id="$1"
  local parent_id="$2"
  local ts="$3"
  local name="$4"

  jq -nc \
    --arg id "$entry_id" \
    --arg parent_id "$parent_id" \
    --arg ts "$ts" \
    --arg name "$name" \
    '{
      type: "harness",
      id: $id,
      parentId: $parent_id,
      timestamp: $ts,
      name: $name
    }'
}

# Wake event entry — records that an agent was woken into a session.
# Shape is uniform across harnesses: the harness binaries don't read
# this entry type; we own the schema.
#
#   $1 entry_id, $2 parent_id, $3 timestamp_iso, $4 shell_name,
#   $5 agent, $6 harness_name, $7 headless ("true" | "false"),
#   $8 meta_json (optional, "{}" or "" for none)
wake_entry() {
  local entry_id="$1"
  local parent_id="$2"
  local ts="$3"
  local shell_name="$4"
  local agent="$5"
  local harness_name="$6"
  local headless="$7"
  local meta_json="${8:-}"

  # Intentionally strict: only the exact string "true" maps to true.
  # Any other value ("false", "", "TRUE", "yes", "1") maps to false.
  # Callers pass "$usage_headless" from the mise USAGE flag, which is
  # always "true" or the empty string — no need to be lenient here.
  local headless_bool=false
  [ "$headless" = "true" ] && headless_bool=true

  if [ -z "$meta_json" ] || [ "$meta_json" = "{}" ]; then
    jq -nc \
      --arg id "$entry_id" \
      --arg parent_id "$parent_id" \
      --arg ts "$ts" \
      --arg shell_name "$shell_name" \
      --arg agent "$agent" \
      --arg harness "$harness_name" \
      --argjson headless "$headless_bool" \
      '{
        type: "wake",
        id: $id,
        parentId: $parent_id,
        timestamp: $ts,
        shell: $shell_name,
        agent: $agent,
        harness: $harness,
        headless: $headless
      }'
  else
    jq -nc \
      --arg id "$entry_id" \
      --arg parent_id "$parent_id" \
      --arg ts "$ts" \
      --arg shell_name "$shell_name" \
      --arg agent "$agent" \
      --arg harness "$harness_name" \
      --argjson headless "$headless_bool" \
      --argjson meta "$meta_json" \
      '{
        type: "wake",
        id: $id,
        parentId: $parent_id,
        timestamp: $ts,
        shell: $shell_name,
        agent: $agent,
        harness: $harness,
        headless: $headless,
        meta: $meta
      }'
  fi
}
