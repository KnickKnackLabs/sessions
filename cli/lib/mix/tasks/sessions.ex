defmodule Mix.Tasks.Sessions do
  @shortdoc "Run the sessions CLI"
  @moduledoc """
  Runs the sessions execution engine.

  ## Usage

      mix sessions --system-prompt-file <path> [options] <message>

  ## Examples

      mix sessions --system-prompt-file /tmp/prompt.txt --timeout 300 "Fix the bug"
      mix sessions --system-prompt-file ./prompt.txt --session ./session.jsonl "Continue"

  """
  use Mix.Task

  @impl Mix.Task
  def run(args) do
    args |> Cli.run() |> System.halt()
  end
end
