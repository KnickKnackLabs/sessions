defmodule Cli.Harness.Pi.CommandTest do
  use ExUnit.Case

  alias Cli.Harness.Pi.Command

  describe "build_command/6 — shell script" do
    test "builds a basic invocation with no timeout, session, or flags" do
      {script, _args} =
        Command.build_command("hi", "claude-sonnet-4-5", "/tmp/prompt.txt", nil, nil)

      assert script =~ "echo | pi -p \"$1\""
      assert script =~ ~s( --append-system-prompt "$3")
      assert script =~ ~s( --model "$2")
      assert script =~ " --mode json"
    end

    test "wraps the command in `timeout <N>` when timeout is given" do
      {script, _} =
        Command.build_command("hi", "claude-sonnet-4-5", "/tmp/prompt.txt", nil, 300)

      assert script =~ "echo | timeout 300 pi -p"
    end

    test "uses --session when a session path is given" do
      {script, _} =
        Command.build_command(
          "hi",
          "claude-sonnet-4-5",
          "/tmp/prompt.txt",
          "/tmp/session.jsonl",
          nil
        )

      assert script =~ ~s( --session "$4")
      refute script =~ " --no-session"
    end

    test "uses --no-session when no session path is given" do
      {script, _} =
        Command.build_command("hi", "claude-sonnet-4-5", "/tmp/prompt.txt", nil, nil)

      assert script =~ " --no-session"
      refute script =~ "--session \"$4\""
    end
  end

  describe "build_command/6 — feature flags" do
    test "defaults all feature flags to enabled (no --no-* flags in script)" do
      {script, _} =
        Command.build_command("hi", "claude-sonnet-4-5", "/tmp/prompt.txt", nil, nil)

      refute script =~ "--no-extensions"
      refute script =~ "--no-skills"
      refute script =~ "--no-prompt-templates"
    end

    test "adds --no-extensions when extensions: false" do
      {script, _} =
        Command.build_command("hi", "claude-sonnet-4-5", "/tmp/prompt.txt", nil, nil,
          extensions: false
        )

      assert script =~ "--no-extensions"
    end

    test "adds --no-skills when skills: false" do
      {script, _} =
        Command.build_command("hi", "claude-sonnet-4-5", "/tmp/prompt.txt", nil, nil,
          skills: false
        )

      assert script =~ "--no-skills"
    end

    test "adds --no-prompt-templates when prompt_templates: false" do
      {script, _} =
        Command.build_command("hi", "claude-sonnet-4-5", "/tmp/prompt.txt", nil, nil,
          prompt_templates: false
        )

      assert script =~ "--no-prompt-templates"
    end

    test "combines multiple disabled flags" do
      {script, _} =
        Command.build_command("hi", "claude-sonnet-4-5", "/tmp/prompt.txt", nil, nil,
          extensions: false,
          skills: false,
          prompt_templates: false
        )

      assert script =~ "--no-extensions"
      assert script =~ "--no-skills"
      assert script =~ "--no-prompt-templates"
    end
  end

  describe "build_command/6 — positional args" do
    test "returns [message, model, system_prompt_file] without session" do
      {_script, args} =
        Command.build_command("hello world", "openai-codex/gpt-5.5", "/tmp/p.txt", nil, nil)

      assert args == ["hello world", "openai-codex/gpt-5.5", "/tmp/p.txt"]
    end

    test "appends session path to positional args when given" do
      {_script, args} =
        Command.build_command(
          "hello",
          "openai-codex/gpt-5.5",
          "/tmp/p.txt",
          "/tmp/s.jsonl",
          nil
        )

      assert args == ["hello", "openai-codex/gpt-5.5", "/tmp/p.txt", "/tmp/s.jsonl"]
    end
  end

  describe "build_command/6 — model qualification" do
    test "leaves provider-qualified model names unchanged" do
      {_, args} =
        Command.build_command("hi", "openai-codex/gpt-5.5", "/tmp/p.txt", nil, nil)

      assert Enum.at(args, 1) == "openai-codex/gpt-5.5"
    end
  end
end
