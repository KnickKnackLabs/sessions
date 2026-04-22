#!/usr/bin/env bash
# Harness-aware session lookup.
#
# `find_session_file <query>` scans each available harness adapter for a
# session matching <query> (UUID prefix or name). If exactly one adapter
# has a match, returns that path. If none match, errors. If multiple
# harnesses match, errors with an ambiguity message.
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

  local harness matches=() match err_msgs=()
  while IFS= read -r harness; do
    [ -z "$harness" ] && continue
    # shellcheck source=/dev/null
    source "$HARNESS_LIB_DIR/$harness.sh"

    # Each adapter's find function returns 0 + path on success, non-zero on
    # error. We capture stderr so per-adapter "no match" messages don't
    # spam the caller when another adapter did match.
    if match=$("harness_${harness}_find_session" "$query" 2>/dev/null); then
      matches+=("$match")
    fi
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
