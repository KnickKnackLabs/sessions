#!/usr/bin/env bash
# Shared session-finding logic for bash tasks.
#
# Usage:
#   source "$MISE_CONFIG_ROOT/lib/find.sh"
#   SESSION_FILE=$(find_session_file "$query")
#
# Matches by UUID prefix first, then by session name in the JSONL header.
# Exits with error if no match or ambiguous.

find_session_file() {
  local query="$1"
  local sessions_dir
  local pi_dir="${PI_DIR:-$HOME/.pi}"
  sessions_dir="$pi_dir/agent/sessions"

  if [ ! -d "$sessions_dir" ]; then
    echo "Error: No sessions directory at $sessions_dir" >&2
    return 1
  fi

  local id_matches=()
  local name_matches=()

  for project_dir in "$sessions_dir"/*/; do
    for jsonl in "$project_dir"*.jsonl; do
      [ -f "$jsonl" ] || continue
      local basename
      basename=$(basename "$jsonl" .jsonl)

      # Match against UUID part of filename
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

      # Match against session name in header
      local name
      name=$(head -1 "$jsonl" | jq -r '.name // empty' 2>/dev/null)
      if [ -n "$name" ] && [ "$name" = "$query" ]; then
        name_matches+=("$jsonl")
      fi
    done
  done

  # ID matches take priority; fall back to name matches
  local matches=()
  if [ ${#id_matches[@]} -gt 0 ]; then
    matches=("${id_matches[@]}")
  elif [ ${#name_matches[@]} -gt 0 ]; then
    matches=("${name_matches[@]}")
  fi

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
      echo "Error: Ambiguous query '$query', matches:" >&2
      printf '  %s\n' "${matches[@]}" >&2
      return 1
      ;;
  esac
}
