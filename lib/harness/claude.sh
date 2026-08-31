#!/usr/bin/env bash
# Claude Code harness adapter for sessions (step 4: new + wake).
#
# This file is the authoritative home for claude-specific knowledge:
#   - Where Claude Code stores transcripts on disk
#   - How it encodes a cwd into a project directory name
#   - The entry shape it will accept from us
#   - How to launch it interactively against an existing transcript
#
# Design: sessions writes its own entries (session header, harness,
# wake, system_prompt, process_*) into Claude Code's own transcript.
# Claude ignores line types it does not know — its own files already
# carry a dozen of them (mode, ai-title, atis-latch, pr-link, ...) —
# so one file serves both tools and every generic task keeps working.
#
# Three behaviours were established against claude 2.1.x and are load
# bearing here. Re-check them if a claude upgrade breaks this adapter:
#
#   1. Foreign line types survive a resume. Claude reads the
#      transcript, appends to it, and leaves our lines alone.
#   2. `--session-id <uuid>` refuses a file that already exists
#      ("Session ID ... is already in use") without truncating it.
#      Since `sessions new` creates the file, launches always use
#      `--resume <uuid>`, never `--session-id`.
#   3. `--resume` needs at least one claude-native message entry in
#      the file, or it reports "No conversation found". `sessions new`
#      therefore seeds one (see harness_claude_seed_entries). A
#      minimal entry is enough: no version, userType, entrypoint or
#      gitBranch field is required.
#
# Step 5 (headless `sessions run` via `claude -p --output-format
# stream-json`) lives in cli/lib/harness/claude.ex and is still
# UNSUPPORTED — a headless wake fails fast and cleanly.
#
# Usage (from task scripts, where $MISE_CONFIG_ROOT is set by mise):
#   source "$MISE_CONFIG_ROOT/lib/harness/claude.sh"

# --- Launch policy ---

# Resolve Claude Code while Sessions' own mise tool context is still
# active, exactly as the pi adapter does.
harness_claude_executable() {
  local sessions_root="${1:-}"
  local executable

  if [ -z "$sessions_root" ] || [ ! -d "$sessions_root" ]; then
    echo "Error: Sessions root is required to resolve the claude executable" >&2
    return 1
  fi

  if ! executable=$(mise -C "$sessions_root" which claude); then
    echo "Error: Sessions-owned claude executable is unavailable" >&2
    return 1
  fi

  case "$executable" in
    /*) ;;
    *)
      echo "Error: Sessions-owned claude executable is not an absolute path: $executable" >&2
      return 1
      ;;
  esac

  if [ ! -x "$executable" ]; then
    echo "Error: Sessions-owned claude executable is not executable: $executable" >&2
    return 1
  fi

  printf '%s\n' "$executable"
}

# Translate Sessions' generic one-run project trust policy to claude flags.
#
# `deny` maps to --safe-mode, which disables project-local
# customizations (CLAUDE.md, skills, plugins, hooks, MCP servers,
# custom commands and agents) — the closest analogue to pi's
# --no-approve.
#
# `approve` is a deliberate no-op, not an oversight: Claude Code has no
# pre-trust flag. It trusts the project by default and skips the
# workspace-trust dialog entirely under --print. Returning UNSUPPORTED
# here instead would fail every wake from `shimmer agent`, which passes
# --project-trust approve on every launch.
harness_claude_project_trust_flag() {
  case "${1:-}" in
    inherit|approve)
      return 0
      ;;
    deny)
      echo "--safe-mode"
      ;;
    *)
      echo "Error: unknown project trust policy: ${1:-}" >&2
      return 2
      ;;
  esac
}

# Translate a Sessions provider-qualified model into claude's own
# vocabulary. Sessions requires `provider/model`; claude wants a bare
# alias ("opus") or full name ("claude-opus-5").
harness_claude_model_arg() {
  local model="${1:-}"

  case "$model" in
    anthropic/*)
      printf '%s\n' "${model#anthropic/}"
      ;;
    claude-code/*)
      printf '%s\n' "${model#claude-code/}"
      ;;
    */*)
      echo "Error: the claude harness cannot run model '$model'" >&2
      echo "  Expected anthropic/<model> or claude-code/<model>" >&2
      return 1
      ;;
    "")
      echo "Error: model is required" >&2
      return 1
      ;;
    *)
      # Bare model name. The tasks reject these before we are called;
      # accepted here so the adapter stays usable on its own.
      printf '%s\n' "$model"
      ;;
  esac
}

# Print the claude session UUID recorded in a session file's header.
harness_claude_session_id() {
  local session_file="$1"
  local session_id

  session_id=$(head -1 "$session_file" 2>/dev/null |
    jq -r 'select(.type == "session") | .id // empty' 2>/dev/null)

  if [ -z "$session_id" ]; then
    echo "Error: no session header found in $session_file" >&2
    return 1
  fi

  printf '%s\n' "$session_id"
}

# Build the interactive launch argv. Populates the global array
# `HARNESS_INTERACTIVE_ARGV` — see harness_pi_interactive_argv for why
# adapters set a global instead of printing an argv.
#
#   $1 executable, $2 model, $3 system_prompt_file (may be empty),
#   $4 session file (may be empty), $5 message (may be empty),
#   $6 project trust policy, $7 extensions ("true"/"false"),
#   $8 skills, $9 prompt templates
harness_claude_interactive_argv() {
  local executable="$1"
  local model="$2"
  local system_prompt_file="$3"
  local session="$4"
  local message="$5"
  local project_trust="$6"
  local extensions="$7"
  local skills="$8"
  local prompt_templates="$9"

  # pi's extensions and prompt templates have no honest one-to-one
  # claude equivalent. --strict-mcp-config or --safe-mode would each
  # disable more than the caller asked for, so say so instead of
  # guessing.
  if [ "$extensions" != "true" ] || [ "$prompt_templates" != "true" ]; then
    harness_unsupported
    return
  fi

  local model_arg trust_flag
  model_arg=$(harness_claude_model_arg "$model") || return 1
  trust_flag=$(harness_claude_project_trust_flag "$project_trust") || return $?

  local args=(--model "$model_arg")
  [ -n "$trust_flag" ] && args+=("$trust_flag")
  [ "$skills" = "true" ] || args+=(--disable-slash-commands)

  # claude takes prompt text, not a path. Passing the contents keeps us
  # off the undocumented --append-system-prompt-file flag.
  if [ -n "$system_prompt_file" ]; then
    args+=(--append-system-prompt "$(cat "$system_prompt_file")")
  fi

  if [ -n "$session" ]; then
    local session_id
    session_id=$(harness_claude_session_id "$session") || return 1
    args+=(--resume "$session_id")
  fi

  # `--` so a message beginning with a dash is not parsed as a flag.
  if [ -n "$message" ]; then
    args+=(-- "$message")
  fi

  HARNESS_INTERACTIVE_ARGV=("$executable" ${args[@]+"${args[@]}"})
}

# --- Location ---

# Print the absolute path of claude's transcript root.
# Honours $CLAUDE_DIR for test isolation; defaults to ~/.claude.
harness_claude_sessions_dir() {
  local claude_dir="${CLAUDE_DIR:-$HOME/.claude}"
  echo "${claude_dir%/}/projects"
}

# Encode an absolute cwd into claude's project directory name.
#
# Claude replaces every character outside [A-Za-z0-9-] with a dash and
# collapses nothing, so `/tmp/a.b_c/Work` becomes `-tmp-a-b-c-Work`.
# Note the difference from pi, which uses double-dash bookends.
harness_claude_encode_cwd() {
  local cwd_abs="$1"
  printf '%s' "$cwd_abs" | LC_ALL=C tr -c 'A-Za-z0-9-' '-'
  echo
}

# Print the full path for a new claude session file, creating the
# project dir. Filename is the bare session UUID — unlike pi, claude
# puts no timestamp in the name.
harness_claude_session_file_path() {
  local cwd_abs="$1"
  local session_id="$2"
  # $3 (now_iso) is unused: claude's filenames carry no timestamp.

  local sessions_dir project_dir
  sessions_dir=$(harness_claude_sessions_dir)
  project_dir="$sessions_dir/$(harness_claude_encode_cwd "$cwd_abs")/"
  mkdir -p "$project_dir"

  echo "${project_dir}${session_id}.jsonl"
}

# --- Lookup ---

# Find a claude session file by UUID prefix or session name.
#
# Contract matches pi's: stdout = match path, exit 0 = unique match,
# exit 1 = no match, exit 2 = within-adapter ambiguity. Name lookup
# works because `sessions new` writes our own session header as the
# first line (see harness_claude_header_entry).
harness_claude_find_session() {
  local query="$1"
  local sessions_dir
  sessions_dir=$(harness_claude_sessions_dir)

  if [ ! -d "$sessions_dir" ]; then
    return 1
  fi

  local id_matches=()
  local name_matches=()

  for project_dir in "$sessions_dir"/*/; do
    for jsonl in "$project_dir"*.jsonl; do
      [ -f "$jsonl" ] || continue
      local uuid_part
      uuid_part=$(basename "$jsonl" .jsonl)

      if [[ "$uuid_part" == "$query"* ]]; then
        id_matches+=("$jsonl")
        continue
      fi

      local name
      name=$(head -1 "$jsonl" | jq -r 'select(.type == "session") | .name // empty' 2>/dev/null)
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
      echo "Error: Ambiguous query '$query' matches multiple claude sessions:" >&2
      printf '  %s\n' "${matches[@]}" >&2
      return 2
      ;;
  esac
}

# --- Entry builders ---

# Session header entry (first line of every session file).
#
# Deliberately the same shape pi writes. Claude ignores it, and in
# exchange `sessions meta`, `sessions wake`'s id/name reads and
# name-based lookup all work against claude sessions with no
# per-harness branching.
#
#   $1 session_id, $2 timestamp_iso, $3 cwd_abs, $4 name (optional),
#   $5 meta_json (optional, "{}" or "" for none)
harness_claude_header_entry() {
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
  # shellcheck disable=SC2016  # jq expression: $id, $ts, $cwd are jq variables bound by --arg, not bash expansions
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

# Extra entries a new session needs before it can be launched.
#
# Claude refuses to resume a transcript with no native message entry,
# so seed one. It is marked isMeta because it is bookkeeping rather
# than something the owner said; the model still sees it.
#
#   $1 session_id, $2 timestamp_iso, $3 cwd_abs
harness_claude_seed_entries() {
  local session_id="$1"
  local ts="$2"
  local cwd_abs="$3"

  harness_claude_native_user_entry \
    "$session_id" "$ts" "$cwd_abs" "" true \
    "Session created by sessions. Wait for the first instruction."
}

# Model change entry. Claude records the active model in its own
# entries; sessions has no reason to write one.
harness_claude_model_change_entry() {
  harness_unsupported
}

# User message entry (context injection at new/wake time).
#
# This one has to be claude-native, or the injected context never
# reaches the model. `$1` (entry id) and `$2` (parent id) are the
# sessions-side 8-character ids; claude's schema uses full UUIDs in
# `uuid`/`parentUuid`, so they are ignored and the parent is chained
# from the transcript instead. The trailing session-file argument is
# how the adapter recovers the session id and cwd claude requires.
#
#   $1 entry_id (ignored), $2 parent_id (ignored), $3 timestamp_iso,
#   $4 text, $5 session_file
harness_claude_user_message_entry() {
  local ts="$3"
  local text="$4"
  local session_file="${5:-}"

  if [ -z "$session_file" ] || [ ! -f "$session_file" ]; then
    echo "Error: the claude harness needs the session file to build a user message" >&2
    return 1
  fi

  local header session_id cwd_abs parent_uuid
  header=$(head -1 "$session_file")
  session_id=$(printf '%s' "$header" | jq -r 'select(.type == "session") | .id // empty')
  cwd_abs=$(printf '%s' "$header" | jq -r 'select(.type == "session") | .cwd // empty')

  if [ -z "$session_id" ]; then
    echo "Error: no session header found in $session_file" >&2
    return 1
  fi

  # Chain onto claude's own most recent entry when there is one.
  parent_uuid=$(jq -r 'select(.uuid) | .uuid' "$session_file" 2>/dev/null | tail -1)

  harness_claude_native_user_entry \
    "$session_id" "$ts" "$cwd_abs" "$parent_uuid" false "$text"
}

# Build one claude-native user entry.
#
# The field set is the minimum claude accepts on resume; version,
# userType, entrypoint and gitBranch are all optional and are left out
# so the adapter does not have to track claude's release format.
#
#   $1 session_id, $2 timestamp_iso, $3 cwd_abs, $4 parent_uuid (may be
#   empty for null), $5 is_meta ("true"/"false"), $6 text
harness_claude_native_user_entry() {
  local session_id="$1"
  local ts="$2"
  local cwd_abs="$3"
  local parent_uuid="${4:-}"
  local is_meta="$5"
  local text="$6"

  local entry_uuid
  entry_uuid=$(uuidgen | tr '[:upper:]' '[:lower:]')

  local parent_json=null
  if [ -n "$parent_uuid" ]; then
    parent_json=$(jq -nc --arg p "$parent_uuid" '$p')
  fi

  local meta_json=false
  [ "$is_meta" = "true" ] && meta_json=true

  jq -nc \
    --arg uuid "$entry_uuid" \
    --argjson parent "$parent_json" \
    --arg ts "$ts" \
    --arg cwd "$cwd_abs" \
    --arg sid "$session_id" \
    --argjson is_meta "$meta_json" \
    --arg content "$text" \
    '{
      parentUuid: $parent,
      isSidechain: false,
      type: "user",
      message: { role: "user", content: $content },
      isMeta: $is_meta,
      uuid: $uuid,
      timestamp: $ts,
      cwd: $cwd,
      sessionId: $sid
    }'
}
