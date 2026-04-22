defmodule Cli.UsageReport do
  @moduledoc """
  Renders the `Run Metrics:` block printed after a `sessions run`
  completes.

  Reads a harness-agnostic usage map populated by the harness's stream
  parser (see `Cli.Harness.Pi.Stream.handle_agent_end/2`). Does nothing
  when `state.usage` is `nil`.
  """

  @doc """
  Print the run-metrics block for a completed run state. No-op when
  usage data is absent.
  """
  @spec print(map()) :: :ok
  def print(%{usage: nil}), do: :ok

  def print(%{usage: usage}) do
    IO.puts("\n---")
    IO.puts("Run Metrics:")

    if usage.duration_ms do
      duration_s = :erlang.float_to_binary(usage.duration_ms / 1000, decimals: 1)
      IO.puts("  Duration: #{duration_s}s")
    end

    if usage.num_turns, do: IO.puts("  Turns: #{usage.num_turns}")

    if usage.cost_usd do
      cost = :erlang.float_to_binary(usage.cost_usd / 1, decimals: 4)
      IO.puts("  Cost: $#{cost}")
    end

    if usage.usage do
      input = Map.get(usage.usage, "input_tokens", 0)
      output = Map.get(usage.usage, "output_tokens", 0)
      cache_read = Map.get(usage.usage, "cache_read_input_tokens", 0)
      cache_create = Map.get(usage.usage, "cache_creation_input_tokens", 0)

      IO.puts("  Tokens: #{input} in, #{output} out")

      if cache_read > 0 or cache_create > 0 do
        IO.puts("  Cache: #{cache_read} read, #{cache_create} created")
      end
    end
  end
end
