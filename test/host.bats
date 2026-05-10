#!/usr/bin/env bats

load helpers

setup() {
  TMP=$(mktemp -d)
  BIN="$TMP/bin"
  mkdir -p "$BIN"
  export PATH="$BIN:$PATH"
  export SESSIONS_SUDOERS_FILE="$TMP/sudoers.d/sessions-humans-agents"
  export SESSIONS_RUN_AS_USER="$TMP/run-as-user"

  cat > "$BIN/id" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = "-un" ]; then
  echo rikonor
elif [ "${1:-}" = "-u" ]; then
  case "${2:-}" in
    iris|rikonor) echo 500 ;;
    *) exit 1 ;;
  esac
elif [ "${1:-}" = "-Gn" ]; then
  case "${2:-}" in
    rikonor) echo "staff humans" ;;
    iris) echo "staff agents" ;;
    *) exit 1 ;;
  esac
else
  echo "unexpected id args: $*" >&2
  exit 64
fi
EOF
  chmod +x "$BIN/id"

  cat > "$BIN/dscl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  ". -read /Groups/humans"|". -read /Groups/agents") exit 0 ;;
  *) echo "unexpected dscl args: $*" >&2; exit 64 ;;
esac
EOF
  chmod +x "$BIN/dscl"

  cat > "$BIN/visudo" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ "$1" = "-cf" ]
[ -f "$2" ]
if grep -Fxq INVALID "$2"; then
  exit 1
fi
exit 0
EOF
  chmod +x "$BIN/visudo"

  mkdir -p "$(dirname "$SESSIONS_SUDOERS_FILE")"
  printf '%%humans ALL=(%%agents) NOPASSWD: ALL\n' > "$SESSIONS_SUDOERS_FILE"

  cat > "$SESSIONS_RUN_AS_USER" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ "$1" = "--user" ]
[ "$2" = "iris" ]
[ "$3" = "--" ]
shift 3
if [ "$1" = "whoami" ]; then
  echo iris
else
  exec "$@"
fi
EOF
  chmod +x "$SESSIONS_RUN_AS_USER"
}

teardown() {
  rm -rf "$TMP"
}

@test "host:doctor succeeds when groups sudoers and smoke test are healthy" {
  run sessions host:doctor --os-user iris
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK    group 'humans' exists"* ]]
  [[ "$output" == *"OK    run-as-user smoke test returned 'iris'"* ]]
}

@test "host:doctor fails when sudoers file syntax is invalid" {
  printf 'INVALID\n' >> "$SESSIONS_SUDOERS_FILE"

  run sessions host:doctor --os-user iris
  [ "$status" -eq 1 ]
  [[ "$output" == *"OK    sudoers rule installed at $SESSIONS_SUDOERS_FILE"* ]]
  [[ "$output" == *"FAIL  sudoers file syntax is invalid or cannot be validated: $SESSIONS_SUDOERS_FILE"* ]]
}

@test "host:fix --dry-run prints missing host changes" {
  rm -f "$SESSIONS_SUDOERS_FILE"
  cat > "$BIN/dscl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  ". -read /Groups/agents") exit 0 ;;
  ". -read /Groups/humans") exit 1 ;;
  *) echo "unexpected dscl args: $*" >&2; exit 64 ;;
esac
EOF
  chmod +x "$BIN/dscl"

  cat > "$BIN/id" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = "-un" ]; then
  echo rikonor
elif [ "${1:-}" = "-u" ]; then
  case "${2:-}" in
    iris|rikonor) echo 500 ;;
    *) exit 1 ;;
  esac
elif [ "${1:-}" = "-Gn" ]; then
  case "${2:-}" in
    rikonor) echo "staff" ;;
    iris) echo "staff" ;;
    *) exit 1 ;;
  esac
else
  exit 64
fi
EOF
  chmod +x "$BIN/id"

  run sessions host:fix --os-user iris --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"sudo dseditgroup -o create humans"* ]]
  [[ "$output" == *"sudo dseditgroup -o edit -a rikonor -t user humans"* ]]
  [[ "$output" == *"sudo dseditgroup -o edit -a iris -t user agents"* ]]
  [[ "$output" == *"sudo visudo -cf"* ]]
}

@test "host:fix --dry-run repairs installed sudoers file with invalid syntax" {
  printf 'INVALID\n' >> "$SESSIONS_SUDOERS_FILE"

  run sessions host:fix --os-user iris --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"sudo tee $SESSIONS_SUDOERS_FILE"* ]]
  [[ "$output" == *"sudo chmod 0440 $SESSIONS_SUDOERS_FILE"* ]]
  [[ "$output" == *"sudo visudo -cf $SESSIONS_SUDOERS_FILE"* ]]
}

@test "host:fix without --dry-run refuses to mutate in first slice" {
  rm -f "$SESSIONS_SUDOERS_FILE"
  run sessions host:fix --os-user iris
  [ "$status" -eq 2 ]
  [[ "$output" == *"mutating host:fix is not implemented yet"* ]]
}
