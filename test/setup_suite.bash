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

  eval "$(cd "$REPO_DIR" && mise env)"
}
