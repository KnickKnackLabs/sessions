# CLI

Session execution engine — runs pi with streaming output, timeout, ABORT detection, and usage reporting.

## Overview

Prompt-agnostic Elixir wrapper around pi. It:

- Optionally reads appended system prompt text from a file (`--system-prompt-file`)
- Executes pi via Erlang Port with optional timeout
- Streams JSON output in real-time, showing tool invocations with formatted inputs
- Detects `[[ABORT]]` signals across streaming chunk boundaries
- Reports usage metrics (tokens, cost, turns) at session end
- Supports session files for conversation continuity (`--session`)

**This CLI does not interpret prompt contents or compose caller context.** Those are the caller's responsibility. The `sessions run` task handles optional runtime prompt additions and delegates here; when no prompt is provided, the harness can rely on native cwd context discovery.

## Usage

```bash
# Via the sessions run task (typical)
sessions run --model openai-codex/gpt-5.5 --timeout 300 "Your message"

# Direct CLI invocation (rare)
cd cli && mix sessions --model openai-codex/gpt-5.5 "Your message"

# With session file for conversation continuity
mix sessions --model openai-codex/gpt-5.5 --session ./session.jsonl "Continue"
```

## Options

| Option | Description |
|--------|-------------|
| `--system-prompt-file <path>` | Optional. Path to appended system prompt text |
| `--timeout <seconds>` | Optional. Timeout in seconds (default: no timeout) |
| `--model <provider/model>` | Required. Provider-qualified model to use |
| `--session <path>` | Optional. Session file for conversation continuity |
| `--cwd <path>` | Optional. Working directory for pi |
| `--no-extensions` | Disable pi extensions |
| `--no-skills` | Disable pi skills |
| `--no-prompt-templates` | Disable pi prompt templates |

## Dependencies

- Elixir 1.19+
- Jason (JSON parsing)
- pi (owned by this package via mise: `github:KnickKnackLabs/pi@v0.80.6-kkl.1`)
