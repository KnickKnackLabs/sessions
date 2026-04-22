#!/usr/bin/env bats
# Tests for lib/ensure-deps.sh — the defensive deps check that self-heals
# a fresh shiv-sessions install. See KnickKnackLabs/sessions#53.

load helpers

setup() {
  # Source the helper under test. Using MISE_CONFIG_ROOT guarantees we're
  # sourcing the version in the tree being tested (not the shiv-installed
  # one), consistent with how `.mise/tasks/run` resolves it.
  source "$MISE_CONFIG_ROOT/lib/ensure-deps.sh"

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

@test "ensure_cli_deps: returns 0 and does nothing when deps are populated" {
  # Multiple subdirs, mimicking a real install.
  mkdir -p "$CLI/deps/jason" "$CLI/deps/credo" "$CLI/deps/bunt"
  run ensure_cli_deps "$CLI"
  [ "$status" -eq 0 ]
  # Directory unchanged.
  [ -d "$CLI/deps/jason" ]
  [ -d "$CLI/deps/credo" ]
  [ -d "$CLI/deps/bunt" ]
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

@test "ensure_cli_deps: errors when cli_dir argument is missing" {
  run ensure_cli_deps
  [ "$status" -ne 0 ]
  [[ "$output" == *"cli_dir argument required"* ]]
}

@test "ensure_cli_deps: errors when cli_dir does not exist" {
  run ensure_cli_deps "$TMP/does-not-exist"
  [ "$status" -ne 0 ]
  [[ "$output" == *"cli dir does not exist"* ]]
}

@test "ensure_cli_deps: errors and emits hint when mix fetch fails" {
  # Break the mix project so deps.get fails.
  echo "this is not valid elixir" > "$CLI/mix.exs"

  run ensure_cli_deps "$CLI"
  [ "$status" -ne 0 ]
  [[ "$output" == *"first-run setup"* ]]
  [[ "$output" == *"failed to fetch dependencies"* ]]
  [[ "$output" == *"mise run cli:build"* ]]
}
