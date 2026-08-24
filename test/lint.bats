#!/usr/bin/env bats

load helpers

@test "Python lint passes" {
  run sessions lint:python
  if [ "$status" -ne 0 ]; then
    echo "$output"
    return 1
  fi
}

@test "configured codebase lints pass" {
  run bash -c 'cd "$1" && mise exec codebase -- codebase lint "$1"' bash "$REPO_DIR"
  if [ "$status" -ne 0 ]; then
    echo "$output"
    return 1
  fi
}
