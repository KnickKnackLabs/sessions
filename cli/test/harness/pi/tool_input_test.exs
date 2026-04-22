defmodule Cli.Harness.Pi.ToolInputTest do
  use ExUnit.Case

  alias Cli.Harness.Pi.ToolInput

  describe "format_tool_input/1" do
    test "formats bash command input" do
      input = %{"command" => "ls -la"}
      assert ToolInput.format_tool_input(input) == "  $ ls -la"
    end

    test "formats pi read/write tool input with path" do
      input = %{"path" => "/path/to/file.ex"}
      assert ToolInput.format_tool_input(input) == "  -> /path/to/file.ex"
    end

    test "formats pattern input for Glob tool" do
      input = %{"pattern" => "**/*.ex"}
      assert ToolInput.format_tool_input(input) == "  pattern: **/*.ex"
    end

    test "formats pattern input for Grep tool with path" do
      input = %{"pattern" => "def main", "path" => "cli/lib/cli.ex"}
      assert ToolInput.format_tool_input(input) == "  cli/lib/cli.ex\n  pattern: def main"
    end

    test "formats pi edit tool input with edits array" do
      input = %{
        "path" => "/path/to/file.ex",
        "edits" => [%{"oldText" => "old code here", "newText" => "new code here"}]
      }

      result = ToolInput.format_tool_input(input)
      assert result =~ "  /path/to/file.ex"
      assert result =~ "  - old code here"
      assert result =~ "  + new code here"
      refute result =~ "old code here..."
      refute result =~ "new code here..."
    end

    test "truncates long oldText and newText in pi edit tool" do
      long_string = String.duplicate("x", 100)

      input = %{
        "path" => "/path/to/file.ex",
        "edits" => [%{"oldText" => long_string, "newText" => long_string}]
      }

      result = ToolInput.format_tool_input(input)
      assert result =~ String.duplicate("x", 60) <> "..."
    end

    test "replaces newlines in pi edit tool strings" do
      input = %{
        "path" => "/path/to/file.ex",
        "edits" => [%{"oldText" => "line1\nline2", "newText" => "line3\nline4"}]
      }

      result = ToolInput.format_tool_input(input)
      assert result =~ "line1\\nline2"
      assert result =~ "line3\\nline4"
    end

    test "formats TodoWrite tool input with map todos" do
      input = %{
        "todos" => [
          %{"content" => "First task", "status" => "in_progress", "activeForm" => "Doing first"},
          %{"content" => "Second task", "status" => "pending", "activeForm" => "Doing second"}
        ]
      }

      result = ToolInput.format_tool_input(input)
      assert result == "  2 todo(s): First task"
    end

    test "formats TodoWrite tool input with empty todos list" do
      input = %{"todos" => []}

      result = ToolInput.format_tool_input(input)
      assert result == "  0 todo(s)"
    end

    test "handles TodoWrite with non-map todo items gracefully" do
      input = %{"todos" => ["Task 1", "Task 2"]}

      result = ToolInput.format_tool_input(input)
      assert result == "  2 todo(s)"
    end

    test "handles TodoWrite with mixed todo items gracefully" do
      input = %{"todos" => [nil, %{"content" => "Valid task"}]}

      result = ToolInput.format_tool_input(input)
      assert result == "  2 todo(s)"
    end

    test "formats WebFetch tool input with prompt" do
      input = %{
        "prompt" => "Extract the main content",
        "description" => "Fetching docs"
      }

      result = ToolInput.format_tool_input(input)
      assert result =~ "  Fetching docs"
      assert result =~ "  prompt: Extract the main content"
      refute result =~ "Extract the main content..."
    end

    test "formats WebFetch tool input with url and prompt" do
      input = %{
        "url" => "https://example.com/docs",
        "prompt" => "Extract the main content",
        "description" => "Fetching docs"
      }

      result = ToolInput.format_tool_input(input)
      assert result =~ "  Fetching docs"
      assert result =~ "  url: https://example.com/docs"
      assert result =~ "  prompt: Extract the main content"
      refute result =~ "Extract the main content..."
    end

    test "formats WebFetch tool input with url but no description" do
      input = %{
        "url" => "https://example.com",
        "prompt" => "Get content"
      }

      result = ToolInput.format_tool_input(input)
      assert result == "  url: https://example.com\n  prompt: Get content"
    end

    test "formats WebFetch tool input with url and empty description" do
      input = %{
        "url" => "https://example.com",
        "prompt" => "Get content",
        "description" => ""
      }

      result = ToolInput.format_tool_input(input)
      assert result == "  url: https://example.com\n  prompt: Get content"
    end

    test "formats prompt input without description" do
      input = %{"prompt" => "Some prompt text"}
      result = ToolInput.format_tool_input(input)
      assert result == "  prompt: Some prompt text"
      refute result =~ "Some prompt text..."
    end

    test "truncates long prompts to 100 chars" do
      long_prompt = String.duplicate("a", 150)
      input = %{"prompt" => long_prompt}

      result = ToolInput.format_tool_input(input)
      assert result =~ String.duplicate("a", 100) <> "..."
      refute result =~ String.duplicate("a", 101)
    end

    test "returns nil for unrecognized input format" do
      assert ToolInput.format_tool_input(%{"unknown" => "value"}) == nil
      assert ToolInput.format_tool_input(%{}) == nil
    end
  end
end
