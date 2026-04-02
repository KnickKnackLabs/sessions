defmodule Cli do
  @moduledoc """
  Session execution engine — runs pi with streaming output, timeout,
  ABORT detection, and usage reporting.

  Identity-agnostic: receives a system prompt file, doesn't know or care
  what's in it. Prompt composition (identity, passphrase, context) is the
  caller's responsibility.
  """

  use Application

  @impl Application
  def start(_type, _args) do
    Task.start(fn ->
      args = get_argv()
      exit_code = run(args)
      System.halt(exit_code)
    end)
  end

  defp get_argv do
    if Code.ensure_loaded?(Burrito.Util.Args) do
      apply(Burrito.Util.Args, :argv, [])
    else
      System.argv()
    end
  end

  @default_model "claude-opus-4-6"
  @truncate_edit_limit 60
  @truncate_prompt_limit 100
  @buffer_flush_timeout_ms 100
  @timeout_exit_code 124

  @spec main([String.t()]) :: no_return()
  def main(args) do
    args |> run() |> System.halt()
  end

  @spec run([String.t()]) :: non_neg_integer()
  def run(args) do
    {opts, rest} = parse_args(args)

    if opts[:help] do
      print_help()
      0
    else
      run_with_opts(opts, rest)
    end
  end

  defp run_with_opts(opts, rest) do
    message = Enum.join(rest, " ")
    timeout = opts[:timeout]
    model = opts[:model] || @default_model
    cwd = opts[:cwd]
    session = opts[:session]

    # Extension flags default to true (enabled) unless explicitly disabled
    extensions = opts[:no_extensions] != true
    skills = opts[:no_skills] != true
    prompt_templates = opts[:no_prompt_templates] != true

    print_header(opts, message, timeout, model)

    case validate_args(message, opts[:system_prompt_file]) do
      {:error, msg} ->
        IO.puts("ERROR: #{msg}")
        1

      :ok ->
        system_prompt_file = opts[:system_prompt_file]

        run_agent(message, system_prompt_file, timeout, model, cwd, session,
          extensions: extensions,
          skills: skills,
          prompt_templates: prompt_templates
        )
    end
  end

  defp print_header(opts, message, timeout, model) do
    IO.puts("Running at: #{DateTime.utc_now()}")
    IO.puts("Message: #{message}")
    if timeout, do: IO.puts("Timeout: #{timeout}s")
    if opts[:system_prompt_file], do: IO.puts("System prompt: #{opts[:system_prompt_file]}")
    IO.puts("Model: #{model}")
    if opts[:session], do: IO.puts("Session: #{opts[:session]}")
    if opts[:cwd], do: IO.puts("Working dir: #{opts[:cwd]}")
    IO.puts("---")
  end

  defp validate_args(message, system_prompt_file) do
    cond do
      String.trim(message) == "" ->
        {:error, "No message provided"}

      system_prompt_file == nil or system_prompt_file == "" ->
        {:error, "--system-prompt-file is required"}

      not File.exists?(system_prompt_file) ->
        {:error, "System prompt file not found: #{system_prompt_file}"}

      true ->
        :ok
    end
  end

  defp parse_args(args) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          system_prompt_file: :string,
          timeout: :integer,
          model: :string,
          cwd: :string,
          session: :string,
          no_extensions: :boolean,
          no_skills: :boolean,
          no_prompt_templates: :boolean,
          help: :boolean
        ],
        aliases: [h: :help]
      )

    Enum.each(invalid, fn
      {name, nil} ->
        IO.puts("WARNING: Unknown argument ignored: #{name}")

      {"--timeout", value} ->
        IO.puts("ERROR: --timeout requires an integer value, got: #{value}")

      {name, value} ->
        IO.puts("WARNING: Invalid argument: #{name}=#{value}")
    end)

    {opts, rest}
  end

  defp print_help do
    IO.puts("""
    Usage: sessions run --system-prompt-file <path> [options] <message>

    Run a pi agent session with streaming output, timeout, and ABORT detection.

    Required:
      --system-prompt-file <path>  Path to the system prompt file

    Options:
      --timeout <seconds>          Maximum runtime in seconds (default: no timeout)
      --model <model>              Model to use (default: #{@default_model})
      --cwd <path>                 Working directory for pi
      --session <path>             Session file for conversation continuity
      --no-extensions              Disable pi extensions
      --no-skills                  Disable pi skills
      --no-prompt-templates        Disable pi prompt templates
      -h, --help                   Show this help message

    Examples:
      sessions run --system-prompt-file /tmp/prompt.txt "Fix the bug"
      sessions run --system-prompt-file ./prompt.txt --timeout 300 "Explore"
      sessions run --session ./session.jsonl --system-prompt-file ./prompt.txt "Continue"
    """)
  end

  defp run_agent(message, system_prompt_file, timeout, model, cwd, session, pi_opts) do
    # Ensure model includes a provider prefix (e.g. "anthropic/claude-opus-4-6").
    qualified_model =
      if String.contains?(model, "/"), do: model, else: "anthropic/#{model}"

    # Build pi flags
    pi_flags =
      [
        ~s( --append-system-prompt "#{system_prompt_file}"),
        ~s( --model "$2"),
        " --mode json",
        if(session, do: ~s( --session "#{session}"), else: " --no-session"),
        if(pi_opts[:extensions], do: "", else: " --no-extensions"),
        if(pi_opts[:skills], do: "", else: " --no-skills"),
        if(pi_opts[:prompt_templates], do: "", else: " --no-prompt-templates")
      ]
      |> Enum.join("")

    # Build the shell command. $1=message, $2=model are positional to avoid injection.
    pi_cmd = ~s(pi -p "$1"#{pi_flags})

    shell_script =
      if timeout do
        "echo | timeout #{timeout} #{pi_cmd}"
      else
        "echo | #{pi_cmd}"
      end

    args = ["-c", shell_script, "--", message, qualified_model]

    port_opts = [:binary, :exit_status, :stderr_to_stdout, {:args, args}]
    port_opts = if cwd, do: [{:cd, cwd} | port_opts], else: port_opts

    port =
      Port.open(
        {:spawn_executable, "/bin/sh"},
        port_opts
      )

    status =
      stream_output(port, %{
        tool_input: "",
        buffer: "",
        usage: nil,
        abort_seen: false,
        recent_text: "",
        flushed_chars: 0,
        had_newline_before_window: true
      })

    if timeout && status == @timeout_exit_code do
      IO.puts("\n---")
      IO.puts("ERROR: Agent timed out after #{timeout} seconds")
    end

    status
  end

  defp stream_output(port, %{buffer: buffer} = state) do
    receive do
      {^port, {:data, data}} ->
        combined = buffer <> data
        lines = String.split(combined, "\n")
        {complete_lines, [new_buffer]} = Enum.split(lines, -1)

        new_state =
          complete_lines
          |> Enum.reject(&(&1 == ""))
          |> Enum.reduce(%{state | buffer: new_buffer}, &process_line/2)

        stream_output(port, new_state)

      {^port, {:exit_status, status}} ->
        final_state = finalize_buffer(buffer, state)
        print_usage_summary(final_state)

        if final_state.abort_seen do
          IO.puts("\n---")
          IO.puts("Agent requested session abort via [[ABORT]]")
          1
        else
          status
        end
    after
      @buffer_flush_timeout_ms ->
        case buffer do
          "" ->
            stream_output(port, state)

          partial ->
            extracted = extract_partial_text(partial)
            new_text = text_beyond_flushed(extracted, state.flushed_chars)
            if new_text != "", do: IO.write(new_text)
            stream_output(port, %{state | flushed_chars: String.length(extracted)})
        end
    end
  end

  defp finalize_buffer("", state), do: state

  defp finalize_buffer(buffer, state) do
    case Jason.decode(buffer) do
      {:ok, _} ->
        process_line(buffer, state)

      {:error, _} ->
        extracted = extract_partial_text(buffer)
        new_text = text_beyond_flushed(extracted, state.flushed_chars)
        if new_text != "", do: IO.write(new_text)

        {abort_seen, recent_text, had_newline} = check_abort_signal(extracted, state)

        %{
          state
          | abort_seen: abort_seen,
            recent_text: recent_text,
            had_newline_before_window: had_newline
        }
    end
  end

  @doc """
  Extract text from incomplete JSON lines in the buffer.
  Returns the unescaped text, or empty string if none found.
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
  Flush incomplete JSON lines from the buffer to stdout.
  """
  @spec flush_partial_buffer(String.t()) :: :ok
  def flush_partial_buffer(partial) do
    case extract_partial_text(partial) do
      "" -> :ok
      text -> IO.write(text)
    end
  end

  @typep stream_state :: %{
           tool_input: String.t(),
           buffer: String.t(),
           usage: map() | nil,
           abort_seen: boolean(),
           recent_text: String.t(),
           flushed_chars: non_neg_integer(),
           had_newline_before_window: boolean()
         }

  @doc """
  Detect [[ABORT]] signal on its own line, handling chunk boundaries.
  Returns {abort_seen, recent_text, had_newline_before_window}.
  """
  @spec check_abort_signal(String.t(), stream_state()) ::
          {boolean(), String.t(), boolean()}
  def check_abort_signal(text, state) do
    combined = state.recent_text <> text
    combined_len = String.length(combined)

    trimmed_len = max(0, combined_len - 20)
    trimmed_portion = String.slice(combined, 0, trimmed_len)

    had_newline_before_window =
      if String.contains?(trimmed_portion, "\n"),
        do: true,
        else: state.had_newline_before_window

    text_to_check =
      if had_newline_before_window, do: "\n" <> combined, else: combined

    abort_seen =
      state.abort_seen ||
        Regex.match?(~r/(?:^|\n)\[\[ABORT\]\](?:\n|$)/, text_to_check)

    recent_text = String.slice(combined, -20, 20)

    {abort_seen, recent_text, had_newline_before_window}
  end

  @doc false
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

  defp handle_text_delta(text, state) do
    text_to_write = text_beyond_flushed(text, state.flushed_chars)
    maybe_write_text(text_to_write)

    {abort_seen, recent_text, had_newline} = check_abort_signal(text, state)

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

  @doc """
  Returns the portion of `text` beyond already-flushed characters.

  ## Examples

      iex> Cli.text_beyond_flushed("hello world", 5)
      " world"

      iex> Cli.text_beyond_flushed("hello", 5)
      ""

      iex> Cli.text_beyond_flushed("hello", 0)
      "hello"

      iex> Cli.text_beyond_flushed("hi", 10)
      ""

  """
  @spec text_beyond_flushed(String.t(), non_neg_integer()) :: String.t()
  def text_beyond_flushed(text, 0), do: text

  def text_beyond_flushed(text, flushed_chars) when is_integer(flushed_chars) do
    if String.length(text) > flushed_chars do
      String.slice(text, flushed_chars..-1//1)
    else
      ""
    end
  end

  defp print_usage_summary(%{usage: nil}), do: :ok

  defp print_usage_summary(%{usage: usage}) do
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

  defp print_tool_input(input) do
    case format_tool_input(input) do
      nil -> :ok
      output -> IO.puts(output)
    end
  end

  @doc """
  Formats tool input map into a human-readable string for display.
  Returns nil for unrecognized input formats.
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

  defp truncate(nil, _limit), do: ""

  defp truncate(string, limit) do
    if String.length(string) > limit do
      String.slice(string, 0, limit) <> "..."
    else
      string
    end
  end
end
