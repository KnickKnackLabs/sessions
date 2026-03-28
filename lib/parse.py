"""
Shared JSONL session parser for the sessions tooling.

Parses pi's session log format (~/.pi/agent/sessions/).

Usage:
    import parse
    session = parse.load(filepath)
    # session.entries       — all raw JSONL dicts
    # session.messages      — user/assistant message entries only
    # session.metadata()    — dict with id, project, model, timestamps, counts, etc.
    # session.text_messages() — list of (index, role, timestamp, text) tuples
"""

import json
import os
import re
import sys
from dataclasses import dataclass, field


@dataclass
class Session:
    filepath: str
    entries: list = field(default_factory=list)

    @property
    def messages(self) -> list:
        """Return message entries with user or assistant role."""
        return [
            e for e in self.entries
            if e.get("type") == "message"
            and e.get("message", {}).get("role") in ("user", "assistant")
        ]

    @property
    def session_id(self) -> str:
        """Get session ID from the session header entry, or derive from filename."""
        for e in self.entries:
            if e.get("type") == "session":
                return e.get("id", "")
        # Fallback: extract UUID from pi filename (timestamp_uuid.jsonl)
        basename = os.path.basename(self.filepath).replace(".jsonl", "")
        parts = basename.rsplit("_", 1)
        return parts[-1] if len(parts) == 2 else basename

    @property
    def slug(self) -> str:
        """Pi sessions don't have slugs."""
        return ""

    @property
    def project(self) -> str:
        """Decode the project directory name into a readable path.

        Pi encodes paths with double-dash bookends: --Users-foo-bar--
        """
        dirname = os.path.basename(os.path.dirname(self.filepath))
        # Strip double-dash bookends
        if dirname.startswith("--") and dirname.endswith("--"):
            dirname = dirname[2:-2]
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
        """Get model from first model_change entry or first assistant message."""
        for e in self.entries:
            if e.get("type") == "model_change":
                m = e.get("modelId", "")
                if m:
                    return m
        # Fallback: check assistant messages
        for e in self.entries:
            if e.get("type") == "message":
                msg = e.get("message", {})
                if msg.get("role") == "assistant":
                    m = msg.get("model", "")
                    if m:
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
        user_count = 0
        assistant_count = 0
        for e in self.entries:
            if e.get("type") != "message":
                continue
            role = e.get("message", {}).get("role", "")
            if role == "user":
                user_count += 1
            elif role == "assistant":
                assistant_count += 1
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
            if entry.get("type") != "message":
                continue

            msg = entry.get("message", {})
            role = msg.get("role", "")
            ts = entry.get("timestamp", "")

            if role == "user":
                parts = self._extract_text_content(msg)
                text = "\n".join(parts) if parts else "(empty)"
                results.append((i, "user", ts, text))

            elif role == "assistant":
                parts = self._extract_assistant_content(msg)
                text = "\n".join(parts) if parts else "(empty)"
                results.append((i, "assistant", ts, text))

            elif role == "toolResult":
                # Tool results are separate entries in pi format
                tool_name = msg.get("toolName", "?")
                content = msg.get("content", [])
                preview = self._extract_tool_result_preview(content)
                text = f"[tool_result: {tool_name}: {preview}]" if preview else f"[tool_result: {tool_name}]"
                results.append((i, "user", ts, text))

        return results

    def _extract_text_content(self, msg: dict) -> list:
        """Extract text from a user message's content."""
        content = msg.get("content", "")
        parts = []
        if isinstance(content, str):
            parts.append(content)
        elif isinstance(content, list):
            for block in content:
                if not isinstance(block, dict):
                    continue
                if block.get("type") == "text":
                    parts.append(block.get("text", ""))
        return parts

    def _extract_assistant_content(self, msg: dict) -> list:
        """Extract text and tool call summaries from an assistant message."""
        content = msg.get("content", [])
        parts = []
        if isinstance(content, str):
            parts.append(content)
            return parts
        if not isinstance(content, list):
            return parts

        for block in content:
            if not isinstance(block, dict):
                continue
            btype = block.get("type", "")

            if btype == "text":
                parts.append(block.get("text", ""))

            elif btype == "toolCall":
                name = block.get("name", "?")
                args = block.get("arguments", {})
                detail = self._format_tool_detail(name, args)
                parts.append(f"[tool_use: {name}{detail}]")

            elif btype == "thinking":
                # Skip thinking blocks in output — they're internal reasoning
                pass

        return parts

    def _format_tool_detail(self, name: str, args: dict) -> str:
        """Format tool call arguments into a brief summary."""
        if "command" in args:
            cmd = args["command"]
            return f" $ {cmd[:80]}" if len(cmd) <= 80 else f" $ {cmd[:77]}..."
        elif "path" in args:
            return f" {args['path']}"
        elif "file_path" in args:
            return f" {args['file_path']}"
        elif "pattern" in args:
            return f" /{args['pattern']}/"
        return ""

    def _extract_tool_result_preview(self, content) -> str:
        """Extract a short preview from tool result content."""
        if isinstance(content, str):
            return content[:100].replace("\n", " ")
        elif isinstance(content, list):
            for block in content:
                if isinstance(block, dict) and block.get("type") == "text":
                    return block.get("text", "")[:100].replace("\n", " ")
        return ""


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
    """Find the pi sessions directory. Respects PI_DIR env var for testing."""
    pi_dir = os.environ.get("PI_DIR", os.path.expanduser("~/.pi"))
    return os.path.join(pi_dir, "agent", "sessions")


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
            if not fname.endswith(".jsonl"):
                continue
            # Pi filenames: <timestamp>_<uuid>.jsonl — match against UUID part
            uuid_part = fname.rsplit("_", 1)[-1].replace(".jsonl", "") if "_" in fname else fname.replace(".jsonl", "")
            if uuid_part.startswith(session_id) or fname.startswith(session_id):
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
