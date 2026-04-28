defmodule CliTest do
  use ExUnit.Case
  import ExUnit.CaptureIO

  # Helper: capture stdout and the return value from Cli.run/1 in one shot.
  defp run_cli(args) do
    output =
      capture_io(fn ->
        send(self(), {:result, Cli.run(args)})
      end)

    receive do
      {:result, exit_code} -> {output, exit_code}
    end
  end

  describe "invalid argument handling" do
    test "warns about unknown arguments" do
      {output, _exit_code} = run_cli(["--agnet", "quick", "--timeout", "60"])
      assert output =~ "WARNING: Unknown argument ignored: --agnet"
    end

    test "warns about multiple unknown arguments" do
      {output, _exit_code} = run_cli(["--agnet", "quick", "--tiemout", "60"])
      assert output =~ "WARNING: Unknown argument ignored: --agnet"
      assert output =~ "WARNING: Unknown argument ignored: --tiemout"
    end

    test "no warning for valid arguments" do
      {output, _exit_code} = run_cli(["--timeout", "60"])
      refute output =~ "WARNING: Unknown argument"
    end

    test "shows specific error for non-integer timeout value" do
      {output, _exit_code} = run_cli(["--timeout", "abc", "hello"])
      assert output =~ "ERROR: --timeout requires an integer value, got: abc"
    end

    test "returns exit code 1 for missing message" do
      {_output, exit_code} = run_cli(["--timeout", "60"])
      assert exit_code == 1
    end

    test "returns exit code 1 for whitespace-only message" do
      whitespace_cases = ["   ", "\t\t", "\n\n", "  \t\n  "]

      for ws <- whitespace_cases do
        {output, exit_code} = run_cli(["--timeout", "60", ws])
        assert exit_code == 1, "Expected exit 1 for whitespace: #{inspect(ws)}"
        assert output =~ "No message provided"
      end
    end

    test "requires model" do
      prompt = System.tmp_dir!() <> "/sessions-cli-test-prompt-#{System.unique_integer([:positive])}.txt"
      File.write!(prompt, "prompt")

      try do
        {output, exit_code} = run_cli(["--system-prompt-file", prompt, "hello"])
        assert exit_code == 1
        assert output =~ "--model is required"
      after
        File.rm(prompt)
      end
    end

    test "requires provider-qualified model" do
      prompt = System.tmp_dir!() <> "/sessions-cli-test-prompt-#{System.unique_integer([:positive])}.txt"
      File.write!(prompt, "prompt")

      try do
        {output, exit_code} = run_cli(["--system-prompt-file", prompt, "--model", "gpt-5.5", "hello"])
        assert exit_code == 1
        assert output =~ "--model must be provider-qualified"
      after
        File.rm(prompt)
      end
    end

    test "requires system-prompt-file" do
      {output, exit_code} = run_cli(["--timeout", "60", "--model", "openai-codex/gpt-5.5", "hello"])
      assert exit_code == 1
      assert output =~ "--system-prompt-file is required"
    end

    test "rejects non-existent system-prompt-file" do
      {output, exit_code} =
        run_cli(["--system-prompt-file", "/nonexistent/path.txt", "--model", "openai-codex/gpt-5.5", "--timeout", "60", "hello"])

      assert exit_code == 1
      assert output =~ "System prompt file not found"
    end

    test "timeout is optional" do
      # Should not error on missing timeout — only on missing prompt.
      {output, exit_code} = run_cli(["--system-prompt-file", "/nonexistent/path.txt", "--model", "openai-codex/gpt-5.5", "hello"])
      assert exit_code == 1
      assert output =~ "System prompt file not found"
    end
  end

  describe "Cli module" do
    test "exports main/1 function" do
      # `function_exported?` returns `false` unless the module is
      # already loaded; force the load first so the test doesn't flake
      # when scheduled before anything else references `Cli`.
      Code.ensure_loaded!(Cli)
      assert function_exported?(Cli, :main, 1)
    end

    test "module loads without errors" do
      assert Code.ensure_loaded?(Cli)
    end
  end
end
