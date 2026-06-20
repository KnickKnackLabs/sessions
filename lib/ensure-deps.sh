#!/usr/bin/env bash
# Self-healing deps check for the sessions CLI.
#
# On a fresh shiv-sessions install (or after a manual `rm -rf cli/deps`),
# `cli/deps/` is empty and `mix sessions` refuses to start with an
# 'Unchecked dependencies' error. On CI, a restored deps cache can also
# exist before Hex has been installed in the runner's Mix home, which
# makes Mix unable to resolve Hex-backed dependencies.
#
# This helper installs Hex when needed, then asks Mix whether dependency
# load paths are usable. It fetches deps lazily only when that cheap
# no-compile check fails.
#
# See KnickKnackLabs/sessions#53 and KnickKnackLabs/sessions#111 for the rationale.

ensure_mix_hex() {
  local cli_dir="$1"

  if ! (
    cd "$cli_dir" || exit 1
    mix local.hex --force --if-missing >&2
  ); then
    echo "sessions: failed to install Hex package manager." >&2
    echo "  try: mix local.hex --force --if-missing   (in $cli_dir)" >&2
    return 1
  fi
}

cli_deps_ready() {
  local cli_dir="$1"

  (
    cd "$cli_dir" || exit 1
    mix deps.loadpaths --no-compile >/dev/null 2>&1
  )
}

# ensure_cli_deps <cli_dir>
#
# Returns:
#   0 — deps are already usable, or were just fetched successfully.
#   1 — setup/fetch/readiness failed; an actionable hint is emitted to stderr.
#   2 — programmer error (missing arg, or <cli_dir> does not exist).
ensure_cli_deps() {
  local cli_dir="${1:-}"

  if [ -z "$cli_dir" ]; then
    echo "ensure_cli_deps: cli_dir argument required" >&2
    return 2
  fi

  if [ ! -d "$cli_dir" ]; then
    echo "ensure_cli_deps: cli dir does not exist: $cli_dir" >&2
    return 2
  fi

  ensure_mix_hex "$cli_dir" || return 1

  if cli_deps_ready "$cli_dir"; then
    return 0
  fi

  echo "sessions: first-run setup — fetching Elixir dependencies…" >&2
  (
    cd "$cli_dir" || exit 1
    mix deps.get >&2 || exit 1
  ) || {
    echo "sessions: failed to fetch dependencies." >&2
    echo "  try: mise run cli:build   (in $cli_dir)" >&2
    return 1
  }

  if ! cli_deps_ready "$cli_dir"; then
    echo "sessions: dependencies were fetched but are still not loadable." >&2
    echo "  try: mise run cli:build   (in $cli_dir)" >&2
    return 1
  fi

  return 0
}
