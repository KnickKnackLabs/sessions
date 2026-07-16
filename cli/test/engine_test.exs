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

  test "scrubs caller, mise-task, and usage context from the harness environment" do
    inherited = %{
      "CALLER_PWD" => "/stale/caller",
      "SESSIONS_CALLER_PWD" => "/stale/sessions/caller",
      "OTHER_CALLER_PWD" => "/stale/other/caller",
      "MISE_CONFIG_ROOT" => "/stale/sessions/root",
      "MISE_TASK_NAME" => "run",
      "usage_message" => "stale task payload"
    }

    with_env(inherited, fn ->
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

      for name <- Map.keys(inherited) do
        assert output =~ "#{name}="
        refute output =~ Map.fetch!(inherited, name)
      end
    end)
  end

  defmodule EnvHarness do
    def build_command(_message, _model, _system_prompt_file, _session, _timeout, _opts) do
      command =
        [
          "CALLER_PWD",
          "SESSIONS_CALLER_PWD",
          "OTHER_CALLER_PWD",
          "MISE_CONFIG_ROOT",
          "MISE_TASK_NAME",
          "usage_message"
        ]
        |> Enum.map_join("; ", fn name ->
          ~s(printf '#{name}=%s\\n' "${#{name}-}")
        end)

      {command, []}
    end

    def process_line(line, state) do
      IO.puts(line)
      state
    end

    def extract_partial_text(_partial), do: ""
  end

  test "real Pi adapter preserves selected executable and requested child boundary" do
    root =
      Path.join(System.tmp_dir!(), "sessions-pi-boundary-#{System.unique_integer([:positive])}")

    cwd = Path.join(root, "project")
    executable = Path.join(root, "selected pi")
    capture = Path.join(root, "child.txt")
    mise_data = Path.join(root, "mise")
    stale_bin = Path.join([mise_data, "installs", "sessions-tool", "1.0", "bin"])
    shim_bin = Path.join(mise_data, "shims")
    ordinary_bin = Path.join(root, "ordinary-bin")

    File.mkdir_p!(cwd)
    File.mkdir_p!(stale_bin)
    File.mkdir_p!(shim_bin)
    File.mkdir_p!(ordinary_bin)

    File.write!(
      executable,
      """
      #!/bin/sh
      {
        printf 'EXECUTABLE=%s\\n' "$0"
        printf 'CWD=%s\\n' "$(pwd -P)"
        printf 'PATH=%s\\n' "$PATH"
        printf 'MISE_CONFIG_ROOT=%s\\n' "${MISE_CONFIG_ROOT-}"
        printf 'MISE_TASK_NAME=%s\\n' "${MISE_TASK_NAME-}"
        printf 'usage_message=%s\\n' "${usage_message-}"
        printf 'CALLER_PWD=%s\\n' "${CALLER_PWD-}"
        printf 'ARGV='; printf '<%s>' "$@"; printf '\\n'
      } > "#{capture}"
      """
    )

    File.chmod!(executable, 0o755)

    try do
      with_env(
        %{
          "PATH" => Enum.join([stale_bin, ordinary_bin], ":"),
          "MISE_DATA_DIR" => mise_data,
          "MISE_CONFIG_ROOT" => "/stale/sessions/root",
          "MISE_TASK_NAME" => "run",
          "usage_message" => "stale task payload",
          "CALLER_PWD" => "/stale/caller"
        },
        fn ->
          capture_io(fn ->
            exit_code =
              Cli.Engine.run(
                Cli.Harness.Pi,
                "probe",
                nil,
                nil,
                "openai-codex/gpt-5.5",
                cwd,
                nil,
                harness_executable: executable,
                project_trust: "approve"
              )

            send(self(), {:exit_code, exit_code})
          end)
        end
      )

      assert_receive {:exit_code, 0}
      child = File.read!(capture)
      {physical_cwd, 0} = System.cmd("pwd", ["-P"], cd: cwd)

      assert child =~ "EXECUTABLE=#{executable}"
      assert child =~ "CWD=#{String.trim(physical_cwd)}"
      assert child =~ "PATH=#{shim_bin}:#{ordinary_bin}"
      assert child =~ "MISE_CONFIG_ROOT=\n"
      assert child =~ "MISE_TASK_NAME=\n"
      assert child =~ "usage_message=\n"
      assert child =~ "CALLER_PWD=\n"
      assert child =~ "<--approve>"
      refute child =~ stale_bin
    after
      File.rm_rf!(root)
    end
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
