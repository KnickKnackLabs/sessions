"""
Claude harness adapter (Python) — step 3 skeleton.

Every function raises `Unsupported`. The structural behaviour that
allows the cross-adapter aggregator (`parse.find_session`) to keep
working is provided by `find_session` returning `None` instead of
raising.

Step 4 (claude new + wake) will fill in the real behaviour.
"""

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


# --- Location / lookup ---

def sessions_dir() -> str:
    raise Unsupported("sessions_dir", harness="claude")


def find_session(query: str):
    """Structural stub: no claude sessions exist yet.

    Unlike the other functions, this returns a sane "no match" sentinel
    rather than raising — `parse.find_session` iterates every registered
    adapter and would break lookup for pi sessions if claude raised.
    Step 4 will implement the real scan against claude's on-disk layout.
    """
    return None
