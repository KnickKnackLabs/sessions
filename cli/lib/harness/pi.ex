defmodule Cli.Harness.Pi do
  @moduledoc """
  Pi harness adapter — public API.

  `Cli.Engine` and `Cli` receive a resolved adapter module from
  `Cli.Harness.resolve/1` and call this module's functions. The
  implementation is split across submodules (`Command`, `Stream`,
  `ToolInput`) for file-size hygiene, but the engine only knows this
  façade.
  """

  defdelegate build_command(message, model, system_prompt_file, session, timeout, opts),
    to: Cli.Harness.Pi.Command

  defdelegate process_line(line, state), to: Cli.Harness.Pi.Stream

  defdelegate extract_partial_text(partial), to: Cli.Harness.Pi.Stream
end
