#!/usr/bin/env bash
# Self-healing deps check for the sessions CLI.
#
# On a fresh shiv-sessions install (or after a manual `rm -rf cli/deps`),
# `cli/deps/` is empty and `mix sessions` refuses to start with an
# 'Unchecked dependencies' error. This helper detects that case and
# runs `mix deps.get` on the fly.
#
# See KnickKnackLabs/sessions#53 for the rationale.

# ensure_cli_deps <cli_dir>
#
# Returns:
#   0 — deps are already populated, or were just fetched successfully.
#   1 — fetch failed; an actionable hint is emitted to stderr.
#   2 — programmer error (missing arg, or <cli_dir> does not exist).
ensure_cli_deps() {
  local cli_dir="$1"

  if [ -z "$cli_dir" ]; then
    echo "ensure_cli_deps: cli_dir argument required" >&2
    return 2
  fi

  if [ ! -d "$cli_dir" ]; then
    echo "ensure_cli_deps: cli dir does not exist: $cli_dir" >&2
    return 2
  fi

  # Populated-deps check: if any entry exists under deps/, we assume
  # deps have been fetched at least once. `mix` itself will handle
  # version drift (it re-fetches on `mix.lock` change). In practice
  # `mix deps.get` only creates subdirectories, but we check for any
  # entry so the code matches what `ls -A` actually reports.
  if [ -n "$(ls -A "$cli_dir/deps" 2>/dev/null)" ]; then
    return 0
  fi

  echo "sessions: first-run setup — fetching Elixir dependencies…" >&2
  (
    cd "$cli_dir" || exit 1
    mix local.hex --force --if-missing >&2 || exit 1
    mix deps.get >&2 || exit 1
  ) || {
    echo "sessions: failed to fetch dependencies." >&2
    echo "  try: mise run cli:build   (in $cli_dir)" >&2
    return 1
  }

  return 0
}
