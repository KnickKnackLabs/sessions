defmodule Cli.EngineTest do
  use ExUnit.Case
  import ExUnit.CaptureIO

  defmodule FakeHarness do
    def build_command(message, _model, _system_prompt_file, _session, _timeout, _opts) do
      {"printf '%s\\n' \"$1\"; exit 0", [message]}
    end

    def process_line("agent-error", state) do
      Map.put(state, :agent_error, %{
        source: :fake,
        reason: "error",
        message: "failed assistant turn"
      })
    end

    def process_line(_line, state), do: state

    def extract_partial_text(_partial), do: ""
  end

  defp run_engine(message) do
    output =
      capture_io(fn ->
        exit_code =
          Cli.Engine.run(FakeHarness, message, "/tmp/prompt.txt", nil, "test-model", nil, nil, [])

        send(self(), {:exit_code, exit_code})
      end)

    receive do
      {:exit_code, exit_code} -> {output, exit_code}
    end
  end

  test "exits non-zero when the harness reports a generic agent_error" do
    {output, exit_code} = run_engine("agent-error")

    assert exit_code == 1
    assert output =~ "ERROR: Agent reported an error via fake (error): failed assistant turn"
  end

  test "returns process status when the harness does not report agent_error" do
    {output, exit_code} = run_engine("ok")

    assert exit_code == 0
    refute output =~ "Agent reported an error"
  end

  test "scrubs caller context from harness process environment" do
    previous_caller = System.get_env("CALLER_PWD")
    previous_sessions_caller = System.get_env("SESSIONS_CALLER_PWD")
    previous_other_caller = System.get_env("OTHER_CALLER_PWD")

    try do
      System.put_env("CALLER_PWD", "/stale/caller")
      System.put_env("SESSIONS_CALLER_PWD", "/stale/sessions/caller")
      System.put_env("OTHER_CALLER_PWD", "/stale/other/caller")

      output =
        capture_io(fn ->
          exit_code =
            Cli.Engine.run(
              __MODULE__.EnvHarness,
              "ignored",
              "/tmp/prompt.txt",
              nil,
              "test-model",
              nil,
              nil,
              []
            )

          send(self(), {:exit_code, exit_code})
        end)

      assert_receive {:exit_code, 0}
      assert output =~ "CALLER_PWD="
      assert output =~ "SESSIONS_CALLER_PWD="
      assert output =~ "OTHER_CALLER_PWD="
      refute output =~ "/stale/caller"
      refute output =~ "/stale/sessions/caller"
      refute output =~ "/stale/other/caller"
    after
      restore_env("CALLER_PWD", previous_caller)
      restore_env("SESSIONS_CALLER_PWD", previous_sessions_caller)
      restore_env("OTHER_CALLER_PWD", previous_other_caller)
    end
  end

  defmodule EnvHarness do
    def build_command(_message, _model, _system_prompt_file, _session, _timeout, _opts) do
      {"printf 'CALLER_PWD=%s\\n' \"${CALLER_PWD-}\"; printf 'SESSIONS_CALLER_PWD=%s\\n' \"${SESSIONS_CALLER_PWD-}\"; printf 'OTHER_CALLER_PWD=%s\\n' \"${OTHER_CALLER_PWD-}\"",
       []}
    end

    def process_line(line, state) do
      IO.puts(line)
      state
    end

    def extract_partial_text(_partial), do: ""
  end

  test "sanitizes mise install paths from harness PATH" do
    home = System.get_env("HOME") || System.tmp_dir!()
    mise_data_dir = Path.join([home, ".local", "share", "mise"])

    with_env(%{"MISE_DATA_DIR" => nil, "XDG_DATA_HOME" => nil}, fn ->
      assert_sanitized_path(mise_data_dir)
    end)
  end

  test "sanitizes mise install paths from MISE_DATA_DIR" do
    tmp =
      Path.join(System.tmp_dir!(), "sessions-mise-data-dir-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(tmp, "shims"))

    try do
      with_env(%{"MISE_DATA_DIR" => tmp, "XDG_DATA_HOME" => nil}, fn ->
        assert_sanitized_path(tmp)
      end)
    after
      File.rm_rf!(tmp)
    end
  end

  test "sanitizes mise install paths from XDG_DATA_HOME" do
    xdg_data_home =
      Path.join(System.tmp_dir!(), "sessions-xdg-data-home-#{System.unique_integer([:positive])}")

    mise_data_dir = Path.join(xdg_data_home, "mise")
    File.mkdir_p!(Path.join(mise_data_dir, "shims"))

    try do
      with_env(%{"MISE_DATA_DIR" => nil, "XDG_DATA_HOME" => xdg_data_home}, fn ->
        assert_sanitized_path(mise_data_dir)
      end)
    after
      File.rm_rf!(xdg_data_home)
    end
  end

  defp assert_sanitized_path(mise_data_dir) do
    stale_codebase = Path.join([mise_data_dir, "installs", "shiv-codebase", "0.1.0", "bin"])
    fresh_codebase = Path.join([mise_data_dir, "installs", "shiv-codebase", "0.2.0", "bin"])
    mise_shims = Path.join(mise_data_dir, "shims")
    non_mise = Path.join(System.tmp_dir!(), "sessions-non-mise-bin")

    previous_path = System.get_env("PATH")

    try do
      System.put_env("PATH", Enum.join([stale_codebase, non_mise, fresh_codebase], ":"))

      output =
        capture_io(fn ->
          exit_code =
            Cli.Engine.run(
              __MODULE__.PathHarness,
              "ignored",
              "/tmp/prompt.txt",
              nil,
              "test-model",
              nil,
              nil,
              []
            )

          send(self(), {:exit_code, exit_code})
        end)

      assert_receive {:exit_code, 0}
      refute output =~ stale_codebase
      refute output =~ fresh_codebase
      assert output =~ non_mise

      if File.dir?(mise_shims) do
        assert output =~ mise_shims
      end
    after
      restore_env("PATH", previous_path)
    end
  end

  defmodule PathHarness do
    def build_command(_message, _model, _system_prompt_file, _session, _timeout, _opts) do
      {"printf 'PATH=%s\\n' \"$PATH\"", []}
    end

    def process_line(line, state) do
      IO.puts(line)
      state
    end

    def extract_partial_text(_partial), do: ""
  end

  defp with_env(env, fun) do
    previous = Map.new(env, fn {name, _value} -> {name, System.get_env(name)} end)

    try do
      Enum.each(env, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)

      fun.()
    after
      Enum.each(previous, fn {name, value} -> restore_env(name, value) end)
    end
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end
