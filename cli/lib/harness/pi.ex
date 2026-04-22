defmodule Cli.Harness.Pi do
  @moduledoc """
  Pi harness adapter (Elixir).

  Authoritative home for pi-specific knowledge used by `sessions run`:

    * How to invoke the pi CLI (command + flags)
    * Pi's streaming JSON protocol (`message_update` events with
      `assistantMessageEvent` sub-types, `agent_end`, `toolcall_*`, etc.)
    * Pi's tool-input argument shapes
    * Pi's `usage` shape in `agent_end`

  Step 1c of multi-harness support (sessions#50): pure extraction from
  `Cli`. `Cli` keeps orchestration (arg parsing, port spawning, stream
  loop, abort detection) and delegates harness-specific work here.
  Other harnesses (claude, ...) will live in sibling modules
  (`Cli.Harness.Claude`, etc.); step 2 adds a dispatcher.

  Functions exposed here as `@doc` are part of the shared contract every
  harness will implement once the dispatcher lands.
  """

  @default_model "claude-opus-4-6"
  @truncate_edit_limit 60
  @truncate_prompt_limit 100

  @doc "Default model when the caller doesn't pass --model."
  @spec default_model() :: String.t()
  def default_model, do: @default_model

  # --- Command construction ---

  @doc """
  Build the args list passed to `/bin/sh -c <script> -- $1 $2 ...` when
  launching pi under a port.

  Returns `{shell_script, positional_args}`. Positional args use
  `$1`/`$2`/... so user-controlled strings (message, model,
  system_prompt_file, session) are shell-safe.
  """
  @spec build_command(
          message :: String.t(),
          model :: String.t(),
          system_prompt_file :: String.t(),
          session :: String.t() | nil,
          timeout :: non_neg_integer() | nil,
          extensions :: boolean(),
          skills :: boolean(),
          prompt_templates :: boolean()
        ) :: {String.t(), [String.t()]}
  def build_command(
        message,
        model,
        system_prompt_file,
        session,
        timeout,
        extensions,
        skills,
        prompt_templates
      ) do
    qualified_model =
      if String.contains?(model, "/"), do: model, else: "anthropic/#{model}"

    session_flag =
      if session, do: ~s( --session "$4"), else: " --no-session"

    pi_flags =
      [
        ~s( --append-system-prompt "$3"),
        ~s( --model "$2"),
        " --mode json",
        session_flag,
        if(extensions, do: "", else: " --no-extensions"),
        if(skills, do: "", else: " --no-skills"),
        if(prompt_templates, do: "", else: " --no-prompt-templates")
      ]
      |> Enum.join("")

    pi_cmd = ~s(pi -p "$1"#{pi_flags})

    # `echo |` pipes empty stdin so pi doesn't block waiting for a TTY.
    shell_script =
      if timeout do
        "echo | timeout #{timeout} #{pi_cmd}"
      else
        "echo | #{pi_cmd}"
      end

    positional = [message, qualified_model, system_prompt_file]
    positional = if session, do: positional ++ [session], else: positional

    {shell_script, positional}
  end

  # --- Streaming protocol ---

  @typep stream_state :: %{
           optional(:tool_input) => String.t(),
           optional(:usage) => map() | nil,
           optional(:abort_seen) => boolean(),
           optional(:recent_text) => String.t(),
           optional(:flushed_chars) => non_neg_integer(),
           optional(:had_newline_before_window) => boolean(),
           optional(:buffer) => String.t()
         }

  @doc """
  Consume one line of pi's JSON stream and return the updated state.

  Text deltas are written to stdout as they arrive and fed into the
  (harness-agnostic) abort detector in `Cli.Text`. Tool events print
  tool names and formatted arguments. `agent_end` events capture usage
  totals. Unknown / malformed / unrelated events pass through untouched.
  """
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
  Extract partial text from an incomplete JSON line buffered mid-stream.

  Pi's text-carrying events emit `"delta":"..."` (or `"text":"..."` in
  some paths); we look for the trailing unclosed string and unescape it.
  Returns empty string if no partial text can be recovered.
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

  # --- Tool input formatting ---

  @doc """
  Format a pi tool-call's `arguments` map into a human-readable summary.
  Returns `nil` for unrecognized shapes so callers can skip output.
  """
  @spec format_tool_input(map()) :: String.t() | nil
  def format_tool_input(%{"command" => cmd}) do
    "  $ #{cmd}"
  end

  def format_tool_input(%{"path" => path, "edits" => [first | _]}) when is_map(first) do
    old =
      first
      |> Map.get("oldText", "")
      |> truncate(@truncate_edit_limit)
      |> String.replace("\n", "\\n")

    new =
      first
      |> Map.get("newText", "")
      |> truncate(@truncate_edit_limit)
      |> String.replace("\n", "\\n")

    "  #{path}\n  - #{old}\n  + #{new}"
  end

  def format_tool_input(%{"pattern" => pattern} = input) do
    case Map.get(input, "path") do
      nil -> "  pattern: #{pattern}"
      path -> "  #{path}\n  pattern: #{pattern}"
    end
  end

  def format_tool_input(%{"path" => path}) do
    "  -> #{path}"
  end

  def format_tool_input(%{"url" => url, "prompt" => prompt} = input) do
    prompt_preview = truncate(prompt, @truncate_prompt_limit)

    case Map.get(input, "description") do
      desc when desc in [nil, ""] -> "  url: #{url}\n  prompt: #{prompt_preview}"
      desc -> "  #{desc}\n  url: #{url}\n  prompt: #{prompt_preview}"
    end
  end

  def format_tool_input(%{"prompt" => prompt} = input) do
    prompt_preview = truncate(prompt, @truncate_prompt_limit)

    case Map.get(input, "description") do
      desc when desc in [nil, ""] -> "  prompt: #{prompt_preview}"
      desc -> "  #{desc}\n  prompt: #{prompt_preview}"
    end
  end

  def format_tool_input(%{"todos" => todos}) when is_list(todos) do
    count = length(todos)
    first = List.first(todos)

    preview =
      case first do
        %{"content" => content} when is_binary(content) -> ": #{truncate(content, 50)}"
        _ -> ""
      end

    "  #{count} todo(s)#{preview}"
  end

  def format_tool_input(%{"query" => query}) do
    "  search: #{truncate(query, 80)}"
  end

  def format_tool_input(%{"operation" => op, "filePath" => path, "line" => line}) do
    "  #{op} at #{path}:#{line}"
  end

  def format_tool_input(%{"skill" => skill} = input) do
    case Map.get(input, "args") do
      nil -> "  skill: #{skill}"
      args -> "  skill: #{skill} #{truncate(args, 50)}"
    end
  end

  def format_tool_input(%{"shell_id" => id}) do
    "  shell: #{id}"
  end

  def format_tool_input(_), do: nil

  # --- Internal helpers ---

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
    case format_tool_input(input) do
      nil -> :ok
      output -> IO.puts(output)
    end
  end

  defp truncate(nil, _limit), do: ""

  defp truncate(string, limit) do
    if String.length(string) > limit do
      String.slice(string, 0, limit) <> "..."
    else
      string
    end
  end
end
