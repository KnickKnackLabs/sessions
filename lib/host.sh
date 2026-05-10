#!/usr/bin/env bash
# Shared host policy helpers for local OS-user session execution.

HOST_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOST_REPO_DIR="$(cd "$HOST_LIB_DIR/.." && pwd)"
HOST_HUMANS_GROUP="${SESSIONS_HUMANS_GROUP:-humans}"
HOST_AGENTS_GROUP="${SESSIONS_AGENTS_GROUP:-agents}"
HOST_SUDOERS_FILE="${SESSIONS_SUDOERS_FILE:-/etc/sudoers.d/sessions-humans-agents}"
HOST_RUN_AS_USER="${SESSIONS_RUN_AS_USER:-$HOST_REPO_DIR/libexec/run-as-user}"

host_user_exists() {
  id -u "$1" >/dev/null 2>&1
}

host_group_exists() {
  if command -v dscl >/dev/null 2>&1; then
    dscl . -read "/Groups/$1" >/dev/null 2>&1
  else
    getent group "$1" >/dev/null 2>&1
  fi
}

host_user_in_group() {
  local user="$1" group="$2"
  id -Gn "$user" 2>/dev/null | tr ' ' '\n' | grep -Fxq "$group"
}

host_sudoers_rule() {
  printf '%%%s ALL=(%%%s) NOPASSWD: ALL\n' "$HOST_HUMANS_GROUP" "$HOST_AGENTS_GROUP"
}

host_sudoers_exists() {
  [ -e "$HOST_SUDOERS_FILE" ]
}

host_sudoers_readable() {
  [ -r "$HOST_SUDOERS_FILE" ]
}

host_sudoers_installed() {
  host_sudoers_readable && grep -Fxq "$(host_sudoers_rule)" "$HOST_SUDOERS_FILE"
}

host_sudoers_valid() {
  host_sudoers_readable \
    && command -v visudo >/dev/null 2>&1 \
    && visudo -cf "$HOST_SUDOERS_FILE" >/dev/null 2>&1
}

host_run_as_user_smoke() {
  local user="$1"
  [ -x "$HOST_RUN_AS_USER" ] && "$HOST_RUN_AS_USER" --user "$user" -- true >/dev/null 2>&1
}

host_sudoers_needs_repair() {
  local user="$1"

  if ! host_sudoers_exists; then
    return 0
  fi

  if host_sudoers_readable; then
    ! host_sudoers_installed || ! host_sudoers_valid
    return $?
  fi

  ! host_run_as_user_smoke "$user"
}

host_create_group_command() {
  local group="$1"
  printf 'sudo dseditgroup -o create %q\n' "$group"
}

host_add_user_to_group_command() {
  local user="$1" group="$2"
  printf 'sudo dseditgroup -o edit -a %q -t user %q\n' "$user" "$group"
}

host_install_sudoers_commands() {
  local rule
  rule=$(host_sudoers_rule)
  printf "printf '%%s\\\\n' %q | sudo tee %q >/dev/null\n" "$rule" "$HOST_SUDOERS_FILE"
  printf 'sudo chmod 0440 %q\n' "$HOST_SUDOERS_FILE"
  printf 'sudo visudo -cf %q\n' "$HOST_SUDOERS_FILE"
}

host_validate_user_name() {
  local user="$1"
  if [ -z "$user" ]; then
    echo "Error: --os-user is required" >&2
    return 2
  fi
  if [[ "$user" == -* ]]; then
    echo "Error: --os-user value cannot start with a dash: '$user'" >&2
    return 2
  fi
  if ! [[ "$user" =~ ^[a-zA-Z_][a-zA-Z0-9._-]*[$]?$ ]]; then
    echo "Error: invalid --os-user value '$user'" >&2
    return 2
  fi
}
