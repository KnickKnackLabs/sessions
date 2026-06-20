#!/usr/bin/env bats
# Tests for lib/ensure-deps.sh — the defensive deps check that self-heals
# a fresh shiv-sessions install. See KnickKnackLabs/sessions#53.

load helpers

setup() {
  # Source the helper under test. $REPO_DIR is derived from
  # $BATS_TEST_DIRNAME (see test/helpers.bash), which pins us to the
  # tree being tested regardless of how the suite was invoked.
  source "$REPO_DIR/lib/ensure-deps.sh"

  TMP=$(mktemp -d)
  CLI="$TMP/cli"
  mkdir -p "$CLI/deps"

  # Minimal mix project so real `mix deps.get` has something to read.
  cat > "$CLI/mix.exs" <<'EOF'
defmodule EnsureDepsTest.MixProject do
  use Mix.Project
  def project, do: [app: :ensure_deps_test, version: "0.0.1", elixir: "~> 1.19", deps: deps()]
  def application, do: [extra_applications: [:logger]]
  defp deps, do: [{:jason, "~> 1.4"}]
end
EOF
}

teardown() {
  rm -rf "$TMP"
}

write_fake_mix() {
  fakebin="$TMP/fakebin"
  mkdir -p "$fakebin"
  MIX_LOG="$TMP/mix.log"
  export MIX_LOG
  cat > "$fakebin/mix" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$MIX_LOG"
case "$*" in
  "local.hex --force --if-missing")
    exit "${FAKE_MIX_HEX_STATUS:-0}"
    ;;
  "deps.loadpaths --no-compile")
    count_file="$MIX_LOG.loadpaths-count"
    count=0
    if [ -f "$count_file" ]; then
      count=$(cat "$count_file")
    fi
    count=$((count + 1))
    printf '%s\n' "$count" > "$count_file"
    if [ "$count" -eq 1 ]; then
      exit "${FAKE_MIX_LOADPATHS_FIRST_STATUS:-0}"
    fi
    exit "${FAKE_MIX_LOADPATHS_NEXT_STATUS:-${FAKE_MIX_LOADPATHS_FIRST_STATUS:-0}}"
    ;;
  "deps.get")
    exit "${FAKE_MIX_DEPS_GET_STATUS:-0}"
    ;;
esac
exit 43
EOF
  chmod +x "$fakebin/mix"
  export fakebin
}

# ----------------------------------------------------------------------------
# Happy paths
# ----------------------------------------------------------------------------

@test "ensure_cli_deps: returns 0 when Mix reports dependency load paths ready" {
  write_fake_mix
  export FAKE_MIX_LOADPATHS_FIRST_STATUS=0
  export FAKE_MIX_DEPS_GET_STATUS=42

  PATH="$fakebin:$PATH" run ensure_cli_deps "$CLI"

  [ "$status" -eq 0 ]
  [[ "$output" != *"first-run setup"* ]]
  [ "$(sed -n '1p' "$MIX_LOG")" = "local.hex --force --if-missing" ]
  [ "$(sed -n '2p' "$MIX_LOG")" = "deps.loadpaths --no-compile" ]
  ! grep -q '^deps.get$' "$MIX_LOG"
}

@test "ensure_cli_deps: fetches deps when load paths are not ready even if deps is populated" {
  mkdir -p "$CLI/deps/some_pkg"
  write_fake_mix
  export FAKE_MIX_LOADPATHS_FIRST_STATUS=1
  export FAKE_MIX_LOADPATHS_NEXT_STATUS=0

  PATH="$fakebin:$PATH" run ensure_cli_deps "$CLI"

  [ "$status" -eq 0 ]
  [[ "$output" == *"first-run setup"* ]]
  [ "$(sed -n '1p' "$MIX_LOG")" = "local.hex --force --if-missing" ]
  [ "$(sed -n '2p' "$MIX_LOG")" = "deps.loadpaths --no-compile" ]
  [ "$(sed -n '3p' "$MIX_LOG")" = "deps.get" ]
  [ "$(sed -n '4p' "$MIX_LOG")" = "deps.loadpaths --no-compile" ]
}

@test "ensure_cli_deps: installs Hex before checking dependency readiness" {
  write_fake_mix
  export FAKE_MIX_LOADPATHS_FIRST_STATUS=0

  PATH="$fakebin:$PATH" run ensure_cli_deps "$CLI"

  [ "$status" -eq 0 ]
  [ "$(sed -n '1p' "$MIX_LOG")" = "local.hex --force --if-missing" ]
  [ "$(sed -n '2p' "$MIX_LOG")" = "deps.loadpaths --no-compile" ]
}

@test "ensure_cli_deps: returns 1 when Hex setup fails" {
  write_fake_mix
  export FAKE_MIX_HEX_STATUS=17
  export FAKE_MIX_LOADPATHS_FIRST_STATUS=0

  PATH="$fakebin:$PATH" run ensure_cli_deps "$CLI"

  [ "$status" -eq 1 ]
  [[ "$output" == *"failed to install Hex package manager"* ]]
  grep -q '^local.hex --force --if-missing$' "$MIX_LOG"
  ! grep -q '^deps.loadpaths --no-compile$' "$MIX_LOG"
  ! grep -q '^deps.get$' "$MIX_LOG"
}

# ----------------------------------------------------------------------------
# Self-heal
# ----------------------------------------------------------------------------

@test "ensure_cli_deps: fetches deps when deps/ is empty" {
  # deps/ exists but is empty — the fresh-install condition.
  [ -z "$(ls -A "$CLI/deps")" ]

  run ensure_cli_deps "$CLI"
  [ "$status" -eq 0 ]

  # First-run notice must be emitted.
  [[ "$output" == *"first-run setup"* ]]

  # deps/ should now be populated. jason is the only dep in our fixture.
  [ -d "$CLI/deps/jason" ]
}

@test "ensure_cli_deps: fetches deps when deps/ does not exist at all" {
  # Nuke the deps dir entirely — the Mix readiness check should fail closed.
  rm -rf "$CLI/deps"

  run ensure_cli_deps "$CLI"
  [ "$status" -eq 0 ]

  [[ "$output" == *"first-run setup"* ]]
  [ -d "$CLI/deps/jason" ]
}

# ----------------------------------------------------------------------------
# Error paths
# ----------------------------------------------------------------------------

@test "ensure_cli_deps: returns 2 (programmer error) when cli_dir argument is missing" {
  # Tests the documented contract: return 2 for programmer errors,
  # return 1 for runtime setup/readiness failures. A future refactor that
  # swaps these should fail here.
  run ensure_cli_deps
  [ "$status" -eq 2 ]
  [[ "$output" == *"cli_dir argument required"* ]]
}

@test "ensure_cli_deps: returns 2 (programmer error) when cli_dir does not exist" {
  run ensure_cli_deps "$TMP/does-not-exist"
  [ "$status" -eq 2 ]
  [[ "$output" == *"cli dir does not exist"* ]]
}

@test "ensure_cli_deps: returns 1 (fetch failed) and emits hint when deps.get fails" {
  write_fake_mix
  export FAKE_MIX_LOADPATHS_FIRST_STATUS=1
  export FAKE_MIX_DEPS_GET_STATUS=18

  PATH="$fakebin:$PATH" run ensure_cli_deps "$CLI"

  [ "$status" -eq 1 ]
  [[ "$output" == *"first-run setup"* ]]
  [[ "$output" == *"failed to fetch dependencies"* ]]
  [[ "$output" == *"mise run cli:build"* ]]
  grep -q '^local.hex --force --if-missing$' "$MIX_LOG"
  grep -q '^deps.loadpaths --no-compile$' "$MIX_LOG"
  grep -q '^deps.get$' "$MIX_LOG"
}

@test "ensure_cli_deps: returns 1 when deps remain unloadable after deps.get" {
  write_fake_mix
  export FAKE_MIX_LOADPATHS_FIRST_STATUS=1
  export FAKE_MIX_LOADPATHS_NEXT_STATUS=1
  export FAKE_MIX_DEPS_GET_STATUS=0

  PATH="$fakebin:$PATH" run ensure_cli_deps "$CLI"

  [ "$status" -eq 1 ]
  [[ "$output" == *"dependencies were fetched but are still not loadable"* ]]
  [ "$(grep -c '^deps.loadpaths --no-compile$' "$MIX_LOG")" -eq 2 ]
  grep -q '^deps.get$' "$MIX_LOG"
}

@test "cli:build uses the shared readiness helper" {
  write_fake_mix
  export FAKE_MIX_LOADPATHS_FIRST_STATUS=0
  export FAKE_MIX_DEPS_GET_STATUS=42

  PATH="$fakebin:$PATH" run mise -C "$REPO_DIR" run -q cli:build

  [ "$status" -eq 0 ]
  [ "$(sed -n '1p' "$MIX_LOG")" = "local.hex --force --if-missing" ]
  [ "$(sed -n '2p' "$MIX_LOG")" = "deps.loadpaths --no-compile" ]
  ! grep -q '^deps.get$' "$MIX_LOG"
}
