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
    previous_shiv_caller = System.get_env("SHIV_CALLER_PWD")

    try do
      System.put_env("CALLER_PWD", "/stale/caller")
      System.put_env("SHIV_CALLER_PWD", "/stale/shiv/caller")

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
      assert output =~ "SHIV_CALLER_PWD="
      refute output =~ "/stale/caller"
      refute output =~ "/stale/shiv/caller"
    after
      restore_env("CALLER_PWD", previous_caller)
      restore_env("SHIV_CALLER_PWD", previous_shiv_caller)
    end
  end

  defmodule EnvHarness do
    def build_command(_message, _model, _system_prompt_file, _session, _timeout, _opts) do
      {"printf 'CALLER_PWD=%s\\n' \"${CALLER_PWD-}\"; printf 'SHIV_CALLER_PWD=%s\\n' \"${SHIV_CALLER_PWD-}\"", []}
    end

    def process_line(line, state) do
      IO.puts(line)
      state
    end

    def extract_partial_text(_partial), do: ""
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end
