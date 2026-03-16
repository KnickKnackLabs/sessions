"""
Shared JSONL session parser for the sessions tooling.

Usage:
    import parse
    session = parse.load(filepath)
    # session.entries       — all raw JSONL dicts
    # session.messages      — user/assistant entries only
    # session.metadata()    — dict with id, project, model, timestamps, counts, etc.
    # session.text_messages() — list of (index, role, timestamp, text) tuples
"""

import json
import os
import sys
from dataclasses import dataclass, field
from typing import Any


@dataclass
class Session:
    filepath: str
    entries: list = field(default_factory=list)

    @property
    def messages(self) -> list:
        return [e for e in self.entries if e.get("type") in ("user", "assistant")]

    @property
    def session_id(self) -> str:
        for e in self.entries:
            sid = e.get("sessionId", "")
            if sid:
                return sid
        return os.path.basename(self.filepath).replace(".jsonl", "")

    @property
    def slug(self) -> str:
        for e in self.entries:
            s = e.get("slug", "")
            if s:
                return s
        return ""

    @property
    def project(self) -> str:
        """Decode the project directory name into a readable path."""
        dirname = os.path.basename(os.path.dirname(self.filepath))
        # Claude Code encodes paths: /Users/foo/bar -> -Users-foo-bar
        readable = dirname.replace("-", "/")
        if readable.startswith("/"):
            readable = readable[1:]
        # Trim to last two components (owner/repo style)
        parts = readable.split("/")
        if len(parts) >= 2:
            return "/".join(parts[-2:])
        return readable

    @property
    def model(self) -> str:
        for e in self.entries:
            if e.get("type") == "assistant":
                m = e.get("message", {}).get("model", "")
                if m and m != "<synthetic>":
                    return m
        return "unknown"

    @property
    def first_timestamp(self) -> str:
        for e in self.entries:
            ts = e.get("timestamp", "")
            if ts:
                return ts
        return ""

    @property
    def last_timestamp(self) -> str:
        for e in reversed(self.entries):
            ts = e.get("timestamp", "")
            if ts:
                return ts
        return ""

    def metadata(self) -> dict:
        user_count = sum(1 for e in self.entries if e.get("type") == "user")
        assistant_count = sum(1 for e in self.entries if e.get("type") == "assistant")
        return {
            "session_id": self.session_id,
            "slug": self.slug,
            "project": self.project,
            "model": self.model,
            "first_timestamp": self.first_timestamp,
            "last_timestamp": self.last_timestamp,
            "total_entries": len(self.entries),
            "user_messages": user_count,
            "assistant_messages": assistant_count,
            "filepath": self.filepath,
        }

    def text_messages(self) -> list:
        """
        Extract human-readable messages as (index, role, timestamp, text) tuples.
        Tool calls are rendered as [tool_use: name], tool results as [tool_result].
        """
        results = []
        for i, entry in enumerate(self.entries):
            etype = entry.get("type", "")
            if etype not in ("user", "assistant"):
                continue

            role = etype
            ts = entry.get("timestamp", "")
            msg = entry.get("message", {})
            content = msg.get("content", "")

            parts = []
            if isinstance(content, str):
                parts.append(content)
            elif isinstance(content, list):
                for block in content:
                    if not isinstance(block, dict):
                        continue
                    btype = block.get("type", "")
                    if btype == "text":
                        parts.append(block.get("text", ""))
                    elif btype == "tool_use":
                        name = block.get("name", "?")
                        inp = block.get("input", {})
                        # Show command for Bash, file_path for Read/Edit, pattern for Grep
                        detail = ""
                        if "command" in inp:
                            cmd = inp["command"]
                            detail = f" $ {cmd[:80]}" if len(cmd) <= 80 else f" $ {cmd[:77]}..."
                        elif "file_path" in inp:
                            detail = f" {inp['file_path']}"
                        elif "pattern" in inp:
                            detail = f" /{inp['pattern']}/"
                        parts.append(f"[tool_use: {name}{detail}]")
                    elif btype == "tool_result":
                        tc = block.get("content", "")
                        if isinstance(tc, str):
                            preview = tc[:100].replace("\n", " ")
                            parts.append(f"[tool_result: {preview}]")
                        elif isinstance(tc, list):
                            # Content array (e.g. text blocks inside tool_result)
                            for sub in tc:
                                if isinstance(sub, dict) and sub.get("type") == "text":
                                    preview = sub.get("text", "")[:100].replace("\n", " ")
                                    parts.append(f"[tool_result: {preview}]")
                                    break
                            else:
                                parts.append("[tool_result]")
                        else:
                            parts.append("[tool_result]")

            text = "\n".join(parts) if parts else "(empty)"

            # Skip synthetic "No response requested." entries unless they're the only content
            if text.strip() == "No response requested." and role == "assistant":
                model = msg.get("model", "")
                if model == "<synthetic>":
                    continue

            results.append((i, role, ts, text))

        return results


def load(filepath: str) -> Session:
    """Load a JSONL session file into a Session object."""
    entries = []
    with open(filepath) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                entries.append(json.loads(line))
            except json.JSONDecodeError:
                continue
    return Session(filepath=filepath, entries=entries)


def discover_sessions_dir() -> str:
    """Find the sessions directory. Respects CLAUDE_DIR env var for testing."""
    claude_dir = os.environ.get("CLAUDE_DIR", os.path.expanduser("~/.claude"))
    return os.path.join(claude_dir, "projects")


def find_session(session_id: str) -> str:
    """Find a session JSONL file by ID (prefix match supported). Returns filepath or exits."""
    sessions_dir = discover_sessions_dir()
    if not os.path.isdir(sessions_dir):
        print(f"Error: No sessions directory at {sessions_dir}", file=sys.stderr)
        sys.exit(1)

    matches = []
    for project_dir in os.listdir(sessions_dir):
        project_path = os.path.join(sessions_dir, project_dir)
        if not os.path.isdir(project_path):
            continue
        for fname in os.listdir(project_path):
            if fname.endswith(".jsonl") and fname.startswith(session_id):
                matches.append(os.path.join(project_path, fname))

    if not matches:
        print(f"Error: No session matching '{session_id}'", file=sys.stderr)
        sys.exit(1)
    if len(matches) > 1:
        print(f"Error: Ambiguous session ID '{session_id}', matches:", file=sys.stderr)
        for m in matches:
            print(f"  {os.path.basename(m)}", file=sys.stderr)
        sys.exit(1)

    return matches[0]
