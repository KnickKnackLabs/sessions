/** @jsxImportSource jsx-md */

import {
  Heading,
  Paragraph,
  Bold,
  Code,
  CodeBlock,
  Section,
  Table,
  TableHead,
  TableRow,
  Cell,
  HR,
  Center,
  List,
  Item,
} from "readme/src/components";

const readme = (
  <>
    <Center>
      <Heading level={1}>sessions</Heading>
      <Paragraph>
        <Bold>Mise-based CLI tooling for working with Wibey/Claude Code session transcripts.</Bold>
      </Paragraph>
      <Paragraph>
        List, search, inspect, and export your conversation history from the terminal.
      </Paragraph>
    </Center>

    <HR />

    <Section title="What is this?">
      <Paragraph>
        Wibey (and Claude Code) store every conversation as a JSONL file on disk.
        This project provides <Code>mise run</Code> commands that let you query,
        search, and export those transcripts — useful for resuming context after
        compaction, auditing tool usage, or transferring sessions between machines.
      </Paragraph>
    </Section>

    <Section title="Install">
      <CodeBlock lang="bash">{[
        `git clone https://gecgithub01.walmart.com/vn5a6e7/sessions.git`,
        `cd sessions && mise trust && mise install`,
      ].join("\n")}</CodeBlock>
    </Section>

    <Section title="Commands">
      <Table>
        <TableHead>
          <Cell>Command</Cell>
          <Cell>Description</Cell>
        </TableHead>
        <TableRow>
          <Cell><Code>sessions list</Code></Cell>
          <Cell>List recent sessions with ID, project, model, date, and message count</Cell>
        </TableRow>
        <TableRow>
          <Cell><Code>{"sessions show <id>"}</Code></Cell>
          <Cell>Pretty-print a full session transcript with role markers and timestamps</Cell>
        </TableRow>
        <TableRow>
          <Cell><Code>{"sessions tail <id>"}</Code></Cell>
          <Cell>Show the last N messages — quick "where was I?" for resuming</Cell>
        </TableRow>
        <TableRow>
          <Cell><Code>{"sessions inspect <id>"}</Code></Cell>
          <Cell>Forensic metadata: duration, model, tools used, context snapshots, compaction status</Cell>
        </TableRow>
        <TableRow>
          <Cell><Code>{"sessions search <query>"}</Code></Cell>
          <Cell>Full-text regex search across all session transcripts</Cell>
        </TableRow>
        <TableRow>
          <Cell><Code>{"sessions export <id>"}</Code></Cell>
          <Cell>Export as a portable bundle (JSONL + metadata), markdown, or plain JSONL</Cell>
        </TableRow>
        <TableRow>
          <Cell><Code>{"sessions import <path>"}</Code></Cell>
          <Cell>Import a previously exported session bundle</Cell>
        </TableRow>
      </Table>
    </Section>

    <Section title="Examples">
      <Paragraph><Bold>List your 10 most recent sessions:</Bold></Paragraph>
      <CodeBlock lang="bash">{`mise run list --limit 10`}</CodeBlock>

      <Paragraph><Bold>See the last 5 messages of a session (prefix match on ID):</Bold></Paragraph>
      <CodeBlock lang="bash">{`mise run tail b94b7b8a --limit 5 --no-tools`}</CodeBlock>

      <Paragraph><Bold>Search for "sccache" across all sessions:</Bold></Paragraph>
      <CodeBlock lang="bash">{`mise run search "sccache"`}</CodeBlock>

      <Paragraph><Bold>Inspect a session's metadata:</Bold></Paragraph>
      <CodeBlock lang="bash">{`mise run inspect b94b7b8a`}</CodeBlock>

      <Paragraph><Bold>Export a session as markdown:</Bold></Paragraph>
      <CodeBlock lang="bash">{`mise run export b94b7b8a --format markdown --output ~/exports`}</CodeBlock>

      <Paragraph><Bold>Export and import (transfer to another machine):</Bold></Paragraph>
      <CodeBlock lang="bash">{[
        `# On source machine:`,
        `mise run export b94b7b8a --format bundle --output ~/transfer`,
        ``,
        `# Copy ~/transfer/b94b7b8a-.../ to target machine, then:`,
        `mise run import ~/transfer/b94b7b8a-.../`,
      ].join("\n")}</CodeBlock>
    </Section>

    <Section title="How it works">
      <Paragraph>
        Session JSONL files live in <Code>~/.claude/projects/</Code>, organized by
        project directory. Each file contains one JSON object per line — user messages,
        assistant responses (with tool calls), and queue operations.
      </Paragraph>
      <Paragraph>
        All commands are Python 3 scripts under <Code>.mise/tasks/</Code> that share
        a common parser (<Code>lib/parse.py</Code>). The <Code>CLAUDE_DIR</Code> env
        var can override the default <Code>~/.claude</Code> path, which the BATS test
        suite uses for isolated testing.
      </Paragraph>
    </Section>

    <Section title="Testing">
      <CodeBlock lang="bash">{`mise run test`}</CodeBlock>
      <Paragraph>
        Runs the BATS test suite (50 tests) against synthetic JSONL data.
        Tests are fully isolated via <Code>CLAUDE_DIR</Code> override — no real
        sessions are read or modified.
      </Paragraph>
    </Section>

    <Section title="Relationship to KnickKnackLabs/sessions">
      <Paragraph>
        This is a Wibey-focused fork of the concept from{" "}
        <Code>KnickKnackLabs/sessions</Code>, which targets Claude Code on public
        GitHub. This repo lives on Walmart GHE and can include Wibey-specific features
        (debug log parsing, MCP tool awareness, etc.) without leaking internal details.
      </Paragraph>
      <Paragraph>
        Long term, both repos should converge on a shared interface with pluggable
        provider backends (Claude Code vs Wibey). The JSONL format is identical — only
        paths and metadata differ.
      </Paragraph>
    </Section>

    <Section title="Structure">
      <CodeBlock lang="text">{[
        `sessions/`,
        `├── .mise/tasks/`,
        `│   ├── list        # List sessions`,
        `│   ├── show        # Pretty-print transcript`,
        `│   ├── tail        # Last N messages`,
        `│   ├── inspect     # Forensic metadata`,
        `│   ├── search      # Full-text search`,
        `│   ├── export      # Export (bundle/markdown/jsonl)`,
        `│   ├── import      # Import bundle`,
        `│   └── test        # Run BATS tests`,
        `├── lib/`,
        `│   └── parse.py    # Shared JSONL parser`,
        `├── test/`,
        `│   ├── helpers.bash`,
        `│   ├── list.bats`,
        `│   ├── show.bats`,
        `│   ├── tail.bats`,
        `│   ├── inspect.bats`,
        `│   ├── search.bats`,
        `│   ├── export.bats`,
        `│   └── import.bats`,
        `├── mise.toml`,
        `└── README.tsx      # This file (generates README.md)`,
      ].join("\n")}</CodeBlock>
    </Section>
  </>
);

console.log(readme);
