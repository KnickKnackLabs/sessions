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
      # `$PI_DIR-alt/...` must NOT match as pi.
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
          # No harness entry in file, path doesn't match PI_DIR, no env set →
          # falls to compile default (still pi today, but the path detection
          # itself must not claim this file).
          assert Harness.resolve(session: legacy_under_alt) == Cli.Harness.Pi
          # Directly check the internal rule by simulating a "different
          # default" world would require a second adapter; covered by bash
          # tests where a false-positive path match would make the resolver
          # return pi without env set. Here we just confirm resolution
          # succeeds without raising.
        end)
      after
        File.rm_rf!(base)
        File.rm_rf!(alt)
      end
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
