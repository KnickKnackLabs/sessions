#!/usr/bin/env bash
# Shared environment preparation for launching an interactive harness
# directly from Bash tasks.

sessions_scrub_caller_pwd_env() {
  local name
  while IFS= read -r name; do
    case "$name" in
      CALLER_PWD|*_CALLER_PWD) unset "$name" ;;
    esac
  done < <(compgen -e)
}

sessions_scrub_task_env() {
  local name
  while IFS= read -r name; do
    case "$name" in
      MISE_*|usage_*) unset "$name" ;;
    esac
  done < <(compgen -e)
}

sessions_mise_data_dir() {
  if [ -n "${MISE_DATA_DIR:-}" ]; then
    echo "$MISE_DATA_DIR"
  elif [ -n "${XDG_DATA_HOME:-}" ]; then
    echo "$XDG_DATA_HOME/mise"
  elif [ -n "${HOME:-}" ]; then
    echo "$HOME/.local/share/mise"
  fi
}

sessions_sanitize_harness_path() {
  local data_dir
  data_dir=$(sessions_mise_data_dir)
  [ -n "$data_dir" ] || return 0

  local installs="$data_dir/installs"
  local shims="$data_dir/shims"
  local path_rest="${PATH:-}:"
  local entry new_path="" have_entry=false

  while [ -n "$path_rest" ]; do
    entry="${path_rest%%:*}"
    path_rest="${path_rest#*:}"

    case "$entry" in
      "$installs"/*) continue ;;
    esac

    if [ "$have_entry" = false ]; then
      new_path="$entry"
      have_entry=true
    else
      new_path="$new_path:$entry"
    fi
  done

  if [ -d "$shims" ]; then
    case ":$new_path:" in
      *":$shims:"*) ;;
      *)
        if [ "$have_entry" = true ]; then
          new_path="$shims:$new_path"
        else
          new_path="$shims"
        fi
        ;;
    esac
  fi

  export PATH="$new_path"
}

sessions_prepare_harness_env() {
  # PATH sanitization needs the caller's mise data location before the
  # task-scoped MISE_* variables are removed from the harness boundary.
  sessions_sanitize_harness_path
  sessions_scrub_caller_pwd_env
  sessions_scrub_task_env
}
