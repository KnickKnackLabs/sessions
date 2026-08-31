"""
Claude harness adapter (Python) — location and lookup only.

Entry normalization for `read` / `search` / `list` / `inspect` is step 5
of sessions#50 and still raises `Unsupported`. Location and lookup are
implemented here because step 4 creates real claude sessions on disk: a
`find_session` that always returned None would make every Python-side
command report a session that plainly exists as missing, which reads as
breakage rather than as an unimplemented surface. Locating the session
and then failing with "'claude' harness does not support 'messages'
yet" is the honest boundary.

Kept in sync with `lib/harness/claude.sh` — the two implement the same
layout and lookup rules.
"""

import json
import os

from harness import Unsupported


# --- Entry-level schema ---


def is_message_entry(entry: dict) -> bool:
    raise Unsupported("is_message_entry", harness="claude")


def messages(entries: list) -> list:
    raise Unsupported("messages", harness="claude")


def session_id(entries: list, filepath: str) -> str:
    raise Unsupported("session_id", harness="claude")


def name(entries: list) -> str:
    raise Unsupported("name", harness="claude")


def meta(entries: list) -> dict:
    raise Unsupported("meta", harness="claude")


def slug() -> str:
    raise Unsupported("slug", harness="claude")


def model(entries: list) -> str:
    raise Unsupported("model", harness="claude")


def project(filepath: str) -> str:
    raise Unsupported("project", harness="claude")


def first_timestamp(entries: list) -> str:
    raise Unsupported("first_timestamp", harness="claude")


def last_timestamp(entries: list) -> str:
    raise Unsupported("last_timestamp", harness="claude")


def message_counts(entries: list) -> tuple:
    raise Unsupported("message_counts", harness="claude")


def text_messages(entries: list) -> list:
    raise Unsupported("text_messages", harness="claude")


def settled_turn(entry: dict, index: int) -> dict | None:
    raise Unsupported("settled_turn", harness="claude")


def usage_records(entries: list) -> list:
    raise Unsupported("usage", harness="claude")


# --- Location / lookup ---


def sessions_dir() -> str:
    """Claude transcript root. Honours $CLAUDE_DIR for tests; defaults to ~/.claude."""
    claude_dir = os.environ.get("CLAUDE_DIR") or os.path.expanduser("~/.claude")
    return os.path.join(claude_dir, "projects")


def find_session(query: str):
    """Find a claude session JSONL by UUID prefix or session name.

    Same contract as pi's: filepath on a unique match, None on no match
    (the dispatcher aggregates across adapters and owns the final "not
    found" message), ValueError on ambiguity within this adapter.

    Claude names transcripts `<uuid>.jsonl` with no timestamp prefix.
    Name lookup works because `sessions new` writes its own session
    header as line 1 — see harness_claude_header_entry.
    """
    root = sessions_dir()
    if not os.path.isdir(root):
        # No transcript directory is not an error — this adapter has no
        # sessions; other adapters may.
        return None

    id_matches = []
    name_matches = []

    for project_dir in os.listdir(root):
        project_path = os.path.join(root, project_dir)
        if not os.path.isdir(project_path):
            continue
        for fname in os.listdir(project_path):
            if not fname.endswith(".jsonl"):
                continue
            filepath = os.path.join(project_path, fname)

            if fname[: -len(".jsonl")].startswith(query):
                id_matches.append(filepath)
                continue

            try:
                with open(filepath) as f:
                    first_line = f.readline().strip()
                    if first_line:
                        header = json.loads(first_line)
                        if header.get("type") == "session":
                            hname = header.get("name", "")
                            if hname and hname == query:
                                name_matches.append(filepath)
            except (json.JSONDecodeError, OSError):
                # Malformed header is a benign skip, not a hard error.
                continue

    matches = id_matches if id_matches else name_matches

    if not matches:
        return None
    if len(matches) > 1:
        raise ValueError(
            f"Ambiguous query '{query}' matches multiple claude sessions:\n"
            + "\n".join(f"  {os.path.basename(m)}" for m in matches)
        )
    return matches[0]
