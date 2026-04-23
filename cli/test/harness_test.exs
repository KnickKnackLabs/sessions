defmodule Cli.HarnessTest do
  use ExUnit.Case, async: false
  # async: false — we mutate process environment variables.

  alias Cli.Harness

  # --- Registry ---

  describe "available/0" do
    test "returns :pi today, sorted" do
      assert Harness.available() == [:pi]
    end
  end

  describe "adapter/1" do
    test "returns the pi adapter module" do
      assert Harness.adapter(:pi) == Cli.Harness.Pi
    end

    test "raises on unknown name" do
      assert_raise ArgumentError, ~r/Unknown harness/, fn ->
        Harness.adapter(:claude)
      end
    end
  end

  # --- Resolver priority ---

  describe "resolve/1" do
    test "with no args falls through to the compile-time default" do
      with_env(%{"SESSIONS_DEFAULT_HARNESS" => nil}, fn ->
        assert Harness.resolve() == Cli.Harness.Pi
      end)
    end

    test "explicit :name as atom short-circuits" do
      assert Harness.resolve(name: :pi) == Cli.Harness.Pi
    end

    test "explicit :name as string is validated against the adapter list" do
      assert Harness.resolve(name: "pi") == Cli.Harness.Pi

      assert_raise ArgumentError, ~r/Unknown harness "claude" from name: option/, fn ->
        Harness.resolve(name: "claude")
      end
    end

    test "reads the most recent harness entry from a session file" do
      path = write_session_file("""
      {"type":"session","id":"abc"}
      {"type":"harness","id":"h1","parentId":"abc","timestamp":"2026-04-22T10:00:00.000Z","name":"pi"}
      {"type":"model_change","id":"mc1"}
      """)

      assert Harness.resolve(session: path) == Cli.Harness.Pi
    end

    test "raises if the session file declares an unknown harness" do
      path = write_session_file("""
      {"type":"session","id":"abc"}
      {"type":"harness","id":"h1","name":"rogue"}
      """)

      assert_raise ArgumentError, ~r/Unknown harness "rogue" from session file/, fn ->
        Harness.resolve(session: path)
      end
    end

    test "falls through to path-based detection when the file has no harness entry" do
      # Legacy session with no harness declaration, under PI_DIR.
      pi_dir = System.tmp_dir!() |> Path.join("cli-harness-test-#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(pi_dir, "agent/sessions/project"))
      legacy = Path.join([pi_dir, "agent/sessions/project", "legacy.jsonl"])
      File.write!(legacy, """
      {"type":"session","id":"legacy"}
      {"type":"model_change","id":"mc1"}
      """)

      try do
        with_env(%{"PI_DIR" => pi_dir}, fn ->
          assert Harness.resolve(session: legacy) == Cli.Harness.Pi
        end)
      after
        File.rm_rf!(pi_dir)
      end
    end

    test "path-based detection requires a `/` separator after the prefix" do
      # TODO(step 3): when a second adapter exists, strengthen this test
      # so the resolver returning :pi via the *path rule* is distinguishable
      # from it returning :pi via the compile-time default. Today both
      # produce the same answer.
      base = System.tmp_dir!() |> Path.join("harness-test-base-#{System.unique_integer([:positive])}")
      alt = base <> "-alt"
      File.mkdir_p!(base)
      File.mkdir_p!(alt)
      legacy_under_alt = Path.join(alt, "legacy.jsonl")
      File.write!(legacy_under_alt, """
      {"type":"session","id":"legacy"}
      """)

      try do
        with_env(%{"PI_DIR" => base, "SESSIONS_DEFAULT_HARNESS" => nil}, fn ->
          assert Harness.resolve(session: legacy_under_alt) == Cli.Harness.Pi
        end)
      after
        File.rm_rf!(base)
        File.rm_rf!(alt)
      end
    end

    # The rule-by-rule tests below invoke the internal `from_path`
    # directly (exposed as `@doc false def` so these assertions can
    # distinguish "rule matched" from "fell through to default" — a
    # distinction `resolve/1` can't surface while pi is the only
    # adapter).

    test "from_path matches under $PI_DIR with a separator" do
      with_env(%{"PI_DIR" => "/custom/pi"}, fn ->
        assert Harness.from_path("/custom/pi/agent/sessions/foo.jsonl") == :pi
      end)
    end

    test "from_path rejects sibling of $PI_DIR (no trailing-slash false positive)" do
      with_env(%{"PI_DIR" => "/custom/pi", "HOME" => "/nonexistent"}, fn ->
        assert Harness.from_path("/custom/pi-alt/agent/sessions/foo.jsonl") == nil
      end)
    end

    test "from_path matches under $HOME/.pi when PI_DIR is unset" do
      with_env(%{"PI_DIR" => nil, "HOME" => "/fake/home"}, fn ->
        assert Harness.from_path("/fake/home/.pi/agent/sessions/foo.jsonl") == :pi
      end)
    end

    test "from_path rejects $HOME/.pi-alt even when PI_DIR is unset (Path.join regression)" do
      # Regression: `Path.join(home, ".pi/")` strips the trailing
      # slash, producing `/fake/home/.pi` which then false-positive
      # matches `/fake/home/.pi-alt/...`. Fix: build `home <> "/.pi/"`
      # directly.
      with_env(%{"PI_DIR" => nil, "HOME" => "/fake/home"}, fn ->
        assert Harness.from_path("/fake/home/.pi-alt/agent/sessions/foo.jsonl") == nil
      end)
    end

    test "from_path treats PI_DIR=\"\" the same as unset" do
      # Regression: an empty PI_DIR used to become the prefix "" → "/",
      # matching every absolute path as pi.
      with_env(%{"PI_DIR" => "", "HOME" => "/fake/home"}, fn ->
        assert Harness.from_path("/etc/passwd") == nil
        assert Harness.from_path("/fake/home/.pi/foo.jsonl") == :pi
      end)
    end

    test "from_path normalizes a trailing slash on $PI_DIR" do
      # `PI_DIR=/opt/x/` should still match `/opt/x/agent/sessions/...`.
      with_env(%{"PI_DIR" => "/opt/x/", "HOME" => "/nonexistent"}, fn ->
        assert Harness.from_path("/opt/x/agent/sessions/foo.jsonl") == :pi
      end)
    end

    test "honours SESSIONS_DEFAULT_HARNESS when no session context is given" do
      with_env(%{"SESSIONS_DEFAULT_HARNESS" => "pi"}, fn ->
        assert Harness.resolve() == Cli.Harness.Pi
      end)
    end

    test "raises on unknown SESSIONS_DEFAULT_HARNESS without creating a new atom" do
      # Use a string guaranteed unique per test run so this test can't
      # be invalidated by an earlier compile-time reference to the name.
      bad = "no_such_harness_#{System.unique_integer([:positive])}"

      with_env(%{"SESSIONS_DEFAULT_HARNESS" => bad}, fn ->
        assert_raise ArgumentError,
                     ~r/Unknown harness ".*" from \$SESSIONS_DEFAULT_HARNESS/,
                     fn -> Harness.resolve() end
      end)

      # The failed resolution must not have created the bad name as an
      # atom. This is the real guarantee against atom-exhaustion — the
      # `String.to_existing_atom/1` call below raises if (and only if)
      # `atomize_or_raise` used `String.to_atom/1` under the hood.
      assert_raise ArgumentError, fn ->
        String.to_existing_atom(bad)
      end
    end

    test "explicit :name beats session-file harness entry" do
      path = write_session_file("""
      {"type":"session","id":"abc"}
      {"type":"harness","id":"h1","name":"pi"}
      """)

      # If both resolve to pi, a string-returning proof is thin — but we
      # can still confirm that passing an invalid explicit :name raises
      # *before* reaching the session-file rule (which would have resolved
      # cleanly).
      assert_raise ArgumentError, ~r/Unknown harness "rogue" from name: option/, fn ->
        Harness.resolve(name: "rogue", session: path)
      end
    end
  end

  # --- Helpers ---

  defp with_env(env, fun) do
    previous =
      Enum.map(env, fn {k, _} -> {k, System.get_env(k)} end)

    try do
      Enum.each(env, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)

      fun.()
    after
      Enum.each(previous, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)
    end
  end

  defp write_session_file(contents) do
    path =
      System.tmp_dir!()
      |> Path.join("harness-session-#{System.unique_integer([:positive])}.jsonl")

    File.write!(path, contents)
    on_exit_cleanup(path)
    path
  end

  defp on_exit_cleanup(path) do
    ExUnit.Callbacks.on_exit(fn -> File.rm(path) end)
  end
end
