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
    def name(self) -> str:
        """Get session name from the session header, or empty string."""
        for e in self.entries:
            if e.get("type") == "session":
                return e.get("name", "")
        return ""

    @property
    def slug(self) -> str:
        """Pi sessions don't have slugs."""
        return ""

    @property
    def meta(self) -> dict:
        """Get meta field from the session header, or empty dict."""
        for e in self.entries:
            if e.get("type") == "session":
                return e.get("meta", {})
        return {}

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
        result = {
            "session_id": self.session_id,
            "name": self.name,
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
        if self.meta:
            result["meta"] = self.meta
        return result

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


def dict_contains(haystack: dict, needle: dict) -> bool:
    """Check if haystack contains all keys/values from needle (recursive)."""
    for key, value in needle.items():
        if key not in haystack:
            return False
        if isinstance(value, dict):
            if not isinstance(haystack[key], dict):
                return False
            if not dict_contains(haystack[key], value):
                return False
        elif haystack[key] != value:
            return False
    return True


def parse_meta_filter(raw: str) -> dict:
    """Parse a meta filter string into a dict.

    Supports two formats:
      - Dotted key=value: "agent.name=ikma" → {"agent": {"name": "ikma"}}
      - JSON object: '{"agent": {"name": "ikma"}}' → as-is

    Returns empty dict on parse failure.
    """
    raw = raw.strip()
    if not raw:
        return {}

    # JSON object
    if raw.startswith("{"):
        try:
            return json.loads(raw)
        except json.JSONDecodeError:
            # Try evaluating via jq for jq-syntax (e.g., unquoted keys)
            import subprocess
            try:
                result = subprocess.run(
                    ["jq", "-nc", raw],
                    capture_output=True, text=True, timeout=5,
                )
                if result.returncode == 0:
                    return json.loads(result.stdout.strip())
            except (subprocess.TimeoutExpired, FileNotFoundError, json.JSONDecodeError):
                pass
            return {}

    # Dotted key=value
    if "=" in raw:
        key, _, value = raw.partition("=")
        parts = key.strip().split(".")
        result = {}
        current = result
        for i, part in enumerate(parts):
            if i == len(parts) - 1:
                current[part] = value
            else:
                current[part] = {}
                current = current[part]
        return result

    return {}


@dataclass
class Filter:
    """A parsed filter expression.

    entry_type: which JSONL entry type to match ('session', 'wake', etc.)
    index: optional index into entries of that type (0, 1, -1, None=any)
    path: dotted path within the entry (e.g., 'meta.agent.name')
    value: expected value
    """
    entry_type: str
    index: object  # int or None
    path: str
    value: str


def parse_filters(raw: str) -> list:
    """Parse filter string (from var=#true, space-separated by xargs) into Filter objects.

    Format: type[index].path=value
    Examples:
        session.meta.agent.name=ikma
        wake.meta.by.agent.name=ikma
        wake[0].meta.by.agent.name=ikma
        wake[-1].meta.by.agent.name=brownie
    """
    import shlex
    filters = []
    if not raw.strip():
        return filters

    # var=#true delivers multiple values as shell-escaped string
    try:
        parts = shlex.split(raw)
    except ValueError:
        parts = raw.split()

    for part in parts:
        part = part.strip()
        if not part or "=" not in part:
            continue

        lhs, _, value = part.partition("=")

        # Parse entry_type, optional index, and path
        # e.g., "wake[0].meta.by.agent.name" → type=wake, index=0, path=meta.by.agent.name
        # e.g., "session.meta.agent.name" → type=session, index=None, path=meta.agent.name
        index = None
        if "[" in lhs.split(".")[0]:
            type_part = lhs.split(".")[0]
            entry_type = type_part[:type_part.index("[")]
            idx_str = type_part[type_part.index("[") + 1:type_part.index("]")]
            try:
                index = int(idx_str)
            except ValueError:
                continue
            path = ".".join(lhs.split(".")[1:])
        else:
            entry_type = lhs.split(".")[0]
            path = ".".join(lhs.split(".")[1:])

        filters.append(Filter(entry_type=entry_type, index=index, path=path, value=value))

    return filters


def _get_nested(d: dict, dotted_path: str):
    """Get a value from a dict using a dotted path. Returns None if not found."""
    current = d
    for key in dotted_path.split("."):
        if not isinstance(current, dict) or key not in current:
            return None
        current = current[key]
    return current


def _entry_matches_filter(entry: dict, f: Filter) -> bool:
    """Check if a single JSONL entry matches a filter's path=value."""
    val = _get_nested(entry, f.path)
    if val is None:
        return False
    return str(val) == f.value


def session_matches_filters(session: 'Session', filters: list) -> bool:
    """Check if a session matches ALL filters."""
    for f in filters:
        # Collect entries of the specified type
        typed_entries = [e for e in session.entries if e.get("type") == f.entry_type]

        if f.index is not None:
            # Index-specific: check one entry
            try:
                entry = typed_entries[f.index]
            except IndexError:
                return False
            if not _entry_matches_filter(entry, f):
                return False
        else:
            # Any-match: at least one entry of this type must match
            if not any(_entry_matches_filter(e, f) for e in typed_entries):
                return False

    return True


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


def find_session(query: str) -> str:
    """Find a session JSONL file by ID prefix or name. Returns filepath or exits."""
    sessions_dir = discover_sessions_dir()
    if not os.path.isdir(sessions_dir):
        print(f"Error: No sessions directory at {sessions_dir}", file=sys.stderr)
        sys.exit(1)

    id_matches = []
    name_matches = []

    for project_dir in os.listdir(sessions_dir):
        project_path = os.path.join(sessions_dir, project_dir)
        if not os.path.isdir(project_path):
            continue
        for fname in os.listdir(project_path):
            if not fname.endswith(".jsonl"):
                continue
            filepath = os.path.join(project_path, fname)

            # Match against UUID part of filename
            uuid_part = fname.rsplit("_", 1)[-1].replace(".jsonl", "") if "_" in fname else fname.replace(".jsonl", "")
            if uuid_part.startswith(query) or fname.startswith(query):
                id_matches.append(filepath)
                continue

            # Match against session name in header
            try:
                with open(filepath) as f:
                    first_line = f.readline().strip()
                    if first_line:
                        header = json.loads(first_line)
                        name = header.get("name", "")
                        if name and name == query:
                            name_matches.append(filepath)
            except (json.JSONDecodeError, OSError):
                continue

    # ID matches take priority; fall back to name matches
    matches = id_matches if id_matches else name_matches

    if not matches:
        print(f"Error: No session matching '{query}'", file=sys.stderr)
        sys.exit(1)
    if len(matches) > 1:
        print(f"Error: Ambiguous query '{query}', matches:", file=sys.stderr)
        for m in matches:
            print(f"  {os.path.basename(m)}", file=sys.stderr)
        sys.exit(1)

    return matches[0]
