#!/usr/bin/env bats

load helpers

@test "Python lint passes" {
  run bash -c 'cd "$1" && mise run lint:python' bash "$REPO_DIR"
  if [ "$status" -ne 0 ]; then
    echo "$output"
    return 1
  fi
}

@test "configured codebase lints pass" {
  local lints
  lints=$(python3 - "$REPO_DIR/mise.toml" <<'PY'
import sys
import tomllib

with open(sys.argv[1], "rb") as f:
    config = tomllib.load(f)

for lint in config.get("_", {}).get("codebase", {}).get("lint", []):
    print(lint)
PY
)
  [ -n "$lints" ]

  local lint
  while IFS= read -r lint; do
    [ -n "$lint" ]
    run bash -c 'cd "$1" && mise exec codebase -- codebase "lint:$2" "$1"' bash "$REPO_DIR" "$lint"
    if [ "$status" -ne 0 ]; then
      echo "lint:$lint failed"
      echo "$output"
      return 1
    fi
  done <<< "$lints"
}
