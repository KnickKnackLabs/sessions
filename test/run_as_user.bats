#!/usr/bin/env bats

load helpers

setup() {
  TMP=$(mktemp -d)
  BIN="$TMP/bin"
  mkdir -p "$BIN"
  export RUN_AS_USER_LOG="$TMP/run-as-user.log"
  export PATH="$BIN:$PATH"

  cat > "$BIN/id" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = "-u" ]; then
  case "${2:-}" in
    iris) echo 503 ;;
    *) exit 1 ;;
  esac
elif [ "${1:-}" = "-un" ]; then
  echo rikonor
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
if [ "$1 $2 $3" = ". -read /Users/iris" ]; then
  case "${4:-}" in
    NFSHomeDirectory) echo "NFSHomeDirectory: /Users/iris" ;;
    UserShell) echo "UserShell: /bin/zsh" ;;
    *) exit 1 ;;
  esac
else
  echo "unexpected dscl args: $*" >&2
  exit 64
fi
EOF
  chmod +x "$BIN/dscl"

  cat > "$BIN/sudo" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${RUN_AS_USER_LOG:?}"
# Simulate sudo by executing the command after: -n -H -u <user> --
[ "$1" = "-n" ]
[ "$2" = "-H" ]
[ "$3" = "-u" ]
[ "$4" = "iris" ]
[ "$5" = "--" ]
shift 5
exec "$@"
EOF
  chmod +x "$BIN/sudo"
}

teardown() {
  rm -rf "$TMP"
}

@test "run-as-user runs command through sudo with explicit target env" {
  run "$REPO_DIR/libexec/run-as-user" --user iris -- sh -c 'printf "%s|%s|%s|%s|%s" "$HOME" "$USER" "$LOGNAME" "$SHELL" "$PATH"'
  [ "$status" -eq 0 ]
  [[ "$output" == /Users/iris\|iris\|iris\|/bin/zsh\|/Users/iris/.local/bin:* ]]
  grep -q -- '-n -H -u iris -- env -i HOME=/Users/iris USER=iris LOGNAME=iris SHELL=/bin/zsh' "$RUN_AS_USER_LOG"
}

@test "run-as-user rejects invalid users" {
  run "$REPO_DIR/libexec/run-as-user" --user '../bad' -- whoami
  [ "$status" -eq 2 ]
  [[ "$output" == *"invalid --user"* ]]
}

@test "run-as-user requires command after separator" {
  run "$REPO_DIR/libexec/run-as-user" --user iris --
  [ "$status" -eq 2 ]
  [[ "$output" == *"command required"* ]]
}
