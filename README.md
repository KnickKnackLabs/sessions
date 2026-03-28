<div align="center">

# sessions

**CLI tooling for working with pi agent session transcripts.**

List, search, inspect, read, and export your conversation history from the terminal.

</div>

---

## What is this?

[Pi](https://github.com/KnickKnackLabs/pi) stores every agent conversation as a JSONL file on disk. This project provides `mise run` commands that let you query, search, and navigate those transcripts — useful for resuming context, auditing tool usage, reviewing past sessions, or transferring sessions between machines.

## Install

```bash
git clone https://github.com/KnickKnackLabs/sessions.git
cd sessions && mise trust && mise install
```

## Commands

| Command | Description |
| --- | --- |
| `sessions list` | List recent sessions with ID, duration, model, and message count |
| `sessions read <id>` | Read a session transcript with windowed navigation |
| `sessions inspect <id>` | Forensic metadata: duration, model, tools used, context, compaction |
| `sessions search <query>` | Full-text regex search across all session transcripts |
| `sessions export <id>` | Export as a portable bundle (JSONL + metadata), markdown, or plain JSONL |
| `sessions import <path>` | Import a previously exported session bundle |
| `sessions fork <id>` | Fork a session (Claude Code format — pi port pending, see [#16](https://github.com/KnickKnackLabs/sessions/issues/16)) |

## Examples

**List your 10 most recent sessions:**

```bash
mise run list --limit 10
```

**Read a session transcript (prefix match on ID):**

```bash
mise run read b94b7b8a
```

**Read with windowing — jump to any part of a conversation:**

```bash
mise run read b94b7b8a --from 1 --to 10       # first 10 messages
mise run read b94b7b8a --from 100 --to 110     # jump to middle
mise run read b94b7b8a --last 10               # last 10 messages
mise run read b94b7b8a --from -60 --to -50     # 50 back from end
```

**Search for "sccache" across all sessions:**

```bash
mise run search "sccache"
```

**Inspect a session's metadata:**

```bash
mise run inspect b94b7b8a
```

**Export a session as markdown:**

```bash
mise run export b94b7b8a --format markdown --output ~/exports
```

**Export and import (transfer to another machine):**

```bash
# On source machine:
mise run export b94b7b8a --format bundle --output ~/transfer

# Copy the bundle to the target machine, then:
mise run import ~/transfer/b94b7b8a-.../
```

## How it works

Pi session JSONL files live in `~/.pi/agent/sessions/`, organized by project directory. Each file contains one JSON object per line — a session header, model changes, user messages, assistant responses (with tool calls), and tool results.

All commands are Python 3 scripts under `.mise/tasks/` that share a common parser (`lib/parse.py`) and Rich formatting helpers (`lib/format.py`). The `PI_DIR` env var can override the default `~/.pi` path, which the test suite uses for isolated testing.

Output uses [Rich](https://github.com/Textualize/rich) for styled terminal output — tables, colored role labels, search highlighting. Designed for 80-column minimum, degrades gracefully without color.

## Testing

```bash
mise run test
```

Runs the BATS test suite (66 tests) against synthetic JSONL data in pi format. Tests are fully isolated via `PI_DIR` override — no real sessions are read or modified.

## Structure

```text
sessions/
├── .mise/tasks/
│   ├── list        # List sessions
│   ├── read        # Read transcript (windowed navigation)
│   ├── inspect     # Forensic metadata
│   ├── search      # Full-text search
│   ├── export      # Export (bundle/markdown/jsonl)
│   ├── import      # Import bundle
│   ├── fork        # Fork a session (Claude Code format, pi port pending)
│   └── test        # Run BATS tests
├── lib/
│   ├── parse.py    # Shared JSONL parser (pi format)
│   └── format.py   # Rich formatting helpers
├── test/
│   ├── helpers.bash
│   ├── list.bats
│   ├── read.bats
│   ├── inspect.bats
│   ├── search.bats
│   ├── export.bats
│   ├── import.bats
│   └── fork.bats
├── mise.toml
└── LICENSE
```
