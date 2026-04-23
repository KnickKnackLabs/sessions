#!/usr/bin/env bash
# Pi harness adapter for sessions.
#
# This file is the authoritative home for pi-specific knowledge:
#   - Where pi stores sessions on disk
#   - How pi encodes paths into directory names
#   - Pi's JSONL entry schema (session header, model_change, message, wake)
#
# Step 1 of multi-harness support (sessions#50): pure extraction, no
# behavior change. Other harnesses will live in sibling files
# (lib/harness/claude.sh, etc.) and a dispatcher (step 2) will route
# commands based on session metadata.
#
# All functions are prefixed `harness_pi_` to keep the namespace clean
# when dispatched from a generic harness loader.
#
# Usage (from task scripts, where $MISE_CONFIG_ROOT is set by mise):
#   source "$MISE_CONFIG_ROOT/lib/harness/pi.sh"

# --- Location ---

# Print the absolute path of pi's sessions root.
# Honours $PI_DIR for test isolation; defaults to ~/.pi.
harness_pi_sessions_dir() {
  local pi_dir="${PI_DIR:-$HOME/.pi}"
  echo "$pi_dir/agent/sessions"
}

# Encode an absolute cwd into pi's project directory name.
# Pi uses double-dash bookends: /Users/foo/bar -> --Users-foo-bar--
harness_pi_encode_cwd() {
  local cwd_abs="$1"
  local encoded
  encoded=$(echo "$cwd_abs" | sed 's|/|-|g')
  echo "-${encoded}-"
}

# Print the full path for a new pi session file, creating the project dir.
# Filename format: <timestamp-with-colons-as-dashes>_<session-uuid>.jsonl
harness_pi_session_file_path() {
  local cwd_abs="$1"
  local session_id="$2"
  local now_iso="$3"

  local sessions_dir project_dir now_file
  sessions_dir=$(harness_pi_sessions_dir)
  project_dir="$sessions_dir/$(harness_pi_encode_cwd "$cwd_abs")/"
  mkdir -p "$project_dir"

  now_file=$(echo "$now_iso" | sed 's/:/-/g')
  echo "${project_dir}${now_file}_${session_id}.jsonl"
}

# --- Lookup ---

# Find a pi session file by UUID prefix or session name.
#
# Contract (shared across adapters — see `lib/find.sh` for the
# aggregator):
#   - Exit 0 + path on stdout  → unique match
#   - Exit 1 + empty output    → no match (the aggregator owns the
#     final "not found" message; missing sessions dir is treated as
#     "no match" since other adapters may have sessions)
#   - Exit 2 + stderr message  → within-adapter ambiguity (hard error;
#     aggregator propagates)
#
# Real failures (permission denied, corrupt filesystem) are not caught
# here — bash's normal non-zero exit from the underlying command
# surfaces.
harness_pi_find_session() {
  local query="$1"
  local sessions_dir
  sessions_dir=$(harness_pi_sessions_dir)

  if [ ! -d "$sessions_dir" ]; then
    return 1
  fi

  local id_matches=()
  local name_matches=()

  for project_dir in "$sessions_dir"/*/; do
    for jsonl in "$project_dir"*.jsonl; do
      [ -f "$jsonl" ] || continue
      local basename
      basename=$(basename "$jsonl" .jsonl)

      local uuid_part
      if [[ "$basename" == *_* ]]; then
        uuid_part="${basename##*_}"
      else
        uuid_part="$basename"
      fi
      if [[ "$uuid_part" == "$query"* ]]; then
        id_matches+=("$jsonl")
        continue
      fi

      local name
      name=$(head -1 "$jsonl" | jq -r '.name // empty' 2>/dev/null)
      if [ -n "$name" ] && [ "$name" = "$query" ]; then
        name_matches+=("$jsonl")
      fi
    done
  done

  local matches=()
  if [ ${#id_matches[@]} -gt 0 ]; then
    matches=("${id_matches[@]}")
  elif [ ${#name_matches[@]} -gt 0 ]; then
    matches=("${name_matches[@]}")
  fi

  case ${#matches[@]} in
    0)
      return 1
      ;;
    1)
      echo "${matches[0]}"
      return 0
      ;;
    *)
      echo "Error: Ambiguous query '$query' matches multiple pi sessions:" >&2
      printf '  %s\n' "${matches[@]}" >&2
      return 2
      ;;
  esac
}

# --- Entry builders ---
#
# Each function prints a single JSONL entry to stdout. Callers append
# to the session file. Entries match pi's on-disk schema; any changes
# here must stay synchronised with pi itself.

# Session header entry (first line of every session file).
#   $1 session_id, $2 timestamp_iso, $3 cwd_abs, $4 name (optional),
#   $5 meta_json (optional, "{}" or "" for none)
harness_pi_header_entry() {
  local session_id="$1"
  local ts="$2"
  local cwd_abs="$3"
  local name="${4:-}"
  local meta_json="${5:-}"

  local args=(
    --arg id "$session_id"
    --arg ts "$ts"
    --arg cwd "$cwd_abs"
  )
  local expr='{type: "session", version: 3, id: $id, timestamp: $ts, cwd: $cwd}'

  if [ -n "$name" ]; then
    args+=(--arg name "$name")
    expr="$expr + {name: \$name}"
  fi

  if [ -n "$meta_json" ] && [ "$meta_json" != "{}" ]; then
    args+=(--argjson meta "$meta_json")
    expr="$expr + {meta: \$meta}"
  fi

  jq -nc "${args[@]}" "$expr"
}

# Model change entry.
#   $1 entry_id, $2 timestamp_iso, $3 model_id
harness_pi_model_change_entry() {
  local entry_id="$1"
  local ts="$2"
  local model="$3"

  jq -nc \
    --arg id "$entry_id" \
    --arg ts "$ts" \
    --arg model "$model" \
    '{
      type: "model_change",
      id: $id,
      parentId: null,
      timestamp: $ts,
      provider: "anthropic",
      modelId: $model
    }'
}

# User message entry (used for context injection at new/wake time).
#   $1 entry_id, $2 parent_id, $3 timestamp_iso, $4 text
harness_pi_user_message_entry() {
  local entry_id="$1"
  local parent_id="$2"
  local ts="$3"
  local text="$4"

  jq -nc \
    --arg id "$entry_id" \
    --arg parent_id "$parent_id" \
    --arg ts "$ts" \
    --arg content "$text" \
    '{
      type: "message",
      id: $id,
      parentId: $parent_id,
      timestamp: $ts,
      message: {
        role: "user",
        content: [{ type: "text", text: $content }]
      }
    }'
}

