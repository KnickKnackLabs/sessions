#!/usr/bin/env bats

load helpers
bats_require_minimum_version 1.5.0

setup() {
  export PI_DIR="$BATS_TEST_TMPDIR/pi-test"
  MOCK_DIR="$BATS_TEST_TMPDIR/mock-bin"
  BATS_LOG="$BATS_TEST_TMPDIR/bats.log"
  mkdir -p "$MOCK_DIR"
  export BATS_LOG

  cat > "$MOCK_DIR/bats" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
{
  printf 'jobs=%s\n' "${BATS_NUMBER_OF_PARALLEL_JOBS:-}"
  printf 'runner=%s\n' "${BATS_PARALLEL_BINARY_NAME:-}"
  for arg in "$@"; do
    printf 'arg=%s\n' "$arg"
  done
} > "$BATS_LOG"
SH

  cat > "$MOCK_DIR/rush" <<'SH'
#!/usr/bin/env bash
exit 0
SH

  chmod +x "$MOCK_DIR/bats" "$MOCK_DIR/rush"

  export BATS_COMMAND="$MOCK_DIR/bats"
  export RUSH_COMMAND="$MOCK_DIR/rush"
  unset BATS_NUMBER_OF_PARALLEL_JOBS BATS_PARALLEL_BINARY_NAME
}

log_value() {
  local key="$1"
  awk -F= -v key="$key" '$1 == key { print substr($0, length(key) + 2); exit }' "$BATS_LOG"
}

arg_count() {
  local expected="$1"
  awk -F= -v expected="$expected" '$1 == "arg" && substr($0, 5) == expected { count++ } END { print count + 0 }' "$BATS_LOG"
}

logged_arguments() {
  sed -n 's/^arg=//p' "$BATS_LOG"
}

@test "test task defaults to four Rush jobs across files" {
  run sessions test copy --filter doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"4 jobs across files"* ]]
  [ "$(log_value jobs)" = "4" ]
  [ "$(log_value runner)" = "$MOCK_DIR/rush" ]
  [ "$(arg_count --no-parallelize-within-files)" -eq 1 ]
  [ "$(arg_count "$REPO_DIR/test/copy.bats")" -eq 1 ]
  [ "$(arg_count --filter)" -eq 1 ]
  [ "$(arg_count doctor)" -eq 1 ]
}

@test "explicit jobs override is forwarded once" {
  run sessions test --jobs 3 copy
  [ "$status" -eq 0 ]
  [[ "$output" == *"3 jobs across files"* ]]
  [ "$(log_value jobs)" = "" ]
  [ "$(arg_count --jobs)" -eq 1 ]
  [ "$(arg_count 3)" -eq 1 ]
  [ "$(arg_count --no-parallelize-within-files)" -eq 1 ]
}

@test "environment jobs override the detected default" {
  export BATS_NUMBER_OF_PARALLEL_JOBS=2

  run sessions test copy
  [ "$status" -eq 0 ]
  [[ "$output" == *"2 jobs across files"* ]]
  [ "$(log_value jobs)" = "2" ]
  [ "$(arg_count --jobs)" -eq 0 ]
}

@test "environment serial opt-out does not require Rush" {
  export BATS_NUMBER_OF_PARALLEL_JOBS=1
  export RUSH_COMMAND="$MOCK_DIR/missing-rush"

  run sessions test copy
  [ "$status" -eq 0 ]
  [[ "$output" == *"BATS parallelism: serial"* ]]
  [ "$(arg_count --no-parallelize-within-files)" -eq 0 ]
}

@test "CLI serial opt-out does not require Rush" {
  export RUSH_COMMAND="$MOCK_DIR/missing-rush"

  run sessions test --jobs 1 copy
  [ "$status" -eq 0 ]
  [[ "$output" == *"BATS parallelism: serial"* ]]
  [ "$(arg_count --no-parallelize-within-files)" -eq 0 ]
}

@test "parallel execution fails clearly when the selected runner is unavailable" {
  export RUSH_COMMAND="$MOCK_DIR/missing-rush"

  run -127 sessions test copy
  [ "$status" -eq 127 ]
  [[ "$output" == *"parallel runner '$MOCK_DIR/missing-rush' is unavailable for 4 jobs"* ]]
  [[ "$output" == *"run 'mise install' or use --jobs 1"* ]]
  [ ! -e "$BATS_LOG" ]
}

@test "environment runner override is preserved" {
  cp "$MOCK_DIR/rush" "$MOCK_DIR/alternate-runner"
  export BATS_PARALLEL_BINARY_NAME="$MOCK_DIR/alternate-runner"

  run sessions test copy
  [ "$status" -eq 0 ]
  [ "$(log_value runner)" = "$MOCK_DIR/alternate-runner" ]
}

@test "CLI runner override is preserved" {
  cp "$MOCK_DIR/rush" "$MOCK_DIR/alternate-runner"

  run sessions test --parallel-binary-name "$MOCK_DIR/alternate-runner" copy
  [ "$status" -eq 0 ]
  [ "$(arg_count --parallel-binary-name)" -eq 1 ]
  [ "$(arg_count "$MOCK_DIR/alternate-runner")" -eq 1 ]
}

@test "invalid job override fails before BATS" {
  export BATS_NUMBER_OF_PARALLEL_JOBS=lots

  run sessions test copy
  [ "$status" -eq 2 ]
  [[ "$output" == *"must be a positive integer"* ]]
  [ ! -e "$BATS_LOG" ]
}

@test "missing job override fails before BATS" {
  run sessions test --jobs
  [ "$status" -eq 2 ]
  [[ "$output" == *"--jobs requires a positive integer"* ]]
  [ ! -e "$BATS_LOG" ]
}

@test "filter values that resemble parallel flags remain filter values" {
  run sessions test --filter --jobs copy
  [ "$status" -eq 0 ]
  [[ "$output" == *"4 jobs across files"* ]]
  [ "$(logged_arguments)" = "$(printf '%s\n' \
    --print-output-on-failure \
    --no-parallelize-within-files \
    --filter \
    --jobs \
    "$REPO_DIR/test/copy.bats")" ]
}

@test "filter values that match suite names are not resolved as targets" {
  run sessions test --filter copy test-task
  [ "$status" -eq 0 ]
  [ "$(logged_arguments)" = "$(printf '%s\n' \
    --print-output-on-failure \
    --no-parallelize-within-files \
    --filter \
    copy \
    "$REPO_DIR/test/test-task.bats")" ]
}

@test "canonical task runs separate BATS files concurrently" {
  probe_dir="$BATS_TEST_TMPDIR/parallel-probe"
  barrier_dir="$BATS_TEST_TMPDIR/barrier"
  mkdir -p "$probe_dir" "$barrier_dir"

  test_keyword='@test'
  {
    printf '%s\n' '#!/usr/bin/env bats'
    printf '%s\n' "$test_keyword \"first worker observes second worker\" {"
    cat <<'BATS'
  touch "$PROBE_DIR/one"
  for _ in {1..50}; do
    [ ! -e "$PROBE_DIR/two" ] || return 0
    sleep 0.05
  done
  false
}
BATS
  } > "$probe_dir/one.bats"

  {
    printf '%s\n' '#!/usr/bin/env bats'
    printf '%s\n' "$test_keyword \"second worker observes first worker\" {"
    cat <<'BATS'
  touch "$PROBE_DIR/two"
  for _ in {1..50}; do
    [ ! -e "$PROBE_DIR/one" ] || return 0
    sleep 0.05
  done
  false
}
BATS
  } > "$probe_dir/two.bats"

  export PROBE_DIR="$barrier_dir"
  unset BATS_COMMAND RUSH_COMMAND
  run sessions test "$probe_dir"

  [ "$status" -eq 0 ]
  [[ "$output" == *"jobs across files"* ]]
}
