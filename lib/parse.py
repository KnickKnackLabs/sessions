"""
Shared JSONL session parser for the sessions tooling.

This module is deliberately harness-agnostic: it loads JSONL files,
exposes a `Session` container, and implements filter parsing that
works against any dotted-path + value expression.

Harness schema knowledge (pi-specific, claude-specific, ...) lives in
`lib/harness/<name>.py`. `lib/harness/__init__.py` resolves which adapter
to use for a given session. Step 2 of sessions#50.

Usage:
    import parse
    session = parse.load(filepath)
    # session.entries       — all raw JSONL dicts
    # session.messages      — user/assistant message entries
    # session.metadata()    — dict with id, project, model, timestamps, counts, etc.
    # session.text_messages() — list of (index, role, timestamp, text) tuples
"""

import json
import sys
from dataclasses import dataclass, field

import harness


@dataclass
class Session:
    filepath: str
    entries: list = field(default_factory=list)

    @property
    def _h(self):
        """Cached adapter module for this session's harness."""
        if not hasattr(self, "_h_cached"):
            self._h_cached = harness.resolve(
                filepath=self.filepath, entries=self.entries
            )
        return self._h_cached

    @property
    def messages(self) -> list:
        return self._h.messages(self.entries)

    @property
    def session_id(self) -> str:
        return self._h.session_id(self.entries, self.filepath)

    @property
    def name(self) -> str:
        return self._h.name(self.entries)

    @property
    def slug(self) -> str:
        return self._h.slug()

    @property
    def meta(self) -> dict:
        return self._h.meta(self.entries)

    @property
    def project(self) -> str:
        return self._h.project(self.filepath)

    @property
    def model(self) -> str:
        return self._h.model(self.entries)

    @property
    def first_timestamp(self) -> str:
        return self._h.first_timestamp(self.entries)

    @property
    def last_timestamp(self) -> str:
        return self._h.last_timestamp(self.entries)

    def metadata(self) -> dict:
        user_count, assistant_count = self._h.message_counts(self.entries)
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
        return self._h.text_messages(self.entries)


# --- Generic helpers (harness-agnostic) ---

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
        typed_entries = [e for e in session.entries if e.get("type") == f.entry_type]

        if f.index is not None:
            try:
                entry = typed_entries[f.index]
            except IndexError:
                return False
            if not _entry_matches_filter(entry, f):
                return False
        else:
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


# --- Top-level lookup (harness-aware) ---
#
# Used by: .mise/tasks/{export,import,list}. Each function iterates over
# all available harnesses and merges the results. Today pi is the only
# adapter, so the iteration has one iteration — the shape is ready for
# when claude (or another adapter) lands.

def discover_sessions_dir() -> str:
    """Return the default harness's sessions root.

    Kept for back-compat with tasks that want "the" sessions dir; with
    multiple harnesses installed, prefer iterating `harness.available()`
    and calling each adapter's `sessions_dir()` directly.
    """
    return harness.adapter(harness.DEFAULT).sessions_dir()


def find_session(query: str) -> str:
    """Find a session JSONL by UUID prefix or name across all harnesses.

    Adapters return Optional[str] from their own `find_session` (None on
    no-match) and raise `ValueError` on within-adapter ambiguity. Hard
    errors (permission denied, etc.) propagate as normal exceptions
    rather than being caught.

    Exits non-zero with a clear message on no-match across all adapters,
    on any adapter's within-adapter ambiguity, or on cross-adapter
    ambiguity (two adapters each find a unique match).
    """
    matches = []
    for name in harness.available():
        adapter = harness.adapter(name)
        try:
            match = adapter.find_session(query)
        except ValueError as e:
            # Within-adapter ambiguity — surface and stop.
            print(f"Error: {e}", file=sys.stderr)
            sys.exit(1)
        if match is not None:
            matches.append(match)

    if not matches:
        print(f"Error: No session matching '{query}'", file=sys.stderr)
        sys.exit(1)
    if len(matches) > 1:
        print(
            f"Error: Ambiguous query '{query}', matches across harnesses:",
            file=sys.stderr,
        )
        for m in matches:
            print(f"  {m}", file=sys.stderr)
        sys.exit(1)
    return matches[0]
