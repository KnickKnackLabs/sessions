"""
Pi harness adapter (Python).

Authoritative home for pi-specific knowledge used by the read/search/
list/inspect tasks:
  - Where pi stores sessions on disk
  - How pi encodes paths into project directory names
  - Pi's JSONL entry schema (session header, model_change, message,
    toolResult, wake, etc.)
  - Tool-call argument shapes in pi's content blocks

Step 1b of multi-harness support (sessions#50): pure extraction from
parse.py. Other harnesses will live in sibling modules
(lib/harness/claude.py, etc.); step 2 will add a dispatcher.

All functions are pure — they take raw entry lists and filepaths,
return the derived value. No I/O except in the discover/find helpers
at the bottom.
"""

import json
import os
import sys


# --- Entry-level schema ---

def is_message_entry(entry: dict) -> bool:
    """True if `entry` is a pi user/assistant message."""
    return (
        entry.get("type") == "message"
        and entry.get("message", {}).get("role") in ("user", "assistant")
    )


def messages(entries: list) -> list:
    """Return all user/assistant message entries."""
    return [e for e in entries if is_message_entry(e)]


def session_id(entries: list, filepath: str) -> str:
    """Session ID from the pi session header, falling back to filename UUID."""
    for e in entries:
        if e.get("type") == "session":
            return e.get("id", "")
    basename = os.path.basename(filepath).replace(".jsonl", "")
    parts = basename.rsplit("_", 1)
    return parts[-1] if len(parts) == 2 else basename


def name(entries: list) -> str:
    """Session name from the pi session header, or empty string."""
    for e in entries:
        if e.get("type") == "session":
            return e.get("name", "")
    return ""


def meta(entries: list) -> dict:
    """Meta dict from the pi session header, or empty dict."""
    for e in entries:
        if e.get("type") == "session":
            return e.get("meta", {})
    return {}


def slug() -> str:
    """Pi sessions don't have slugs.

    Kept as a no-arg function so the dispatcher in step 2 can route to
    per-harness implementations uniformly. Harnesses that derive slugs
    from entries (if any emerge) will introduce their own signature.
    """
    return ""


def model(entries: list) -> str:
    """Model from the first pi model_change entry, falling back to assistant message."""
    for e in entries:
        if e.get("type") == "model_change":
            m = e.get("modelId", "")
            if m:
                return m
    for e in entries:
        if e.get("type") == "message":
            msg = e.get("message", {})
            if msg.get("role") == "assistant":
                m = msg.get("model", "")
                if m:
                    return m
    return "unknown"


def project(filepath: str) -> str:
    """Decode pi's project directory name into a readable owner/repo path.

    Pi encodes paths with double-dash bookends: --Users-foo-bar--
    """
    dirname = os.path.basename(os.path.dirname(filepath))
    if dirname.startswith("--") and dirname.endswith("--"):
        dirname = dirname[2:-2]
    readable = dirname.replace("-", "/")
    if readable.startswith("/"):
        readable = readable[1:]
    parts = readable.split("/")
    if len(parts) >= 2:
        return "/".join(parts[-2:])
    return readable


def first_timestamp(entries: list) -> str:
    for e in entries:
        ts = e.get("timestamp", "")
        if ts:
            return ts
    return ""


def last_timestamp(entries: list) -> str:
    for e in reversed(entries):
        ts = e.get("timestamp", "")
        if ts:
            return ts
    return ""


def message_counts(entries: list) -> tuple[int, int]:
    """Return (user_count, assistant_count) for pi message entries."""
    user_count = 0
    assistant_count = 0
    for e in entries:
        if e.get("type") != "message":
            continue
        role = e.get("message", {}).get("role", "")
        if role == "user":
            user_count += 1
        elif role == "assistant":
            assistant_count += 1
    return user_count, assistant_count


# --- Text rendering ---

def text_messages(entries: list) -> list:
    """
    Render pi's JSONL entries into (index, role, timestamp, text) tuples.

    Tool calls become `[tool_use: name ...]`, tool results become
    `[tool_result: name: preview]`, thinking blocks are skipped.
    """
    results = []
    for i, entry in enumerate(entries):
        if entry.get("type") != "message":
            continue

        msg = entry.get("message", {})
        role = msg.get("role", "")
        ts = entry.get("timestamp", "")

        if role == "user":
            parts = _extract_text_content(msg)
            text = "\n".join(parts) if parts else "(empty)"
            results.append((i, "user", ts, text))

        elif role == "assistant":
            parts = _extract_assistant_content(msg)
            text = "\n".join(parts) if parts else "(empty)"
            results.append((i, "assistant", ts, text))

        elif role == "toolResult":
            tool_name = msg.get("toolName", "?")
            content = msg.get("content", [])
            preview = _extract_tool_result_preview(content)
            text = (
                f"[tool_result: {tool_name}: {preview}]"
                if preview else f"[tool_result: {tool_name}]"
            )
            results.append((i, "user", ts, text))

    return results


def _extract_text_content(msg: dict) -> list:
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


def _extract_assistant_content(msg: dict) -> list:
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
            tool_name = block.get("name", "?")
            args = block.get("arguments", {})
            detail = _format_tool_detail(tool_name, args)
            parts.append(f"[tool_use: {tool_name}{detail}]")

        elif btype == "thinking":
            # Internal reasoning — skip in rendered output.
            pass

    return parts


def _format_tool_detail(tool_name: str, args: dict) -> str:  # noqa: ARG001
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


def _extract_tool_result_preview(content) -> str:
    if isinstance(content, str):
        return content[:100].replace("\n", " ")
    elif isinstance(content, list):
        for block in content:
            if isinstance(block, dict) and block.get("type") == "text":
                return block.get("text", "")[:100].replace("\n", " ")
    return ""


# --- Location / lookup ---

def sessions_dir() -> str:
    """Pi sessions root. Honours $PI_DIR for tests; defaults to ~/.pi."""
    pi_dir = os.environ.get("PI_DIR", os.path.expanduser("~/.pi"))
    return os.path.join(pi_dir, "agent", "sessions")


def find_session(query: str) -> str:
    """Find a pi session JSONL by UUID prefix or session name.

    Prints errors to stderr and calls sys.exit(1) on no-match or ambiguous
    match — matching the legacy `parse.find_session` contract.
    """
    root = sessions_dir()
    if not os.path.isdir(root):
        print(f"Error: No sessions directory at {root}", file=sys.stderr)
        sys.exit(1)

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

            uuid_part = (
                fname.rsplit("_", 1)[-1].replace(".jsonl", "")
                if "_" in fname
                else fname.replace(".jsonl", "")
            )
            if uuid_part.startswith(query) or fname.startswith(query):
                id_matches.append(filepath)
                continue

            try:
                with open(filepath) as f:
                    first_line = f.readline().strip()
                    if first_line:
                        header = json.loads(first_line)
                        hname = header.get("name", "")
                        if hname and hname == query:
                            name_matches.append(filepath)
            except (json.JSONDecodeError, OSError):
                continue

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
