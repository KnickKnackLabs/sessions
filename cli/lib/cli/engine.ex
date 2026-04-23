defmodule Cli.Engine do
  @moduledoc """
  Agent-run execution engine.

  Spawns the harness process under a port, streams its stdout line by
  line through the harness's stream parser, flushes partial JSON
  between lines, handles timeout exit, and returns the process status
  (with ABORT detection surfacing as exit 1).

  The engine is harness-agnostic: `Cli.Harness.resolve/1` picks the
  right adapter module for the session, and the engine calls that
  module's `build_command/6`, `process_line/2`, and
  `extract_partial_text/1` functions. Step 2 of sessions#50.
  """

  @buffer_flush_timeout_ms 100
  @timeout_exit_code 124

  @typep run_opts :: [
           extensions: boolean(),
           skills: boolean(),
           prompt_templates: boolean()
         ]

  @doc """
  Run the agent harness to completion and return its exit status.

  Times out after `timeout` seconds (if given); prints a timeout
  banner when that fires. Returns `1` (not the harness's own status)
  if the agent printed `[[ABORT]]` on its own line.
  """
  @spec run(
          message :: String.t(),
          system_prompt_file :: String.t(),
          timeout :: non_neg_integer() | nil,
          model :: String.t(),
          cwd :: String.t() | nil,
          session :: String.t() | nil,
          run_opts()
        ) :: non_neg_integer()
  def run(message, system_prompt_file, timeout, model, cwd, session, pi_opts) do
    harness = Cli.Harness.resolve(session: session)

    {shell_script, positional_args} =
      harness.build_command(
        message,
        model,
        system_prompt_file,
        session,
        timeout,
        pi_opts
      )

    args = ["-c", shell_script, "--"] ++ positional_args

    port_opts = [:binary, :exit_status, :stderr_to_stdout, {:args, args}]
    port_opts = if cwd, do: [{:cd, cwd} | port_opts], else: port_opts

    port = Port.open({:spawn_executable, "/bin/sh"}, port_opts)

    status =
      stream_output(port, %{
        harness: harness,
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

        harness = state.harness

        new_state =
          complete_lines
          |> Enum.reject(&(&1 == ""))
          |> Enum.reduce(
            %{state | buffer: new_buffer},
            &harness.process_line/2
          )

        stream_output(port, new_state)

      {^port, {:exit_status, status}} ->
        final_state = finalize_buffer(buffer, state)
        Cli.UsageReport.print(final_state)

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
            extracted = state.harness.extract_partial_text(partial)
            new_text = Cli.Text.text_beyond_flushed(extracted, state.flushed_chars)
            if new_text != "", do: IO.write(new_text)
            stream_output(port, %{state | flushed_chars: String.length(extracted)})
        end
    end
  end

  defp finalize_buffer("", state), do: state

  defp finalize_buffer(buffer, state) do
    case Jason.decode(buffer) do
      {:ok, _} ->
        state.harness.process_line(buffer, state)

      {:error, _} ->
        extracted = state.harness.extract_partial_text(buffer)
        new_text = Cli.Text.text_beyond_flushed(extracted, state.flushed_chars)
        if new_text != "", do: IO.write(new_text)

        {abort_seen, recent_text, had_newline} =
          Cli.Text.check_abort_signal(extracted, state)

        %{
          state
          | abort_seen: abort_seen,
            recent_text: recent_text,
            had_newline_before_window: had_newline
        }
    end
  end
end
