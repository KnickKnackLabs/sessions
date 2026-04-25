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
# Usage (from task scripts, where $MISE_CONFIG_ROOT is set by mise):
#   source "$MISE_CONFIG_ROOT/lib/harness/dispatch.sh"
#   name=$(harness_resolve --session "$SESSION_FILE" --flag "$HARNESS_FLAG")
#   source "$MISE_CONFIG_ROOT/lib/harness/$name.sh"

# Source guard — this file is sometimes sourced via two paths in the
# same shell (wake sources dispatch.sh directly, then sources find.sh
# which in turn re-sources dispatch.sh). Redefining functions is
# harmless but burns cycles; the guard skips the re-run.
[ -n "${_DISPATCH_SH_LOADED:-}" ] && return 0
_DISPATCH_SH_LOADED=1

# Self-locate: this file IS `lib/harness/dispatch.sh`, so its own
# directory is the harness lib dir. The env override (HARNESS_LIB_DIR)
# still wins — tests set it to point at test fixtures — but the
# fallback no longer depends on $MISE_CONFIG_ROOT, which can be
# polluted when libs are sourced from a test context (see
# KnickKnackLabs/codebase#16).
HARNESS_LIB_DIR="${HARNESS_LIB_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
HARNESS_DEFAULT="pi"

# --- UNSUPPORTED contract ---
#
# Adapters that don't (yet) implement a given operation signal so via a
# reserved exit code. Callers of adapter functions should go through
# `harness_call` (below), which turns the reserved code into a clean
# user-facing error and exits with the same code so wrapping scripts
# can branch on it. Mirrors `Unsupported` in `lib/harness/__init__.py`
# and `Cli.Harness.UnsupportedError` in `cli/lib/harness.ex`.
HARNESS_UNSUPPORTED_EXIT=10

# Adapter helper — use inside an adapter function to signal that this
# operation isn't supported by this harness. Writes nothing to stdout;
# the caller's `harness_call` wrapper owns the user-facing message.
harness_unsupported() {
  return "$HARNESS_UNSUPPORTED_EXIT"
}

# Call an adapter function with UNSUPPORTED handling.
#
# Usage: harness_call <harness> <fn_suffix> [args...]
#   e.g. harness_call pi header_entry "$id" "$ts" "$cwd"
#
# - Passes through stdout and stderr from the adapter function.
# - On the reserved UNSUPPORTED exit code, prints a clean message to
#   stderr and exits the current shell with the same code (so `set -e`
#   callers fail fast with a useful error).
# - Any other exit code is returned as-is; the caller can decide.
harness_call() {
  local harness="$1" fn_suffix="$2"
  shift 2
  local fn="harness_${harness}_${fn_suffix}"
  local rc=0
  "$fn" "$@" || rc=$?
  if [ "$rc" -eq "$HARNESS_UNSUPPORTED_EXIT" ]; then
    echo "sessions: '$harness' harness does not support '$fn_suffix' yet" >&2
    exit "$HARNESS_UNSUPPORTED_EXIT"
  fi
  return "$rc"
}

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
#
# Kept in sync with `lib/harness/__init__.py::_from_path` and
# `Cli.Harness.from_path/1` — review all three together when editing.
#
# Each prefix is normalised to end with `/` so `~/.pi-alt/...` does not
# get claimed by the pi adapter. $PI_DIR='' and $CLAUDE_DIR='' are
# treated as unset (not as `/`, which would match every absolute path).
harness_from_path() {
  local path="$1"
  [ -n "$path" ] || return 0

  local pi_dir="${PI_DIR:-$HOME/.pi}"
  pi_dir="${pi_dir%/}"
  case "$path" in
    "$pi_dir"/*|"$HOME"/.pi/*) echo "pi"; return 0 ;;
  esac

  local claude_dir="${CLAUDE_DIR:-$HOME/.claude}"
  claude_dir="${claude_dir%/}"
  case "$path" in
    "$claude_dir"/*|"$HOME"/.claude/*) echo "claude"; return 0 ;;
  esac

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
#   $8 meta_json (optional, "{}" or "" for none),
#   $9 model   (optional, "" for none — absence of `.model` on the
#              output signals "harness default was used". `wake_entry`
#              itself never writes null; readers processing wake events
#              from other sources should normalize null to absent.)
#
# Field-placement rule: fields that `sessions wake` itself owns
# (`.headless`, `.model`) go top-level; caller-provided key=value pairs
# passed via `--meta` go inside `.meta`. Apply this rule when adding
# new fields: if wake owns the flag, top-level; if it's user-space,
# stuff it into `meta_json` at the callsite.
#
# Schema-evolution risk: `.model` is written as a bare string in
# harness-native vocabulary (e.g. pi's "claude-opus-4-7"). Readers
# that consume wake events across harnesses must branch on `.harness`
# to interpret `.model` correctly. If per-harness model vocabularies
# diverge further (e.g. structured fields, different naming schemes),
# revisit: either namespace the field (`.harness_model`) or push it
# into a per-harness sub-object. Tracked as an open question on #61.
wake_entry() {
  local entry_id="$1"
  local parent_id="$2"
  local ts="$3"
  local shell_name="$4"
  local agent="$5"
  local harness_name="$6"
  local headless="$7"
  local meta_json="${8:-}"
  local model="${9:-}"

  # Intentionally strict: only the exact string "true" maps to true.
  # Any other value ("false", "", "TRUE", "yes", "1") maps to false.
  # Callers pass "$usage_headless" from the mise USAGE flag, which is
  # always "true" or the empty string — no need to be lenient here.
  local headless_bool=false
  [ "$headless" = "true" ] && headless_bool=true

  # `.model` is written only when explicitly provided. Absent means
  # "harness default was used"; readers can distinguish the two cases.
  # `"${arr[@]+"${arr[@]}"}"` is the nounset-safe empty-array expansion
  # (bash < 4.4 treats `"${empty[@]}"` as an unset reference under -u).
  local model_args=()
  local model_fragment=''
  if [ -n "$model" ]; then
    model_args=(--arg model "$model")
    model_fragment=' + {model: $model}'
  fi

  if [ -z "$meta_json" ] || [ "$meta_json" = "{}" ]; then
    jq -nc \
      --arg id "$entry_id" \
      --arg parent_id "$parent_id" \
      --arg ts "$ts" \
      --arg shell_name "$shell_name" \
      --arg agent "$agent" \
      --arg harness "$harness_name" \
      --argjson headless "$headless_bool" \
      "${model_args[@]+"${model_args[@]}"}" \
      '{
        type: "wake",
        id: $id,
        parentId: $parent_id,
        timestamp: $ts,
        shell: $shell_name,
        agent: $agent,
        harness: $harness,
        headless: $headless
      }'"$model_fragment"
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
      "${model_args[@]+"${model_args[@]}"}" \
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
      }'"$model_fragment"
  fi
}
