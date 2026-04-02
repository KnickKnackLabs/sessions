#!/usr/bin/env bash
# Shared shell-name derivation for sessions tasks.
#
# Usage:
#   source "$MISE_CONFIG_ROOT/lib/shell.sh"
#   SHELL_NAME=$(derive_shell_name "$SESSION_NAME" "$SESSION_ID")
#
# The shell name is an implementation detail of the zmx layer.
# Sessions that have a human-readable name get a sanitized version;
# unnamed sessions use the first 8 chars of their UUID.

derive_shell_name() {
  local session_name="$1"
  local session_id="$2"
  if [ -n "$session_name" ]; then
    echo "$session_name" | sed 's|/|-|g; s|[^a-zA-Z0-9._-]|-|g'
  else
    echo "${session_id:0:8}"
  fi
}
