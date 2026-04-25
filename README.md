<div align="center">

# sessions

**CLI tooling for pi agent session transcripts.**

Create sessions with structured metadata, wake agents into them,
observe transcripts in real time, and query your history.

![lang: bash + python](https://img.shields.io/badge/lang-bash%20%2B%20python-4EAA25?style=flat&logo=gnubash&logoColor=white)
[![tests: 161 passing](https://img.shields.io/badge/tests-161%20passing-brightgreen?style=flat)](test/)
![commands: 13](https://img.shields.io/badge/commands-13-blue?style=flat)
![license: MIT](https://img.shields.io/badge/license-MIT-blue?style=flat)

</div>

```
$ sessions new review/pr-50 --cwd ~/agents/ikma/den --meta agent.name=ikma
e96bd43a

$ sessions wake review/pr-50 --message "review PR #50"
Woke session 'review/pr-50'

$ sessions read review/pr-50 --last 3
┃ assistant  Found 3 issues in error handling.
┃ assistant  Posted review to #scout-report.

$ sessions list --filter session.meta.agent.name=ikma
  e96bd43a  review/pr-50   12m   3m ago   claude-sonnet-4   8
```

<br />

## Quick start

```bash
# Install
shiv install sessions

# List recent sessions
sessions list

# Read a transcript (by name or ID prefix)
sessions read review/pr-50

# Search across all sessions
sessions search "error handling"

# Inspect forensic metadata
sessions inspect e96bd43a
```

## Session lifecycle

Sessions aren't just transcript files agents leave behind — they're managed artifacts with structure. A session starts with `new`, gets woken into with `wake`, and every event is recorded in the JSONL stream.

```
  sessions new              create session with metadata + context
  sessions wake             wake an agent into it via shell
    └─ shell run            persistent zmx session
         └─ shimmer agent   identity + chat attribution
              └─ pi         harness — processes message, exits
  sessions read             observe the transcript
  sessions wake (again)     re-enter with corrections
```

Each wake event is a first-class entry in the session file — timestamped, attributed, with its own metadata. A session that's been woken three times has three `wake` entries you can filter on. The full conversation history carries forward, so the agent sees everything that happened before.

```bash
# Create a named session with metadata and context
sessions new review/pr-50 --cwd ~/agents/ikma/den \
  --meta agent.name=ikma \
  --meta purpose=review \
  --context "Background: this PR refactors the auth module"

# Wake an agent into it (by name)
sessions wake review/pr-50 --message "Review PR #50"

# Pin the model for this wake (defaults to the harness default if omitted)
sessions wake review/pr-50 --model claude-opus-4-7 --message "Review PR #50"

# Watch what it does
sessions read review/pr-50 --last 5

# Something went wrong? Wake the same session again.
sessions wake review/pr-50 --message "You missed the edge case in line 42"
```

The spawning stack uses [shell](https://github.com/KnickKnackLabs/shell) for persistent zmx sessions. `sessions wake` calls `sessions run` directly for execution — identity (AGENT_IDENTITY, etc.) must already be in the environment, typically set upstream via `eval $(shimmer as <agent>)`.

`--model` on `sessions wake` is a one-shot override; it is not remembered across wakes — pass `--model X` on each wake, or track [issue #61](https://github.com/KnickKnackLabs/sessions/issues/61).

## Metadata

Every session carries structured metadata in its JSONL header. Set it at creation with `--meta`, read it back with `sessions meta`. Two formats, mixable:

```bash
# Dotted paths — simple key=value, auto-nested
sessions new scout-run --cwd ~/agents/ikma/den \
  --meta agent.name=ikma \
  --meta agent.email=ikma@ricon.family \
  --meta purpose=scout

# jq expressions — full jq syntax, supports $ENV
sessions new ci-check --cwd $(shiv which den) \
  --meta '{agent: {name: $ENV.GIT_AUTHOR_NAME}}' \
  --meta purpose=review

# Read it back
sessions meta scout-run                      # by name
sessions meta e96bd43a --field .meta.agent   # by ID prefix
```

Wake events carry their own metadata, separate from the session header. This records who woke the session and why — useful for tracing agent-to-agent handoffs:

```bash
sessions wake review/pr-50 \
  --meta by.agent.name=ikma \
  --message "check the CI results"
```

## Filtering

`sessions list --filter` queries across your session history using entry type, dotted paths, and optional indexing. Multiple filters are ANDed together.

```bash
# Find all sessions created by ikma
sessions list --filter session.meta.agent.name=ikma

# Find sessions where ikma was the first to wake
sessions list --filter wake[0].meta.by.agent.name=ikma

# Find sessions where brownie woke last
sessions list --filter wake[-1].meta.by.agent.name=brownie

# Combine filters (AND logic)
sessions list \
  --filter session.meta.agent.name=zeke \
  --filter wake.meta.by.agent.name=brownie
```

The filter syntax is `type[index].path=value`. Type is `session`, `wake`, or any JSONL entry type. Index is optional — without it, any entry of that type can match. Negative indices count from the end.

## Reading transcripts

`sessions read` renders session transcripts with windowed navigation. Jump to any part of a conversation without loading the whole thing:

```bash
sessions read e96bd43a                     # full transcript
sessions read e96bd43a --last 10           # last 10 messages
sessions read e96bd43a --from 20 --to 30   # specific window
sessions read e96bd43a --from -5           # last 5 messages
sessions read e96bd43a --tools             # include tool calls
```

For existing sessions you want to work with elsewhere, `copy` duplicates a session with its full conversation history plus a fork notice. The copy gets a new ID and can be woken independently — useful for handing off context between agents.

```bash
sessions copy e96bd43a --context "continue the review"
```

## Development

```bash
git clone https://github.com/KnickKnackLabs/sessions.git
cd sessions && mise trust && mise install
mise run test
```

**161 tests** across 12 suites, using [BATS 1.13.0](https://github.com/bats-core/bats-core). Tasks are bash scripts (session creation, wake, metadata) and Python scripts with [Rich](https://github.com/Textualize/rich) output (list, read, inspect, search). The JSONL parsing library is 434 lines of Python in `lib/`.

<details>
<summary><b>Project structure</b></summary>

```
sessions/
├── .mise/tasks/
│   ├── new          # Create sessions with metadata + context
│   ├── wake         # Wake agents into sessions via shell
│   ├── meta         # Read session header metadata
│   ├── list         # List + filter sessions (Rich tables)
│   ├── read         # Windowed transcript reader
│   ├── search       # Full-text regex across transcripts
│   ├── inspect      # Forensic metadata (duration, tools, model)
│   ├── copy         # Duplicate sessions for handoff
│   ├── remove       # Remove sessions (kill shell + delete file)
│   ├── run          # Execute agent sessions (wraps Elixir CLI)
│   ├── cli/build    # Build Elixir CLI dependencies
│   ├── export       # Portable bundles (JSONL + metadata)
│   └── import       # Import exported sessions
├── cli/             # Elixir execution engine (timeout, ABORT, usage)
├── lib/
│   ├── parse.py        # JSONL parser, session model, filter engine
│   ├── format.py       # Rich formatting helpers
│   ├── ensure-deps.sh  # First-run CLI deps self-heal
│   ├── find.sh         # Back-compat shim → harness adapter
│   ├── shell.sh        # Shell helpers
│   └── harness/        # Per-harness adapters (pi, …)
└── test/
    └── *.bats          # 161 tests
```

</details>

<br />

<div align="center">

---

<sub>
Every session is structured data. Query it.<br />
<br />
This README was generated from <a href="https://github.com/KnickKnackLabs/readme">README.tsx</a>.
</sub></div>
