/** @jsxImportSource jsx-md */

import { readFileSync, readdirSync } from "fs";
import { join, resolve } from "path";

import {
  Heading, Paragraph, CodeBlock, LineBreak, HR,
  Bold, Italic, Code, Link,
  Badge, Badges, Center, Section, Details,
  List, Item,
  Raw, HtmlLink, Sub,
} from "readme/src/components";

// ── Dynamic data ─────────────────────────────────────────────

const ROOT = resolve(import.meta.dirname);
const TASK_DIR = join(ROOT, ".mise/tasks");
const TEST_DIR = join(ROOT, "test");

// Count tasks (excluding hidden/meta)
const taskFiles = readdirSync(TASK_DIR).filter(
  (f) => !f.startsWith(".") && !f.startsWith("_") && f !== "test"
);
const taskCount = taskFiles.length;

// Count public BATS cases and focused Python unit cases.
const batsTestFiles = readdirSync(TEST_DIR).filter((f) => f.endsWith(".bats"));
const pythonTestFiles = readdirSync(TEST_DIR).filter((f) => f.endsWith("_test.py"));
const batsTestSrc = batsTestFiles
  .map((f) => readFileSync(join(TEST_DIR, f), "utf-8"))
  .join("\n");
const pythonTestSrc = pythonTestFiles
  .map((f) => readFileSync(join(TEST_DIR, f), "utf-8"))
  .join("\n");
const batsTestCount = [...batsTestSrc.matchAll(/@test "/g)].length;
const pythonTestCount = [...pythonTestSrc.matchAll(/^\s+def test_/gm)].length;
const testCount = batsTestCount + pythonTestCount;
const testSuiteCount = batsTestFiles.length + pythonTestFiles.length;

// Extract tool versions from mise.toml
const miseToml = readFileSync(join(ROOT, "mise.toml"), "utf-8");
const batsVersion =
  miseToml.match(/bats\s*=\s*"([^"]+)"/)?.[1] ?? "latest";

// Count Python lib lines for the "how it works" credibility
const libDir = join(ROOT, "lib");
function pythonFiles(dir: string): string[] {
  return readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
    const path = join(dir, entry.name);
    if (entry.isDirectory()) return pythonFiles(path);
    return entry.name.endsWith(".py") ? [path] : [];
  });
}
const libFiles = pythonFiles(libDir);
const libLines = libFiles.reduce(
  (sum, f) => sum + readFileSync(f, "utf-8").split("\n").length,
  0
);

// ── Visual hook ──────────────────────────────────────────────

const lifecycle = [
  "$ sessions new review/pr-50 --cwd ~/agents/ikma/den --system-prompt-file /tmp/review-profile.md --meta agent.name=ikma",
  "e96bd43a",
  "",
  "$ sessions wake review/pr-50 --model openai-codex/gpt-5.5 --message \"review PR #50\"",
  "Woke session 'review/pr-50'",
  "",
  "$ sessions read review/pr-50 --last 3",
  "┃ assistant  Found 3 issues in error handling.",
  "┃ assistant  Posted review to #scout-report.",
  "",
  "$ sessions wait review/pr-50 --assistant-only --timeout 120",
  "┃ assistant  Re-ran CI; all checks are green.",
  "",
  "$ sessions wait-any review/pr-50 deploy/staging --timeout 120",
  "review/pr-50  e96bd43a  turn settled (stop)",
  "",
  "$ sessions ps",
  "  e96bd43a  ikma/den  12345  live  3m ago  openai-codex/gpt-5.5",
  "",
  "$ sessions usage review/pr-50",
  "┃ total  1.2M tokens  $0.84",
  "",
  "$ sessions list --filter session.meta.agent.name=ikma",
  "  e96bd43a  review/pr-50   12m   3m ago   claude-sonnet-4   8",
].join("\n");

// ── Spawning stack ───────────────────────────────────────────

const stack = [
  "  sessions new              create session with prompt + metadata + context",
  "  sessions wake             wake an agent into it via shell",
  "    └─ shell run            persistent zmx session (caller-owned)",
  "         └─ run-as-user     optional --os-user payload boundary",
  "              └─ sessions run",
  "                   └─ pi    harness — processes message or opens interactively",
  "  sessions read             observe the transcript",
  "  sessions wait             block until new transcript messages arrive",
  "  sessions wait-any         wait across sessions for a settled turn",
  "  sessions ps               show live or unverified local session processes",
  "  sessions usage            inspect recorded tokens + costs",
  "  sessions wake (again)     re-enter with corrections",
].join("\n");

// ── Filter examples ──────────────────────────────────────────

const filterExamples = [
  "# Find all sessions created by ikma",
  "sessions list --filter session.meta.agent.name=ikma",
  "",
  "# Find sessions where ikma was the first to wake",
  "sessions list --filter wake[0].meta.by.agent.name=ikma",
  "",
  "# Find sessions where brownie woke last",
  "sessions list --filter wake[-1].meta.by.agent.name=brownie",
  "",
  "# Combine filters (AND logic)",
  "sessions list \\",
  "  --filter session.meta.agent.name=zeke \\",
  "  --filter wake.meta.by.agent.name=brownie",
].join("\n");

// ── README ───────────────────────────────────────────────────

const readme = (
  <>
    <Center>
      <Heading level={1}>sessions</Heading>

      <Paragraph>
        <Bold>
          CLI tooling for pi agent session transcripts.
        </Bold>
      </Paragraph>

      <Paragraph>
        {"Create sessions with structured metadata, wake agents into them,"}
        {"\n"}
        {"observe transcripts in real time, and query your history."}
      </Paragraph>

      <Badges>
        <Badge label="lang" value="bash + python" color="4EAA25" logo="gnubash" logoColor="white" />
        <Badge label="tests" value={`${testCount} passing`} color="brightgreen" href="test/" />
        <Badge label="commands" value={`${taskCount}`} color="blue" />
        <Badge label="license" value="MIT" color="blue" />
      </Badges>
    </Center>

    <CodeBlock>{lifecycle}</CodeBlock>

    <LineBreak />

    <Section title="Quick start">
      <CodeBlock lang="bash">{`# Install
shiv install sessions

# List recent sessions
sessions list

# Read a transcript (by name or ID prefix)
sessions read review/pr-50

# Wait for the next assistant message
sessions wait review/pr-50 --assistant-only --timeout 120

# Wait for any supervised agent to settle
sessions wait-any review/pr-50 deploy/staging --timeout 120

# Search across all sessions
sessions search "error handling"

# Show live or unverified local session processes
sessions ps

# Show recorded token usage and cost
sessions usage review/pr-50

# Inspect forensic metadata
sessions inspect e96bd43a

# Query structured history without creating a durable DB
sessions query --project junior/home --limit 30 \\
  --sql-file queries/bash-status.sql \\
  --format grid`}</CodeBlock>
    </Section>

    <Section title="Session lifecycle">
      <Paragraph>
        {"Sessions aren't just transcript files agents leave behind — they're managed artifacts with structure. A session starts with "}
        <Code>new</Code>
        {", gets woken into with "}
        <Code>wake</Code>
        {", and every event is recorded in the JSONL stream."}
      </Paragraph>

      <CodeBlock>{stack}</CodeBlock>

      <Paragraph>
        {"Each wake event is a first-class entry in the session file — timestamped, attributed, with its own metadata. A session that's been woken three times has three "}
        <Code>wake</Code>
        {" entries you can filter on. The full conversation history carries forward, so the agent sees everything that happened before."}
      </Paragraph>

      <Paragraph>
        <Code>sessions run</Code>
        {" also records generic "}
        <Code>process_start</Code>
        {" / "}
        <Code>process_exit</Code>
        {" entries for managed sessions. "}
        <Code>sessions ps</Code>
        {" uses those entries plus PID start-time verification, so a missing exit entry from a crash does not make a stale or reused PID look live."}
      </Paragraph>

      <CodeBlock lang="bash">{`# Create a named session with a baked system prompt, metadata, and context
sessions new review/pr-50 --cwd ~/agents/ikma/den \\
  --system-prompt-file /tmp/review-profile.md \\
  --meta agent.name=ikma \\
  --meta purpose=review \\
  --context "Background: this PR refactors the auth module"

# Wake the existing session. Model is required at wake time.
sessions wake review/pr-50 --model openai-codex/gpt-5.5 --message "Review PR #50"

# Watch what it does
sessions read review/pr-50 --last 5

# Something went wrong? Wake the same session again.
sessions wake review/pr-50 --model openai-codex/gpt-5.5 --message "You missed the edge case in line 42"`}</CodeBlock>

      <Paragraph>
        {"The spawning stack uses "}
        <Link href="https://github.com/KnickKnackLabs/shell">shell</Link>
        {" for persistent zmx sessions. "}
        <Code>sessions wake</Code>
        {" calls "}
        <Code>sessions run</Code>
        {" as its hidden low-level executor. For profile-specific sessions, use "}
        <Code>new</Code>
        {" + "}
        <Code>wake</Code>
        {": bake profile or task instructions into the session with "}
        <Code>--system-prompt-file</Code>
        {" at creation, then wake it with task messages. If no explicit or baked prompt exists, the harness starts without an appended prompt and can rely on its native cwd context discovery."}
      </Paragraph>

      <Paragraph>
        {"Before launch, Sessions resolves the selected harness executable from its own declared toolchain. The child then starts in the requested "}
        <Code>--cwd</Code>
        {" with Sessions' mise task context and direct tool-install paths removed. Sessions selects compatible KKL Pi patches from the `v0.83.0-kkl` release stream after a six-hour cooling period when its toolchain is installed or refreshed, without replacing the target project or agent home's own tool and resource context. A fixed Sessions release can therefore resolve a newer cooled Pi patch after refresh."}
      </Paragraph>

      <Paragraph>
        <Code>sessions run</Code>
        {" remains available as an advanced/compatibility command. It accepts an explicit "}
        <Code>--system-prompt-file</Code>
        {", uses any prompt baked into the session, and otherwise starts without appending a system prompt. Caller-provided context belongs to the caller, not to "}
        <Code>sessions</Code>
        {"."}
      </Paragraph>

      <Paragraph>
        <Code>--model</Code>
        {" on "}
        <Code>sessions wake</Code>
        {" is required and is not remembered across wakes — pass a provider-qualified model (for example "}
        <Code>openai-codex/gpt-5.5</Code>
        {") on each wake."}
      </Paragraph>

      <Paragraph>
        <Code>--message</Code>
        {" is optional for interactive "}
        <Code>sessions wake</Code>
        {": with a message, wake sends an initial prompt and keeps the harness open; without one, it opens the harness for the human. "}
        <Code>--headless</Code>
        {" still requires "}
        <Code>--message</Code>
        {". For low-level "}
        <Code>sessions run</Code>
        {", pass "}
        <Code>--interactive</Code>
        {" when a provided message should keep the harness open; otherwise a message uses the print/one-turn compatibility path."}
      </Paragraph>

      <Paragraph>
        {"Runs inherit the selected harness's normal extensions, skills, and prompt templates by default, including print and headless execution. Use "}
        <Code>--no-extensions</Code>
        {", "}
        <Code>--no-skills</Code>
        {", or "}
        <Code>--no-prompt-templates</Code>
        {" only when a caller deliberately needs a resource-free boundary."}
      </Paragraph>

      <Paragraph>
        <Code>--project-trust inherit|approve|deny</Code>
        {" controls project-scoped settings and executable resources for one run. The default "}
        <Code>inherit</Code>
        {" preserves native harness behavior. A harness translates "}
        <Code>approve</Code>
        {" and "}
        <Code>deny</Code>
        {" explicitly or rejects the unsupported policy; Sessions never silently ignores it. This option does not persist trust and is not a sandbox."}
      </Paragraph>

      <Paragraph>
        {"To run only the payload process as a local agent OS user, pass "}
        <Code>--os-user</Code>
        {" or set "}
        <Code>SHIMMER_OS_USER</Code>
        {". The shell/zmx session remains owned by the caller. This does not copy caller environment, secrets, or auth into the target account; the target user's session environment is a separate setup step."}
      </Paragraph>

      <CodeBlock lang="bash">{`sessions wake iris-first-wake \\
  --model openai-codex/gpt-5.5 \\
  --os-user iris \\
  --message "Continue Iris onboarding"`}</CodeBlock>
    </Section>

    <Section title="Metadata">
      <Paragraph>
        {"Every session carries structured metadata in its JSONL header. Set it at creation with "}
        <Code>--meta</Code>
        {", read it back with "}
        <Code>sessions meta</Code>
        {". Two formats, mixable:"}
      </Paragraph>

      <CodeBlock lang="bash">{`# Dotted paths — simple key=value, auto-nested
sessions new scout-run --cwd ~/agents/ikma/den \\
  --meta agent.name=ikma \\
  --meta agent.email=ikma@ricon.family \\
  --meta purpose=scout

# jq expressions — full jq syntax, supports $ENV
sessions new ci-check --cwd $(shiv which den) \\
  --meta '{agent: {name: $ENV.GIT_AUTHOR_NAME}}' \\
  --meta purpose=review

# Read it back
sessions meta scout-run                      # by name
sessions meta e96bd43a --field .meta.agent   # by ID prefix`}</CodeBlock>

      <Paragraph>
        {"Wake events carry their own metadata, separate from the session header. This records who woke the session and why — useful for tracing agent-to-agent handoffs:"}
      </Paragraph>

      <CodeBlock lang="bash">{`sessions wake review/pr-50 \\
  --model openai-codex/gpt-5.5 \\
  --meta by.agent.name=ikma \\
  --message "check the CI results"`}</CodeBlock>
    </Section>

    <Section title="Filtering">
      <Paragraph>
        <Code>sessions list --filter</Code>
        {" queries across your session history using entry type, dotted paths, and optional indexing. Multiple filters are ANDed together."}
      </Paragraph>

      <CodeBlock lang="bash">{filterExamples}</CodeBlock>

      <Paragraph>
        {"The filter syntax is "}
        <Code>{"type[index].path=value"}</Code>
        {". Type is "}
        <Code>session</Code>
        {", "}
        <Code>wake</Code>
        {", or any JSONL entry type. Index is optional — without it, any entry of that type can match. Negative indices count from the end."}
      </Paragraph>
    </Section>

    <Section title="Reading transcripts">
      <Paragraph>
        <Code>sessions read</Code>
        {" renders session transcripts with windowed navigation. Jump to any part of a conversation without loading the whole thing:"}
      </Paragraph>

      <CodeBlock lang="bash">{`sessions read e96bd43a                     # full transcript
sessions read e96bd43a --last 10           # last 10 messages
sessions read e96bd43a --from 20 --to 30   # specific window
sessions read e96bd43a --from -5           # last 5 messages
sessions read e96bd43a --tools             # include tool calls`}</CodeBlock>

      <Paragraph>
        <Code>sessions wait</Code>
        {" snapshots the current transcript and blocks until new matching messages arrive. It is useful for supervising long-running or parallel sessions without hand-written sleep loops."}
      </Paragraph>

      <CodeBlock lang="bash">{`sessions wait e96bd43a                         # next non-tool message
sessions wait e96bd43a --count 10              # wait for 10 messages
sessions wait e96bd43a --assistant-only        # ignore user/operator messages
sessions wait e96bd43a --match "done|failed"   # wait for a regex match
sessions wait e96bd43a --tools                 # include tool calls/results
sessions wait e96bd43a --timeout 120 --json`}</CodeBlock>

      <Paragraph>
        <Code>sessions wait-any</Code>
        {" watches an explicit set of transcripts and returns when any assistant turn settles without another tool call or continuation. Provider errors and empty responses are settled events too, so supervision does not mistake them for silence. If several sessions settle in one poll, the command returns the whole batch."}
      </Paragraph>

      <CodeBlock lang="bash">{`# One shared structural condition across positional selectors
sessions wait-any e96bd43a 0e3330f8 --timeout 120

# Named watches plus durable cursors for repeated supervision loops
sessions wait-any --config watches.json \\
  --cursor-file /tmp/foreman-cursors.json --timeout 3600 --json`}</CodeBlock>

      <Paragraph>
        {"A config is a positive allowlist. It gives each session a stable source name without embedding foreman policy or transcript keywords:"}
      </Paragraph>

      <CodeBlock lang="json">{`{"version":1,"watches":[
  {"name":"review","session_id":"e96bd43a"},
  {"name":"deploy","session_id":"0e3330f8"}
]}`}</CodeBlock>

      <Paragraph>
        <Code>--cursor-file</Code>
        {" stores only resolved session paths, harness names, byte offsets, and entry indexes. Reusing it catches settled turns that arrived after the prior invocation returned without reparsing the full transcript; without it, the command deliberately snapshots current state like "}
        <Code>sessions wait</Code>
        {". Event cursors advance after output, so an interrupted delivery may replay an event rather than lose it. One sequential supervision loop should own a cursor file; concurrent writers are not coordinated. Timeout exits 124; JSON mode still emits a structured timeout event for a supervising loop."}
      </Paragraph>

      <Paragraph>
        <Code>sessions ps</Code>
        {" shows live and unverified local session processes recorded by "}
        <Code>sessions run</Code>
        {". If a PID probe fails or returns malformed output, the row remains "}
        <Code>unknown</Code>
        {" instead of disappearing as dead. By default it hides exited processes and verified-dead missing-exit records; pass "}
        <Code>--all</Code>
        {" to inspect those records too."}
      </Paragraph>

      <CodeBlock lang="bash">{`sessions ps                  # live or unknown managed processes
sessions ps --project k7r2   # filter by project/session path
sessions ps --all --json     # include exited and verified-dead records`}</CodeBlock>

      <Paragraph>
        <Code>sessions usage</Code>
        {" reports recorded token usage and cost. It works for one session, or across recent/date-filtered sessions, and attributes usage by the model active at each turn so model switches are visible."}
      </Paragraph>

      <CodeBlock lang="bash">{`sessions usage e96bd43a                  # one session summary
sessions usage e96bd43a --turns          # per-turn records
sessions usage --today                   # aggregate today's recorded usage
sessions usage --after 2026-06-01 --json # machine-readable aggregate`}</CodeBlock>

      <Paragraph>
        {"For existing sessions you want to work with elsewhere, "}
        <Code>copy</Code>
        {" duplicates a session with its full conversation history plus a fork notice. The copy gets a new ID and can be woken independently — useful for handing off context between agents."}
      </Paragraph>

      <CodeBlock lang="bash">{`sessions copy e96bd43a --context "continue the review"`}</CodeBlock>
    </Section>

    <Section title="Querying session history">
      <Paragraph>
        <Code>sessions query</Code>
        {" builds an ephemeral in-memory SQLite projection over local session JSONL files. JSONL remains the source of truth; no durable database is created. This is useful for ad hoc analysis across sessions, tools, messages, usage, and bash command status."}
      </Paragraph>

      <Paragraph>
        {"Privacy defaults are conservative: the default "}
        <Code>--text commands</Code>
        {" mode inserts redacted bash commands, but not message text or tool output excerpts. Use "}
        <Code>--text compact</Code>
        {" only when you intentionally want bounded excerpts, and reserve "}
        <Code>--text full</Code>
        {" for explicitly scoped local analysis."}
      </Paragraph>

      <CodeBlock lang="bash">{`# Show the query schema and examples
sessions query

# Use a packaged SQL preset over a recent project slice
sessions query --project junior/home --limit 30 \\
  --sql-file queries/bash-status.sql \\
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
sessions query e96bd43a --text compact \\
  --sql-file queries/bash-with-output.sql \\
  --format jsonl`}</CodeBlock>

      <Paragraph>
        {"Large result sets can be rendered as "}
        <Code>--format html</Code>
        {" or opened with "}
        <Code>--browser</Code>
        {" for a temporary local table with sticky headers and row filtering. Richer browser table controls are tracked separately so the first query surface can stay small."}
      </Paragraph>
    </Section>

    <Section title="Development">
      <CodeBlock lang="bash">{`git clone https://github.com/KnickKnackLabs/sessions.git
cd sessions && mise trust && mise install
mise run test`}</CodeBlock>

      <Paragraph>
        <Bold>{`${testCount} tests`}</Bold>
        {` across ${testSuiteCount} BATS and Python unittest suites. Shell and integration cases use `}
        <Link href="https://github.com/bats-core/bats-core">{`BATS ${batsVersion}`}</Link>
        {`. Tasks are bash scripts (session creation, wake, metadata) and Python scripts with `}
        <Link href="https://github.com/Textualize/rich">Rich</Link>
        {` output (list, read, wait, wait-any, usage, inspect, search). The shared Python support library is ${libLines} lines in `}
        <Code>lib/</Code>
        {"."}
      </Paragraph>

      <Paragraph>
        {"Python code is checked with "}
        <Link href="https://docs.astral.sh/ruff/">Ruff</Link>
        {" via "}
        <Code>mise run lint:python</Code>
        {", and CI runs the same lint/format check in addition to the BATS and Elixir suites."}
      </Paragraph>

      <Details summary="Project structure">
        <CodeBlock>{`sessions/
├── .mise/tasks/
│   ├── new          # Create sessions with prompt + metadata + context
│   ├── wake         # Wake agents into sessions via shell
│   ├── meta         # Read session header metadata
│   ├── list         # List + filter sessions (Rich tables)
│   ├── read         # Windowed transcript reader
│   ├── wait         # Wait for new transcript messages
│   ├── wait-any     # Wait across sessions for a settled turn
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
│   ├── wait_any.py     # Multi-session settled-turn polling + cursors
│   ├── ensure-deps.sh  # First-run CLI deps self-heal
│   ├── find.sh         # Back-compat shim → harness adapter
│   ├── shell.sh        # Shell helpers
│   ├── query/          # sessions query projection/rendering code
│   └── harness/        # Per-harness adapters (pi, …)
├── queries/            # Packaged sessions query SQL presets
└── test/
    ├── *.bats          # ${batsTestCount} shell and integration tests
    └── *_test.py       # ${pythonTestCount} focused Python unit tests`}</CodeBlock>
      </Details>
    </Section>

    <LineBreak />

    <Center>
      <HR />

      <Sub>
        {"Every session is structured data. Query it."}
        <Raw>{"<br />"}</Raw>{"\n"}
        <Raw>{"<br />"}</Raw>{"\n"}
        {"This README was generated from "}
        <HtmlLink href="https://github.com/KnickKnackLabs/readme">README.tsx</HtmlLink>
        {"."}
      </Sub>
    </Center>
  </>
);

console.log(readme);
