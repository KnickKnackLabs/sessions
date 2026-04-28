defmodule Cli do
  @moduledoc """
  `sessions run` — entry point, argument parsing, and help output.

  Identity-agnostic: receives a system prompt file, doesn't know or care
  what's in it. Prompt composition (identity, passphrase, context) is the
  caller's responsibility.

  Run execution (port spawning, streaming, timeout) lives in
  `Cli.Engine`; usage reporting lives in `Cli.UsageReport`; harness
  specifics live under `Cli.Harness.*`. See sessions#50 for the
  multi-harness plan.
  """

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
      try do
        run_with_opts(opts, rest)
      rescue
        e in Cli.Harness.UnsupportedError ->
          # Clean UNSUPPORTED path: short message to stderr, reserved
          # exit code so wrapping shells can branch. No stacktrace —
          # this is an expected "not yet implemented for this adapter"
          # signal, not a bug.
          IO.puts(:stderr, "sessions: #{Exception.message(e)}")
          Cli.Harness.UnsupportedError.exit_code()
      end
    end
  end

  defp run_with_opts(opts, rest) do
    message = Enum.join(rest, " ")
    timeout = opts[:timeout]
    session = opts[:session]
    # Resolve the harness once here and pass it down. `Cli.Engine.run`
    # used to re-resolve from the session file, which meant reading
    # the JSONL twice on every invocation.
    harness = Cli.Harness.resolve(session: session)
    model = opts[:model]
    cwd = opts[:cwd]

    # Extension flags default to true (enabled) unless explicitly disabled.
    extensions = opts[:no_extensions] != true
    skills = opts[:no_skills] != true
    prompt_templates = opts[:no_prompt_templates] != true

    print_header(opts, message, timeout, model)

    case validate_args(message, opts) do
      {:error, msg} ->
        IO.puts("ERROR: #{msg}")
        1

      :ok ->
        Cli.Engine.run(
          harness,
          message,
          opts[:system_prompt_file],
          timeout,
          model,
          cwd,
          session,
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

  defp validate_args(message, opts) do
    system_prompt_file = opts[:system_prompt_file]
    cond do
      String.trim(message) == "" ->
        {:error, "No message provided"}

      opts[:model] == nil or opts[:model] == "" ->
        {:error, "--model is required"}

      not String.contains?(opts[:model], "/") ->
        {:error, "--model must be provider-qualified (for example: openai/gpt-5.5)"}

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
    Usage: sessions run --system-prompt-file <path> --model <provider/model> [options] <message>

    Run a pi agent session with streaming output, timeout, and ABORT detection.

    Required:
      --system-prompt-file <path>  Path to the system prompt file
      --model <provider/model>     Provider-qualified model to use

    Options:
      --timeout <seconds>          Maximum runtime in seconds (default: no timeout)
      --cwd <path>                 Working directory for pi
      --session <path>             Session file for conversation continuity
      --no-extensions              Disable pi extensions
      --no-skills                  Disable pi skills
      --no-prompt-templates        Disable pi prompt templates
      -h, --help                   Show this help message

    Examples:
      sessions run --system-prompt-file /tmp/prompt.txt --model openai/gpt-5.5 "Fix the bug"
      sessions run --system-prompt-file ./prompt.txt --model openai/gpt-5.5 --timeout 300 "Explore"
      sessions run --session ./session.jsonl --system-prompt-file ./prompt.txt --model openai/gpt-5.5 "Continue"
    """)
  end
end
