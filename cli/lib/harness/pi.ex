defmodule Cli.Harness.Pi do
  @moduledoc """
  Pi harness adapter — groups the modules that together implement
  `sessions run` support for pi.

  Sub-modules:

    * `Cli.Harness.Pi.Command`   — build the pi invocation (CLI flags,
      shell script, positional args).
    * `Cli.Harness.Pi.Stream`    — consume pi's streaming JSON protocol
      (`message_update` / `toolcall_*` / `agent_end`) and update run
      state accordingly.
    * `Cli.Harness.Pi.ToolInput` — format tool-call `arguments` maps
      into human-readable summaries for the stream display.

  This module is intentionally empty. Callers that need pi behavior
  reach into the sub-module for the specific concern. The
  multi-harness dispatcher (sessions#50 step 2) will route between
  `Cli.Harness.Pi.*` and the eventual `Cli.Harness.Claude.*` by calling
  the matching sub-module on the resolved adapter.
  """
end
