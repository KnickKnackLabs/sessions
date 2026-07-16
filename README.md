<div align="center">

# sessions

**CLI tooling for pi agent session transcripts.**

Create sessions with structured metadata, wake agents into them,
observe transcripts in real time, and query your history.

![lang: bash + python](https://img.shields.io/badge/lang-bash%20%2B%20python-4EAA25?style=flat&logo=gnubash&logoColor=white)
[![tests: 321 passing](https://img.shields.io/badge/tests-321%20passing-brightgreen?style=flat)](test/)
![commands: 19](https://img.shields.io/badge/commands-19-blue?style=flat)
![license: MIT](https://img.shields.io/badge/license-MIT-blue?style=flat)

</div>

```
$ sessions new review/pr-50 --cwd ~/agents/ikma/den --system-prompt-file /tmp/review-profile.md --meta agent.name=ikma
e96bd43a

$ sessions wake review/pr-50 --model openai-codex/gpt-5.5 --message "review PR #50"
Woke session 'review/pr-50'

$ sessions read review/pr-50 --last 3
┃ assistant  Found 3 issues in error handling.
┃ assistant  Posted review to #scout-report.

$ sessions wait review/pr-50 --assistant-only --timeout 120
┃ assistant  Re-ran CI; all checks are green.

$ sessions ps
  e96bd43a  ikma/den  12345  live  3m ago  openai-codex/gpt-5.5

$ sessions usage review/pr-50
┃ total  1.2M tokens  $0.84

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

# Wait for the next assistant message
sessions wait review/pr-50 --assistant-only --timeout 120

# Search across all sessions
sessions search "error handling"

# Show live local session processes
sessions ps

# Show recorded token usage and cost
sessions usage review/pr-50

# Inspect forensic metadata
sessions inspect e96bd43a

# Query structured history without creating a durable DB
sessions query --project junior/home --limit 30 \
  --sql-file queries/bash-status.sql \
  --format grid
```

## Session lifecycle

Sessions aren't just transcript files agents leave behind — they're managed artifacts with structure. A session starts with `new`, gets woken into with `wake`, and every event is recorded in the JSONL stream.

```
  sessions new              create session with prompt + metadata + context
  sessions wake             wake an agent into it via shell
    └─ shell run            persistent zmx session (caller-owned)
         └─ run-as-user     optional --os-user payload boundary
              └─ sessions run
                   └─ pi    harness — processes message or opens interactively
  sessions read             observe the transcript
  sessions wait             block until new transcript messages arrive
  sessions ps               show live local session processes
  sessions usage            inspect recorded tokens + costs
  sessions wake (again)     re-enter with corrections
```

Each wake event is a first-class entry in the session file — timestamped, attributed, with its own metadata. A session that's been woken three times has three `wake` entries you can filter on. The full conversation history carries forward, so the agent sees everything that happened before.

`sessions run` also records generic `process_start` / `process_exit` entries for managed sessions. `sessions ps` uses those entries plus PID start-time verification, so a missing exit entry from a crash does not make a stale or reused PID look live.

```bash
# Create a named session with a baked system prompt, metadata, and context
sessions new review/pr-50 --cwd ~/agents/ikma/den \
  --system-prompt-file /tmp/review-profile.md \
  --meta agent.name=ikma \
  --meta purpose=review \
  --context "Background: this PR refactors the auth module"

# Wake the existing session. Model is required at wake time.
sessions wake review/pr-50 --model openai-codex/gpt-5.5 --message "Review PR #50"

# Watch what it does
sessions read review/pr-50 --last 5

# Something went wrong? Wake the same session again.
sessions wake review/pr-50 --model openai-codex/gpt-5.5 --message "You missed the edge case in line 42"
```

The spawning stack uses [shell](https://github.com/KnickKnackLabs/shell) for persistent zmx sessions. `sessions wake` calls `sessions run` as its hidden low-level executor. For profile-specific sessions, use `new` + `wake`: bake profile or task instructions into the session with `--system-prompt-file` at creation, then wake it with task messages. If no explicit or baked prompt exists, the harness starts without an appended prompt and can rely on its native cwd context discovery.

Before launch, Sessions resolves the selected harness executable from its own declared toolchain. The child then starts in the requested `--cwd` with Sessions' mise task context and direct tool-install paths removed. This keeps the harness version pinned without replacing the target project or agent home's own tool and resource context.

`sessions run` remains available as an advanced/compatibility command. It accepts an explicit `--system-prompt-file`, uses any prompt baked into the session, and otherwise starts without appending a system prompt. Caller-provided context belongs to the caller, not to `sessions`.

`--model` on `sessions wake` is required and is not remembered across wakes — pass a provider-qualified model (for example `openai-codex/gpt-5.5`) on each wake.

`--message` is optional for interactive `sessions wake`: with a message, wake sends an initial prompt and keeps the harness open; without one, it opens the harness for the human. `--headless` still requires `--message`. For low-level `sessions run`, pass `--interactive` when a provided message should keep the harness open; otherwise a message uses the print/one-turn compatibility path.

Runs inherit the selected harness's normal extensions, skills, and prompt templates by default, including print and headless execution. Use `--no-extensions`, `--no-skills`, or `--no-prompt-templates` only when a caller deliberately needs a resource-free boundary.

`--project-trust inherit|approve|deny` controls project-scoped settings and executable resources for one run. The default `inherit` preserves native harness behavior. A harness translates `approve` and `deny` explicitly or rejects the unsupported policy; Sessions never silently ignores it. This option does not persist trust and is not a sandbox.

To run only the payload process as a local agent OS user, pass `--os-user` or set `SHIMMER_OS_USER`. The shell/zmx session remains owned by the caller. This does not copy caller environment, secrets, or auth into the target account; the target user's session environment is a separate setup step.

```bash
sessions wake iris-first-wake \
  --model openai-codex/gpt-5.5 \
  --os-user iris \
  --message "Continue Iris onboarding"
```

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
  --model openai-codex/gpt-5.5 \
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

`sessions wait` snapshots the current transcript and blocks until new matching messages arrive. It is useful for supervising long-running or parallel sessions without hand-written sleep loops.

```bash
sessions wait e96bd43a                         # next non-tool message
sessions wait e96bd43a --count 10              # wait for 10 messages
sessions wait e96bd43a --assistant-only        # ignore user/operator messages
sessions wait e96bd43a --match "done|failed"   # wait for a regex match
sessions wait e96bd43a --tools                 # include tool calls/results
sessions wait e96bd43a --timeout 120 --json
```

`sessions ps` shows currently-live local session processes recorded by `sessions run`. By default it hides exited processes and dead missing-exit records; pass `--all` to inspect those records too.

```bash
sessions ps                  # live managed session processes
sessions ps --project k7r2   # filter by project/session path
sessions ps --all --json     # include exited/dead records
```

`sessions usage` reports recorded token usage and cost. It works for one session, or across recent/date-filtered sessions, and attributes usage by the model active at each turn so model switches are visible.

```bash
sessions usage e96bd43a                  # one session summary
sessions usage e96bd43a --turns          # per-turn records
sessions usage --today                   # aggregate today's recorded usage
sessions usage --after 2026-06-01 --json # machine-readable aggregate
```

For existing sessions you want to work with elsewhere, `copy` duplicates a session with its full conversation history plus a fork notice. The copy gets a new ID and can be woken independently — useful for handing off context between agents.

```bash
sessions copy e96bd43a --context "continue the review"
```

## Querying session history

`sessions query` builds an ephemeral in-memory SQLite projection over local session JSONL files. JSONL remains the source of truth; no durable database is created. This is useful for ad hoc analysis across sessions, tools, messages, usage, and bash command status.

Privacy defaults are conservative: the default `--text commands` mode inserts redacted bash commands, but not message text or tool output excerpts. Use `--text compact` only when you intentionally want bounded excerpts, and reserve `--text full` for explicitly scoped local analysis.

```bash
# Show the query schema and examples
sessions query

# Use a packaged SQL preset over a recent project slice
sessions query --project junior/home --limit 30 \
  --sql-file queries/bash-status.sql \
  --format grid

# Inspect failed bash commands for one session
sessions query e96bd43a --sql '
select call_seq, command_category, exit_status, output_lines, command
from bash_calls
where is_error = 1 or coalesce(exit_status, 0) != 0
order by call_seq
limit 20;
' --format grid

# Compact output excerpts require an explicit text mode
sessions query e96bd43a --text compact \
  --sql-file queries/bash-with-output.sql \
  --format jsonl
```

Large result sets can be rendered as `--format html` or opened with `--browser` for a temporary local table with sticky headers and row filtering. Richer browser table controls are tracked separately so the first query surface can stay small.

## Development

```bash
git clone https://github.com/KnickKnackLabs/sessions.git
cd sessions && mise trust && mise install
mise run test
```

**321 tests** across 21 suites, using [BATS 1.13.0](https://github.com/bats-core/bats-core). Tasks are bash scripts (session creation, wake, metadata) and Python scripts with [Rich](https://github.com/Textualize/rich) output (list, read, wait, usage, inspect, search). The shared Python support library is 2740 lines in `lib/`.

Python code is checked with [Ruff](https://docs.astral.sh/ruff/) via `mise run lint:python`, and CI runs the same lint/format check in addition to the BATS and Elixir suites.

<details>
<summary><b>Project structure</b></summary>

```
sessions/
├── .mise/tasks/
│   ├── new          # Create sessions with prompt + metadata + context
│   ├── wake         # Wake agents into sessions via shell
│   ├── meta         # Read session header metadata
│   ├── list         # List + filter sessions (Rich tables)
│   ├── read         # Windowed transcript reader
│   ├── wait         # Wait for new transcript messages
│   ├── ps           # Live local process view
│   ├── usage        # Recorded token/cost aggregation
│   ├── search       # Full-text regex across transcripts
│   ├── inspect      # Forensic metadata (duration, tools, model)
│   ├── query        # Ephemeral SQLite projection for ad hoc analysis
│   ├── copy         # Duplicate sessions for handoff
│   ├── remove       # Remove sessions (kill shell + delete file)
│   ├── run          # Hidden low-level executor used by wake
│   ├── cli/build    # Build Elixir CLI dependencies
│   ├── lint/python  # Ruff lint + format check for Python code
│   ├── export       # Portable bundles (JSONL + metadata)
│   └── import       # Import exported sessions
├── cli/             # Elixir execution engine (timeout, ABORT, usage)
├── lib/
│   ├── parse.py        # JSONL parser, session model, filter engine
│   ├── format.py       # Rich formatting helpers
│   ├── ensure-deps.sh  # First-run CLI deps self-heal
│   ├── find.sh         # Back-compat shim → harness adapter
│   ├── shell.sh        # Shell helpers
│   ├── query/          # sessions query projection/rendering code
│   └── harness/        # Per-harness adapters (pi, …)
├── queries/            # Packaged sessions query SQL presets
└── test/
    └── *.bats          # 321 tests
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
