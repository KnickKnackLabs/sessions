defmodule Mix.Tasks.Sessions do
  @shortdoc "Run the sessions CLI"
  @moduledoc """
  Runs the sessions execution engine.

  ## Usage

      mix sessions --model <provider/model> [options] <message>

  ## Examples

      mix sessions --model openai-codex/gpt-5.5 --timeout 300 "Fix the bug"
      mix sessions --model openai-codex/gpt-5.5 --session ./session.jsonl "Continue"

  """
  use Mix.Task

  @impl Mix.Task
  def run(args) do
    args |> Cli.run() |> System.halt()
  end
end
