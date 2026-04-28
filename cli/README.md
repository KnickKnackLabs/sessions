# CLI

Session execution engine — runs pi with streaming output, timeout, ABORT detection, and usage reporting.

## Overview

Identity-agnostic Elixir wrapper around pi. It:

- Reads a system prompt from a file (`--system-prompt-file`)
- Executes pi via Erlang Port with optional timeout
- Streams JSON output in real-time, showing tool invocations with formatted inputs
- Detects `[[ABORT]]` signals across streaming chunk boundaries
- Reports usage metrics (tokens, cost, turns) at session end
- Supports session files for conversation continuity (`--session`)

**This CLI does not handle identity, passphrase injection, or prompt composition.** Those are the caller's responsibility. The `sessions run` task handles prompt assembly from environment variables and delegates here.

## Usage

```bash
# Via the sessions run task (typical)
sessions run --system-prompt-file /tmp/prompt.txt --model openai-codex/gpt-5.5 --timeout 300 "Your message"

# Direct CLI invocation (rare)
cd cli && mix sessions --system-prompt-file /tmp/prompt.txt --model openai-codex/gpt-5.5 "Your message"

# With session file for conversation continuity
mix sessions --system-prompt-file ./prompt.txt --model openai-codex/gpt-5.5 --session ./session.jsonl "Continue"
```

## Options

| Option | Description |
|--------|-------------|
| `--system-prompt-file <path>` | Required. Path to system prompt file |
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
- pi (installed via mise: `github:badlogic/pi-mono`)
