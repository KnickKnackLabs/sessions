"""Shared transcript message filtering helpers.

The parser returns rendered text messages as ``(index, role, timestamp, text)``
tuples. These helpers keep command-level semantics consistent for tool-block
filtering, role filtering, and regex matching.
"""


def is_tool_line(line: str) -> bool:
    """Check if a rendered line is a tool_use or tool_result marker."""
    stripped = line.strip()
    return stripped.startswith("[tool_use:") or stripped.startswith("[tool_result:")


def strip_tool_lines(text: str) -> str:
    """Strip rendered tool lines from message text."""
    lines = text.split("\n")
    lines = [line for line in lines if not is_tool_line(line)]
    return "\n".join(lines).strip()


def split_message(text: str) -> tuple[list[str], list[str]]:
    """Split rendered message text into (content_lines, tool_lines)."""
    content = []
    tools = []
    for line in text.split("\n"):
        if is_tool_line(line):
            tools.append(line.strip())
        else:
            content.append(line)
    return content, tools


def filter_text_messages(
    messages: list,
    *,
    include_tools: bool = False,
    user_only: bool = False,
    assistant_only: bool = False,
    pattern=None,
) -> list:
    """Filter rendered text messages for display/waiting.

    Args:
        messages: Iterable of ``(index, role, timestamp, text)`` tuples.
        include_tools: Keep rendered tool_use/tool_result lines.
        user_only: Keep only user-role messages.
        assistant_only: Keep only assistant-role messages.
        pattern: Optional compiled regex matched against the rendered text.

    Empty messages after filtering are dropped. ``pattern`` is evaluated after
    tool and role filtering, so default matching ignores tool-only content.
    """
    if user_only and assistant_only:
        raise ValueError("--user-only and --assistant-only are mutually exclusive")

    filtered = []
    for idx, role, ts, text in messages:
        if user_only and role != "user":
            continue
        if assistant_only and role != "assistant":
            continue

        rendered = text if include_tools else strip_tool_lines(text)
        if not rendered.strip():
            continue
        if pattern is not None and not pattern.search(rendered):
            continue

        filtered.append((idx, role, ts, rendered))

    return filtered
