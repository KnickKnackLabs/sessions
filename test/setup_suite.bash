#!/usr/bin/env bash

setup_suite() {
  REPO_DIR="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export REPO_DIR

  # Let direct `bats test/foo.bats` invocations load this repo's mise tool
  # environment instead of inheriting an agent launcher's PATH/MCR context.
  if [ -n "${MISE_TRUSTED_CONFIG_PATHS:-}" ]; then
    export MISE_TRUSTED_CONFIG_PATHS="$REPO_DIR:$MISE_TRUSTED_CONFIG_PATHS"
  else
    export MISE_TRUSTED_CONFIG_PATHS="$REPO_DIR"
  fi

  bats_libexec="${BATS_LIBEXEC:-}"
  eval "$(cd "$REPO_DIR" && mise env)"
  if [ -n "$bats_libexec" ]; then
    export PATH="$bats_libexec:$PATH"
  fi

  # Nested Mise activation can put installed tools ahead of PATH mocks.
  # Select guarded executables explicitly before any test can call a task.
  export SESSIONS_TEST_REAL_MISE
  SESSIONS_TEST_REAL_MISE=$(command -v mise)
  local guard_dir="$BATS_SUITE_TMPDIR/command-guards"
  mkdir -p "$guard_dir"
  local tool
  for tool in pi mix shell; do
    ln -s "$REPO_DIR/test/fixtures/blocked-command" "$guard_dir/$tool"
  done
  export SESSIONS_TEST_GUARD_LOG="$BATS_SUITE_TMPDIR/unmocked-commands.log"
  export SESSIONS_TEST_PI_EXECUTABLE="$guard_dir/pi"
  export SESSIONS_MISE="$REPO_DIR/test/fixtures/mise-resolver"
  export SESSIONS_MIX="$guard_dir/mix"
  export SESSIONS_SHELL="$guard_dir/shell"
  export MISE_AUTO_INSTALL=0
  export MISE_TASK_RUN_AUTO_INSTALL=false
}

teardown_suite() {
  if [ -s "$SESSIONS_TEST_GUARD_LOG" ]; then
    cat "$SESSIONS_TEST_GUARD_LOG" >&2
    return 1
  fi
}
