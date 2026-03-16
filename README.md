<div align="center">

# sessions

**Mise-based CLI tooling for working with Wibey/Claude Code session transcripts.**

List, search, inspect, and export your conversation history from the terminal.

</div>

---

## What is this?

Wibey (and Claude Code) store every conversation as a JSONL file on disk. This project provides `mise run` commands that let you query, search, and export those transcripts — useful for resuming context after compaction, auditing tool usage, or transferring sessions between machines.

## Install

```bash
git clone https://gecgithub01.walmart.com/vn5a6e7/sessions.git
cd sessions && mise trust && mise install
```

## Commands

| Command | Description |
| --- | --- |
| `sessions ls` | List recent sessions with ID, project, model, date, and message count |
| `sessions show <id>` | Pretty-print a full session transcript with role markers and timestamps |
| `sessions tail <id>` | Show the last N messages — quick "where was I?" for resuming |
| `sessions inspect <id>` | Forensic metadata: duration, model, tools used, context snapshots, compaction status |
| `sessions search <query>` | Full-text regex search across all session transcripts |
| `sessions export <id>` | Export as a portable bundle (JSONL + metadata), markdown, or plain JSONL |
| `sessions import <path>` | Import a previously exported session bundle |

## Examples

**List your 10 most recent sessions:**

```bash
mise run ls -- --limit 10
```

**See the last 5 messages of a session (prefix match on ID):**

```bash
mise run tail -- b94b7b8a --limit 5 --no-tools
```

**Search for "sccache" across all sessions:**

```bash
mise run search -- "sccache"
```

**Inspect a session's metadata:**

```bash
mise run inspect -- b94b7b8a
```

**Export a session as markdown:**

```bash
mise run export -- b94b7b8a --format markdown --output ~/exports
```

**Export and import (transfer to another machine):**

```bash
# On source machine:
mise run export -- b94b7b8a --format bundle --output ~/transfer

# Copy ~/transfer/b94b7b8a-.../ to target machine, then:
mise run import -- ~/transfer/b94b7b8a-.../
```

## How it works

Session JSONL files live in `~/.claude/projects/`, organized by project directory. Each file contains one JSON object per line — user messages, assistant responses (with tool calls), and queue operations.

All commands are Python 3 scripts under `.mise/tasks/` that share a common parser (`lib/parse.py`). The `CLAUDE_DIR` env var can override the default `~/.claude` path, which the BATS test suite uses for isolated testing.

## Testing

```bash
mise run test
```

Runs the BATS test suite (50 tests) against synthetic JSONL data. Tests are fully isolated via `CLAUDE_DIR` override — no real sessions are read or modified.

## Relationship to KnickKnackLabs/sessions

This is a Wibey-focused fork of the concept from `KnickKnackLabs/sessions`, which targets Claude Code on public GitHub. This repo lives on Walmart GHE and can include Wibey-specific features (debug log parsing, MCP tool awareness, etc.) without leaking internal details.

Long term, both repos should converge on a shared interface with pluggable provider backends (Claude Code vs Wibey). The JSONL format is identical — only paths and metadata differ.

## Structure

```text
sessions/
├── .mise/tasks/
│   ├── ls          # List sessions
│   ├── show        # Pretty-print transcript
│   ├── tail        # Last N messages
│   ├── inspect     # Forensic metadata
│   ├── search      # Full-text search
│   ├── export      # Export (bundle/markdown/jsonl)
│   ├── import      # Import bundle
│   └── test        # Run BATS tests
├── lib/
│   └── parse.py    # Shared JSONL parser
├── test/
│   ├── helpers.bash
│   ├── ls.bats
│   ├── show.bats
│   ├── tail.bats
│   ├── inspect.bats
│   ├── search.bats
│   ├── export.bats
│   └── import.bats
├── mise.toml
└── README.tsx      # This file (generates README.md)
```
