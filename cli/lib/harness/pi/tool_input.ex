defmodule Cli.Harness.Pi.ToolInput do
  @moduledoc """
  Formats the `arguments` map of a pi `toolCall` into a human-readable
  summary for the streaming-output display.

  Every public head pattern-matches a specific tool shape (bash command,
  edit array, grep pattern, webfetch, etc.). The fallback head returns
  `nil` so callers can skip unrecognized shapes.

  See `Cli.Harness.Pi` for the multi-harness plan (sessions#50).
  """

  @truncate_edit_limit 60
  @truncate_prompt_limit 100

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

  defp truncate(nil, _limit), do: ""

  defp truncate(string, limit) do
    if String.length(string) > limit do
      String.slice(string, 0, limit) <> "..."
    else
      string
    end
  end
end
