defmodule Cli.Harness.Pi.Command do
  @moduledoc """
  Pi command construction — builds the shell invocation passed to the
  port under `/bin/sh -c <script> -- $1 $2 ...`.

  User-controlled strings (message, model, system prompt file, session
  path) are passed as positional `$1`/`$2`/... args so they never enter
  the shell script as interpolated text.

  See `Cli.Harness.Pi` for the multi-harness plan (sessions#50).
  """

  @default_model "claude-opus-4-6"

  @doc "Default model when the caller doesn't pass --model."
  @spec default_model() :: String.t()
  def default_model, do: @default_model

  @doc """
  Build the shell script + positional args for running pi.

  Returns `{shell_script, positional_args}`. The caller passes
  `positional_args` after `--` to `/bin/sh -c`.
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
end
