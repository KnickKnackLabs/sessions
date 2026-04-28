defmodule Cli.Harness.Claude do
  @moduledoc """
  Claude harness adapter — step 3 skeleton.

  Every function raises `Cli.Harness.UnsupportedError`. The CLI
  boundary (`Cli.run/1`) rescues it and exits with the reserved
  UNSUPPORTED exit code. Step 5 will fill in a real command builder
  and stream parser for `claude -p --output-format stream-json`.
  """

  alias Cli.Harness.UnsupportedError

  def build_command(_message, _model, _system_prompt_file, _session, _timeout, _opts) do
    raise UnsupportedError, harness: :claude, op: :build_command
  end

  def process_line(_line, _state) do
    raise UnsupportedError, harness: :claude, op: :process_line
  end

  def extract_partial_text(_partial) do
    raise UnsupportedError, harness: :claude, op: :extract_partial_text
  end
end
