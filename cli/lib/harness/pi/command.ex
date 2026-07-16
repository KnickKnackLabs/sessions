defmodule Cli.Harness.Pi.Command do
  @moduledoc """
  Pi command construction — builds the shell invocation passed to the
  port under `/bin/sh -c <script> -- $1 $2 ...`.

  User-controlled strings and the Sessions-selected Pi executable are passed
  as positional `$1`/`$2`/... args so they never enter the shell script as
  interpolated text.

  Part of the pi harness adapter — see sessions#50 for the
  multi-harness plan.
  """

  @typep build_opts :: [
           extensions: boolean(),
           skills: boolean(),
           prompt_templates: boolean(),
           project_trust: String.t(),
           harness_executable: String.t()
         ]

  @doc """
  Build the shell script + positional args for running pi.

  Returns `{shell_script, positional_args}`. The caller passes
  `positional_args` after `--` to `/bin/sh -c`.

  `opts` controls pi's extension/skills/prompt-template flags. Missing
  keys default to enabled.
  """
  @spec build_command(
          message :: String.t(),
          model :: String.t(),
          system_prompt_file :: String.t() | nil,
          session :: String.t() | nil,
          timeout :: non_neg_integer() | nil,
          opts :: build_opts()
        ) :: {String.t(), [String.t()]}
  def build_command(message, model, system_prompt_file, session, timeout, opts \\ []) do
    extensions = Keyword.get(opts, :extensions, true)
    skills = Keyword.get(opts, :skills, true)
    prompt_templates = Keyword.get(opts, :prompt_templates, true)
    project_trust_flag = project_trust_flag(Keyword.get(opts, :project_trust, "inherit"))
    executable = harness_executable(opts)

    qualified_model = model

    {prompt_flag, positional_after_prompt} =
      if system_prompt_file && system_prompt_file != "" do
        positional = [message, qualified_model, system_prompt_file]
        {~s( --append-system-prompt "$3"), positional}
      else
        {"", [message, qualified_model]}
      end

    {session_flag, positional} =
      if session do
        session_arg = "$#{length(positional_after_prompt) + 1}"
        {~s( --session "#{session_arg}"), positional_after_prompt ++ [session]}
      else
        {" --no-session", positional_after_prompt}
      end

    executable_arg = "$#{length(positional) + 1}"
    positional = positional ++ [executable]

    pi_flags =
      [
        prompt_flag,
        ~s( --model "$2"),
        " --mode json",
        session_flag,
        project_trust_flag,
        if(extensions, do: "", else: " --no-extensions"),
        if(skills, do: "", else: " --no-skills"),
        if(prompt_templates, do: "", else: " --no-prompt-templates")
      ]
      |> Enum.join("")

    pi_cmd = ~s("#{executable_arg}" -p "$1"#{pi_flags})

    # `echo |` pipes empty stdin so pi doesn't block waiting for a TTY.
    shell_script =
      if timeout do
        "echo | timeout #{timeout} #{pi_cmd}"
      else
        "echo | #{pi_cmd}"
      end

    {shell_script, positional}
  end

  defp harness_executable(opts) do
    case Keyword.fetch(opts, :harness_executable) do
      {:ok, executable} when is_binary(executable) and executable != "" ->
        if Path.type(executable) == :absolute do
          executable
        else
          raise ArgumentError, "pi harness executable must be an absolute path"
        end

      _ ->
        raise ArgumentError, "pi harness executable is required"
    end
  end

  defp project_trust_flag("inherit"), do: ""
  defp project_trust_flag("approve"), do: " --approve"
  defp project_trust_flag("deny"), do: " --no-approve"

  defp project_trust_flag(policy) do
    raise ArgumentError, "unknown project trust policy: #{inspect(policy)}"
  end
end
