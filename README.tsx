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

// Count tests from .bats files
const testFiles = readdirSync(TEST_DIR).filter((f) => f.endsWith(".bats"));
const testSrc = testFiles
  .map((f) => readFileSync(join(TEST_DIR, f), "utf-8"))
  .join("\n");
const testCount = [...testSrc.matchAll(/@test "/g)].length;

// Extract tool versions from mise.toml
const miseToml = readFileSync(join(ROOT, "mise.toml"), "utf-8");
const batsVersion =
  miseToml.match(/bats\s*=\s*"([^"]+)"/)?.[1] ?? "latest";

// Count Python lib lines for the "how it works" credibility
const libDir = join(ROOT, "lib");
const libFiles = readdirSync(libDir).filter((f) => f.endsWith(".py"));
const libLines = libFiles.reduce(
  (sum, f) => sum + readFileSync(join(libDir, f), "utf-8").split("\n").length,
  0
);

// ── Visual hook ──────────────────────────────────────────────

const lifecycle = [
  "$ sessions new review/pr-50 --cwd ~/agents/ikma/den --meta agent.name=ikma",
  "e96bd43a",
  "",
  "$ sessions wake review/pr-50 --message \"review PR #50\"",
  "Woke session 'review/pr-50'",
  "",
  "$ sessions read review/pr-50 --last 3",
  "┃ assistant  Found 3 issues in error handling.",
  "┃ assistant  Posted review to #scout-report.",
  "",
  "$ sessions list --filter session.meta.agent.name=ikma",
  "  e96bd43a  review/pr-50   12m   3m ago   claude-sonnet-4   8",
].join("\n");

// ── Spawning stack ───────────────────────────────────────────

const stack = [
  "  sessions new              create session with metadata + context",
  "  sessions wake             wake an agent into it via shell",
  "    └─ shell run            persistent zmx session",
  "         └─ shimmer agent   identity + chat attribution",
  "              └─ pi         harness — processes message, exits",
  "  sessions read             observe the transcript",
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

# Search across all sessions
sessions search "error handling"

# Inspect forensic metadata
sessions inspect e96bd43a`}</CodeBlock>
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

      <CodeBlock lang="bash">{`# Create a named session with metadata and context
sessions new review/pr-50 --cwd ~/agents/ikma/den \\
  --meta agent.name=ikma \\
  --meta purpose=review \\
  --context "Background: this PR refactors the auth module"

# Wake an agent into it (by name)
sessions wake review/pr-50 --message "Review PR #50"

# Watch what it does
sessions read review/pr-50 --last 5

# Something went wrong? Wake the same session again.
sessions wake review/pr-50 --message "You missed the edge case in line 42"`}</CodeBlock>

      <Paragraph>
        {"The spawning stack uses "}
        <Link href="https://github.com/KnickKnackLabs/shell">shell</Link>
        {" for persistent zmx sessions. "}
        <Code>sessions wake</Code>
        {" calls "}
        <Code>sessions run</Code>
        {" directly for execution \u2014 identity (AGENT_IDENTITY, etc.) must already be in the environment, typically set upstream via "}
        <Code>{"eval $(shimmer as <agent>)"}</Code>
        {"."}
      </Paragraph>
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
        {"For existing sessions you want to work with elsewhere, "}
        <Code>copy</Code>
        {" duplicates a session with its full conversation history plus a fork notice. The copy gets a new ID and can be woken independently — useful for handing off context between agents."}
      </Paragraph>

      <CodeBlock lang="bash">{`sessions copy e96bd43a --context "continue the review"`}</CodeBlock>
    </Section>

    <Section title="Development">
      <CodeBlock lang="bash">{`git clone https://github.com/KnickKnackLabs/sessions.git
cd sessions && mise trust && mise install
mise run test`}</CodeBlock>

      <Paragraph>
        <Bold>{`${testCount} tests`}</Bold>
        {` across ${testFiles.length} suites, using `}
        <Link href="https://github.com/bats-core/bats-core">{`BATS ${batsVersion}`}</Link>
        {`. Tasks are bash scripts (session creation, wake, metadata) and Python scripts with `}
        <Link href="https://github.com/Textualize/rich">Rich</Link>
        {` output (list, read, inspect, search). The JSONL parsing library is ${libLines} lines of Python in `}
        <Code>lib/</Code>
        {"."}
      </Paragraph>

      <Details summary="Project structure">
        <CodeBlock>{`sessions/
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
│   ├── parse.py     # JSONL parser, session model, filter engine
│   └── format.py    # Rich formatting helpers
└── test/
    └── *.bats       # ${testCount} tests`}</CodeBlock>
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
