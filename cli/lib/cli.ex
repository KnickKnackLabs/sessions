defmodule Cli do
  @moduledoc """
  Session execution engine — runs an agent harness with streaming output,
  timeout, ABORT detection, and usage reporting.

  Identity-agnostic: receives a system prompt file, doesn't know or care
  what's in it. Prompt composition (identity, passphrase, context) is the
  caller's responsibility.

  Today this engine only knows pi. All pi-specific logic lives in
  `Cli.Harness.Pi`; this module keeps the CLI surface, port spawning,
  stream loop, and harness-agnostic helpers (abort detection, usage
  summary). See sessions#50 for the multi-harness plan.
  """

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
    model = opts[:model] || Cli.Harness.Pi.default_model()
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
    default_model = Cli.Harness.Pi.default_model()

    IO.puts("""
    Usage: sessions run --system-prompt-file <path> [options] <message>

    Run a pi agent session with streaming output, timeout, and ABORT detection.

    Required:
      --system-prompt-file <path>  Path to the system prompt file

    Options:
      --timeout <seconds>          Maximum runtime in seconds (default: no timeout)
      --model <model>              Model to use (default: #{default_model})
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
    {shell_script, positional_args} =
      Cli.Harness.Pi.build_command(
        message,
        model,
        system_prompt_file,
        session,
        timeout,
        pi_opts[:extensions],
        pi_opts[:skills],
        pi_opts[:prompt_templates]
      )

    args = ["-c", shell_script, "--"] ++ positional_args

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

  # --- Delegating wrappers ---
  #
  # These exist so existing callers, tests, and doctests don't break
  # during the multi-harness refactor. Step 2 will make `process_line`
  # (and friends) dispatch on a harness resolved from session context.

  @doc """
  Extract text from incomplete JSON lines in the buffer.
  Returns the unescaped text, or empty string if none found.

  Delegates to the pi harness adapter today; will dispatch on harness
  in step 2.
  """
  @spec extract_partial_text(String.t()) :: String.t()
  defdelegate extract_partial_text(partial), to: Cli.Harness.Pi

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

  @doc """
  Format tool input map into a human-readable string for display.
  Returns nil for unrecognized input formats.
  """
  @spec format_tool_input(map()) :: String.t() | nil
  defdelegate format_tool_input(input), to: Cli.Harness.Pi

  @doc false
  @spec process_line(String.t(), map()) :: map()
  def process_line(line, state) do
    Cli.Harness.Pi.process_line(line, state,
      check_abort: &__MODULE__.check_abort_signal/2,
      text_beyond_flushed: &__MODULE__.text_beyond_flushed/2
    )
  end

  # --- Harness-agnostic helpers ---

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

  @typep abort_state :: %{
           optional(:abort_seen) => boolean(),
           optional(:recent_text) => String.t(),
           optional(:had_newline_before_window) => boolean()
         }

  @doc """
  Detect [[ABORT]] signal on its own line, handling chunk boundaries.
  Returns {abort_seen, recent_text, had_newline_before_window}.

  Harness-agnostic — operates on raw text, not on any specific event
  schema.
  """
  @spec check_abort_signal(String.t(), abort_state()) ::
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
end
