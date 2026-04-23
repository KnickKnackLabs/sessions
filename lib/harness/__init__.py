"""
Harness dispatch layer (Python).

Mirrors `lib/harness/dispatch.sh`. Resolves which harness adapter to use
for a given session and returns the adapter module.

Resolver priority (highest first):
  1. Explicit name passed in (caller already knows)
  2. Most recent {"type": "harness"} entry in the session's entry list
  3. Path-based detection (session file under ~/.pi/... → pi)
  4. $SESSIONS_DEFAULT_HARNESS environment variable
  5. Compile-time default: "pi"

Each adapter lives in a sibling module (pi, claude, ...) and exposes the
same surface — see `pi.py` for the reference.
"""

import importlib
import os

DEFAULT = "pi"


# --- Registry ---

def available() -> list:
    """List adapter names present in this package, sorted."""
    harness_dir = os.path.dirname(__file__)
    names = []
    for fname in os.listdir(harness_dir):
        if fname.endswith(".py") and fname not in ("__init__.py",):
            names.append(fname[:-3])
    return sorted(names)


def _load(name: str):
    """Import and return an adapter module by name. Raises ValueError if unknown."""
    if name not in available():
        raise ValueError(
            f"Unknown harness: {name!r} (available: {available()})"
        )
    return importlib.import_module(f"harness.{name}")


# --- Resolver inputs ---

def _from_entries(entries: list):
    """Scan entries in reverse; return the most recent harness-declaration name."""
    if not entries:
        return None
    for e in reversed(entries):
        if e.get("type") == "harness":
            n = e.get("name")
            if n:
                return n
    return None


def _from_path(filepath: str):
    """Infer harness from a path prefix. Returns None if no rule matches."""
    if not filepath:
        return None
    pi_dir = os.environ.get("PI_DIR", os.path.expanduser("~/.pi"))
    if filepath.startswith(pi_dir) or filepath.startswith(os.path.expanduser("~/.pi")):
        return "pi"
    # Future: ~/.claude/... → claude
    return None


# --- Resolver ---

def resolve(*, filepath: str = None, entries: list = None, name: str = None):
    """Resolve the harness for a session. Returns the adapter module.

    Callers typically provide (filepath, entries) together since they've
    already loaded the JSONL. Passing `name` short-circuits the resolver
    for cases where the caller knows the harness explicitly (e.g. tests).

    Raises ValueError if the resolved name is not a known adapter.
    """
    resolved = name
    if not resolved:
        resolved = _from_entries(entries)
    if not resolved:
        resolved = _from_path(filepath)
    if not resolved:
        resolved = os.environ.get("SESSIONS_DEFAULT_HARNESS")
    if not resolved:
        resolved = DEFAULT
    return _load(resolved)


# --- Convenience for non-session callers ---

def adapter(name: str):
    """Load an adapter module by name. Prefer `resolve()` when you have a session."""
    return _load(name)
