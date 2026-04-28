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
end
