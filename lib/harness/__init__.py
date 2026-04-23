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
import sys

DEFAULT = "pi"

# Reserved exit code for UNSUPPORTED operations. Mirrored in
# `lib/harness/dispatch.sh` (HARNESS_UNSUPPORTED_EXIT=10) and
# `Cli.Harness.UnsupportedError` (Elixir).
UNSUPPORTED_EXIT = 10


class Unsupported(Exception):
    """Raised by adapter functions that don't implement a given operation.

    Adapters raise this with a short, user-facing message; the CLI
    entry point catches it, prints the message, and exits with
    `UNSUPPORTED_EXIT`. Aggregator code (e.g. `parse.find_session`) may
    catch it earlier to skip adapters that can't contribute to the
    aggregate — see call sites for which semantics apply.
    """


def exit_unsupported(harness: str, op: str) -> None:
    """Print the clean UNSUPPORTED message and exit the process.

    Call from CLI entry points after catching an `Unsupported` raised
    deep in an adapter. Kept here (not duplicated across .mise/tasks)
    so the wording is uniform.
    """
    print(
        f"sessions: '{harness}' harness does not support '{op}' yet",
        file=sys.stderr,
    )
    sys.exit(UNSUPPORTED_EXIT)


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
    names = available()
    if name not in names:
        raise ValueError(f"Unknown harness: {name!r} (available: {names})")
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
    """Infer harness from a path prefix. Returns None if no rule matches.

    Requires a trailing `/` after the prefix so `~/.pi-alt/...` does not
    get claimed by the pi adapter. Kept in sync with `lib/harness/dispatch.sh`
    and `cli/lib/harness.ex` — review all three together when editing.
    """
    if not filepath:
        return None
    # `os.environ.get(..., default)` returns the default only for *missing*
    # keys; an empty-string value still wins. Guard explicitly so
    # `PI_DIR=""` doesn't collapse the prefix to `"/"` (which would
    # match every absolute path).
    env_pi = os.environ.get("PI_DIR") or None
    home_pi = os.path.expanduser("~/.pi")
    candidates = set()
    if env_pi:
        candidates.add(env_pi.rstrip("/") + "/")
    candidates.add(home_pi.rstrip("/") + "/")
    if any(filepath.startswith(p) for p in candidates):
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
