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

  # Minimal mix project so `mix deps.get` has something to read.
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

# ----------------------------------------------------------------------------
# Happy paths
# ----------------------------------------------------------------------------

@test "ensure_cli_deps: returns 0 when deps/ is already populated" {
  # Simulate previously-fetched state by planting a dummy subdir.
  mkdir -p "$CLI/deps/some_pkg"
  run ensure_cli_deps "$CLI"
  [ "$status" -eq 0 ]
  # Should NOT emit the first-run notice when deps are present.
  [[ "$output" != *"first-run setup"* ]]
}

@test "ensure_cli_deps: returns 0 without fetching deps when deps are populated" {
  # Multiple subdirs, mimicking a real install.
  mkdir -p "$CLI/deps/jason" "$CLI/deps/credo" "$CLI/deps/bunt"
  run ensure_cli_deps "$CLI"
  [ "$status" -eq 0 ]
  # Directory unchanged.
  [ -d "$CLI/deps/jason" ]
  [ -d "$CLI/deps/credo" ]
  [ -d "$CLI/deps/bunt" ]
}

@test "ensure_cli_deps: installs Hex even when deps are populated" {
  mkdir -p "$CLI/deps/jason"
  fakebin="$TMP/fakebin"
  mkdir -p "$fakebin"
  MIX_LOG="$TMP/mix.log"
  export MIX_LOG
  cat > "$fakebin/mix" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$MIX_LOG"
case "$*" in
  "local.hex --force --if-missing") exit 0 ;;
  "deps.get") exit 42 ;;
esac
exit 43
EOF
  chmod +x "$fakebin/mix"

  PATH="$fakebin:$PATH" run ensure_cli_deps "$CLI"
  [ "$status" -eq 0 ]
  grep -q '^local.hex --force --if-missing$' "$MIX_LOG"
  ! grep -q '^deps.get$' "$MIX_LOG"
}

@test "ensure_cli_deps: returns 1 when Hex setup fails" {
  mkdir -p "$CLI/deps/jason"
  fakebin="$TMP/fakebin"
  mkdir -p "$fakebin"
  MIX_LOG="$TMP/mix.log"
  export MIX_LOG
  cat > "$fakebin/mix" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$MIX_LOG"
case "$*" in
  "local.hex --force --if-missing") exit 17 ;;
  "deps.get") exit 0 ;;
esac
exit 43
EOF
  chmod +x "$fakebin/mix"

  PATH="$fakebin:$PATH" run ensure_cli_deps "$CLI"
  [ "$status" -eq 1 ]
  [[ "$output" == *"failed to install Hex package manager"* ]]
  grep -q '^local.hex --force --if-missing$' "$MIX_LOG"
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
  # Nuke the deps dir entirely — ls -A returns empty for a missing dir.
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
  # return 1 for runtime fetch failures. A future refactor that swaps
  # these should fail here.
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
  fakebin="$TMP/fakebin"
  mkdir -p "$fakebin"
  MIX_LOG="$TMP/mix.log"
  export MIX_LOG
  cat > "$fakebin/mix" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$MIX_LOG"
case "$*" in
  "local.hex --force --if-missing") exit 0 ;;
  "deps.get") exit 18 ;;
esac
exit 43
EOF
  chmod +x "$fakebin/mix"

  PATH="$fakebin:$PATH" run ensure_cli_deps "$CLI"
  [ "$status" -eq 1 ]
  [[ "$output" == *"first-run setup"* ]]
  [[ "$output" == *"failed to fetch dependencies"* ]]
  [[ "$output" == *"mise run cli:build"* ]]
  grep -q '^local.hex --force --if-missing$' "$MIX_LOG"
  grep -q '^deps.get$' "$MIX_LOG"
}
