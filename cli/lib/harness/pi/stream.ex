defmodule Cli.Harness.Pi.Stream do
  @moduledoc """
  Pi streaming protocol parser for the `sessions run` engine.

  Consumes one JSONL line of pi's stream at a time via `process_line/2`.
  Text deltas are written to stdout as they arrive and fed into the
  (harness-agnostic) abort detector in `Cli.Text`. Tool events print
  tool names and formatted arguments (via `Cli.Harness.Pi.ToolInput`).
  `agent_end` events capture usage totals into state.

  Unknown / malformed / unrelated events pass through untouched.

  Part of the pi harness adapter — see sessions#50 for the
  multi-harness plan.
  """

  @typep stream_state :: %{
           optional(:tool_input) => String.t(),
           optional(:usage) => map() | nil,
           optional(:abort_seen) => boolean(),
           optional(:recent_text) => String.t(),
           optional(:flushed_chars) => non_neg_integer(),
           optional(:had_newline_before_window) => boolean(),
           optional(:buffer) => String.t()
         }

  @doc "Consume one line of pi's JSON stream and return the updated state."
  @spec process_line(String.t(), stream_state()) :: stream_state()
  def process_line(line, state) do
    case Jason.decode(line) do
      {:ok,
       %{
         "type" => "message_update",
         "assistantMessageEvent" => %{"type" => "text_delta", "delta" => text}
       }} ->
        handle_text_delta(text, state)

      {:ok,
       %{
         "type" => "message_update",
         "assistantMessageEvent" => %{"type" => "toolcall_start"} = event
       }} ->
        name = extract_tool_name_from_event(event)
        IO.puts("\n[TOOL] #{name}")
        %{state | tool_input: ""}

      {:ok,
       %{
         "type" => "message_update",
         "assistantMessageEvent" => %{"type" => "toolcall_delta", "delta" => json}
       }}
      when json != "" ->
        %{state | tool_input: state.tool_input <> json}

      {:ok,
       %{
         "type" => "message_update",
         "assistantMessageEvent" => %{"type" => "toolcall_end", "toolCall" => tool_call}
       }} ->
        handle_tool_call_end(tool_call, state)

      {:ok, %{"type" => "agent_end", "messages" => messages}} ->
        handle_agent_end(messages, state)

      _ ->
        state
    end
  end

  @doc """
  Extract text from an incomplete JSON line buffered mid-stream.

  Pi's text-carrying events emit `"delta":"..."` (or `"text":"..."` on
  some paths); we look for the trailing unclosed string and unescape it.
  Returns `""` if no partial text can be recovered.
  """
  @spec extract_partial_text(String.t()) :: String.t()
  def extract_partial_text(partial) do
    case Regex.run(~r/"(?:text|delta)"\s*:\s*"((?:[^"\\]|\\.)*)$/, partial) do
      [_, text] ->
        case Jason.decode("\"#{text}\"") do
          {:ok, unescaped} -> unescaped
          {:error, _} -> ""
        end

      nil ->
        ""
    end
  end

  @doc """
  Extract any recoverable text from a partial JSON buffer and write it
  to stdout. No-op when nothing can be recovered.

  Used by tests and debugging flows that exercise the partial-text path
  without the full stream loop.
  """
  @spec flush_partial_buffer(String.t()) :: :ok
  def flush_partial_buffer(partial) do
    case extract_partial_text(partial) do
      "" -> :ok
      text -> IO.write(text)
    end
  end

  # --- Internal handlers ---

  defp handle_text_delta(text, state) do
    text_to_write = Cli.Text.text_beyond_flushed(text, state.flushed_chars)
    maybe_write_text(text_to_write)

    {abort_seen, recent_text, had_newline} = Cli.Text.check_abort_signal(text, state)

    %{
      state
      | abort_seen: abort_seen,
        recent_text: recent_text,
        flushed_chars: 0,
        had_newline_before_window: had_newline
    }
  end

  defp maybe_write_text(""), do: :ok
  defp maybe_write_text(text), do: IO.write(text)

  defp handle_tool_call_end(tool_call, state) do
    case Map.get(tool_call, "arguments") do
      nil -> :ok
      args -> print_tool_input(args)
    end

    %{state | tool_input: ""}
  end

  defp handle_agent_end(messages, state) do
    assistant_msgs =
      Enum.filter(messages, fn msg ->
        msg["role"] == "assistant" && msg["usage"] != nil
      end)

    totals =
      Enum.reduce(
        assistant_msgs,
        %{input: 0, output: 0, cache_read: 0, cache_write: 0, cost: 0.0},
        fn msg, acc ->
          u = msg["usage"]
          cost = get_in(u, ["cost", "total"]) || 0.0

          %{
            input: acc.input + (u["input"] || 0),
            output: acc.output + (u["output"] || 0),
            cache_read: acc.cache_read + (u["cacheRead"] || 0),
            cache_write: acc.cache_write + (u["cacheWrite"] || 0),
            cost: acc.cost + cost
          }
        end
      )

    %{
      state
      | usage: %{
          cost_usd: totals.cost,
          duration_ms: nil,
          num_turns: length(assistant_msgs),
          usage: %{
            "input_tokens" => totals.input,
            "output_tokens" => totals.output,
            "cache_read_input_tokens" => totals.cache_read,
            "cache_creation_input_tokens" => totals.cache_write
          },
          model_usage: nil
        }
    }
  end

  defp extract_tool_name_from_event(%{
         "contentIndex" => idx,
         "partial" => %{"content" => content}
       }) do
    case Enum.at(content, idx) do
      %{"name" => name} -> name
      _ -> "unknown"
    end
  end

  defp extract_tool_name_from_event(_), do: "unknown"

  defp print_tool_input(input) do
    case Cli.Harness.Pi.ToolInput.format_tool_input(input) do
      nil -> :ok
      output -> IO.puts(output)
    end
  end
end
