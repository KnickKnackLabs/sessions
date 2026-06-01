#!/usr/bin/env bash
# Shared process-lifecycle helpers for bash tasks.

sessions_linux_proc_start_time_from_stat() {
  local stat_line="$1"
  local rest token
  local fields=()

  rest="${stat_line##*) }"
  [ "$rest" != "$stat_line" ] || return 1

  read -r -a fields <<< "$rest"
  [ "${#fields[@]}" -ge 20 ] || return 1

  token="${fields[19]}"
  case "$token" in
    ''|0|*[!0-9]*) return 1 ;;
  esac
  printf '%s\n' "$token"
}

sessions_process_start_time_token_once() {
  local pid="$1"
  local stat_line token

  if [ -r "/proc/$pid/stat" ]; then
    if stat_line=$(cat "/proc/$pid/stat" 2>/dev/null); then
      if token=$(sessions_linux_proc_start_time_from_stat "$stat_line"); then
        printf 'linux:%s\n' "$token"
        return 0
      fi
    fi
  fi

  if command -v ps >/dev/null 2>&1; then
    if token=$(ps -p "$pid" -o lstart= 2>/dev/null | awk '{$1=$1; print}'); then
      if [ -n "$token" ]; then
        printf 'ps:%s\n' "$token"
        return 0
      fi
    fi
  fi
}

sessions_process_start_time_token() {
  local pid="$1"
  local token=""
  local attempt
  for attempt in 1 2 3 4 5; do
    token=$(sessions_process_start_time_token_once "$pid")
    if [ -n "$token" ]; then
      printf '%s\n' "$token"
      return 0
    fi
    sleep 0.05
  done
}
