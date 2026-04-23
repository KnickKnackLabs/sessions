#!/usr/bin/env bash
# Harness-aware session lookup.
#
# `find_session_file <query>` iterates over installed harness adapters
# and aggregates their matches.
#
# Adapter contract (see `lib/harness/pi.sh`):
#   exit 0 + path on stdout  → unique match
#   exit 1 + empty output    → no match (benign; try next adapter)
#   exit 2 + stderr message  → hard error (within-adapter ambiguity or
#                              actual failure); we surface and stop.
#
# Aggregator behaviour:
#   - Zero matches across all adapters → "No session matching..." (exit 1).
#   - Exactly one match → print it (exit 0).
#   - More than one match (across adapters) → cross-adapter ambiguity
#     message with all matches (exit 1).
#   - Any adapter exits 2 → surface its stderr and exit non-zero.
#
# Used by: .mise/tasks/wake (and anything else that sources this file).

# shellcheck source=/dev/null
source "$MISE_CONFIG_ROOT/lib/harness/dispatch.sh"

find_session_file() {
  local query="$1"
  if [ -z "$query" ]; then
    echo "Error: find_session_file: query required" >&2
    return 1
  fi

  local harness matches=() adapter_stderr adapter_rc match
  while IFS= read -r harness; do
    [ -z "$harness" ] && continue
    # shellcheck source=/dev/null
    source "$HARNESS_LIB_DIR/$harness.sh"

    # Capture adapter stdout (match path) and stderr (error details)
    # separately so we can distinguish "no match" from "hard error."
    local stderr_file
    stderr_file=$(mktemp)
    match=$("harness_${harness}_find_session" "$query" 2>"$stderr_file")
    adapter_rc=$?
    adapter_stderr=$(cat "$stderr_file")
    rm -f "$stderr_file"

    case "$adapter_rc" in
      0)
        matches+=("$match")
        ;;
      1)
        # No match for this adapter; continue.
        :
        ;;
      *)
        # Hard error (within-adapter ambiguity, corrupted state, etc.) —
        # surface and stop.
        if [ -n "$adapter_stderr" ]; then
          printf '%s\n' "$adapter_stderr" >&2
        else
          echo "Error: $harness adapter failed (exit $adapter_rc)" >&2
        fi
        return "$adapter_rc"
        ;;
    esac
  done < <(harness_list)

  case ${#matches[@]} in
    0)
      echo "Error: No session matching '$query'" >&2
      return 1
      ;;
    1)
      echo "${matches[0]}"
      return 0
      ;;
    *)
      echo "Error: Ambiguous query '$query', matches across harnesses:" >&2
      printf '  %s\n' "${matches[@]}" >&2
      return 1
      ;;
  esac
}
