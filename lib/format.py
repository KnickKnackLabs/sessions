"""
Shared Rich formatting helpers for sessions CLI output.

Provides a shared Console instance and formatting functions used across
all session commands (list, read, inspect, search) for consistent styling.

Usage:
    from format import console, format_date, format_time, format_id, format_model
"""

from datetime import datetime, timezone

from rich.console import Console
from rich.table import Table
from rich.text import Text

console = Console()

# Style constants — single source of truth for the visual vocabulary
STYLE_ID = "cyan"
STYLE_ROLE_USER = "green"
STYLE_ROLE_ASSISTANT = "blue"
STYLE_DIM = "dim"
STYLE_MATCH = "bold yellow"
STYLE_TOOL = "dim italic"


def format_date(iso_timestamp: str) -> str:
    """Convert ISO timestamp to 'Mar 25 · 14:32 · (2h ago)' format."""
    if not iso_timestamp or len(iso_timestamp) < 10:
        return "?"
    try:
        dt = datetime.strptime(iso_timestamp[:19], "%Y-%m-%dT%H:%M:%S")
        date_part = dt.strftime("%b %d")
        time_part = dt.strftime("%H:%M")
        relative = _relative_time(dt)
        return f"{date_part} · {time_part} · ({relative})"
    except ValueError:
        try:
            dt = datetime.strptime(iso_timestamp[:10], "%Y-%m-%d")
            relative = _relative_time(dt)
            return f"{dt.strftime('%b %d')} · ({relative})"
        except ValueError:
            return iso_timestamp[:10]


def _relative_time(dt: datetime) -> str:
    """Compute a human-friendly relative time string from dt to now.

    Assumes dt is UTC (session timestamps are UTC).
    """
    now = datetime.now(timezone.utc).replace(tzinfo=None)
    delta = now - dt
    seconds = int(delta.total_seconds())
    if seconds < 0:
        return "0s ago"
    if seconds < 60:
        return f"{seconds}s ago"
    minutes = seconds // 60
    if minutes < 60:
        return f"{minutes}m ago"
    hours = minutes // 60
    if hours < 24:
        return f"{hours}h ago"
    days = hours // 24
    if days == 1:
        return "yesterday"
    if days < 30:
        return f"{days}d ago"
    months = days // 30
    return f"{months}mo ago"


def format_relative(iso_timestamp: str) -> str:
    """Convert ISO timestamp to relative time only (e.g. '2m ago', '1h ago')."""
    if not iso_timestamp or len(iso_timestamp) < 10:
        return "?"
    try:
        dt = datetime.strptime(iso_timestamp[:19], "%Y-%m-%dT%H:%M:%S")
        return _relative_time(dt)
    except ValueError:
        return "?"


def format_time(iso_timestamp: str) -> str:
    """Extract HH:MM from an ISO timestamp."""
    if not iso_timestamp or len(iso_timestamp) < 16:
        return ""
    return iso_timestamp[11:16]


def format_id(session_id: str) -> Text:
    """Format a session ID prefix in cyan."""
    return Text(session_id[:8], style=STYLE_ID)


def format_model(model: str) -> str:
    """Format a model name for display. Returns raw string, '?' for unknown."""
    if not model or model == "unknown":
        return "?"
    return model


def format_role(role: str) -> Text:
    """Format a role label with semantic color."""
    if role == "user":
        return Text("user", style=STYLE_ROLE_USER)
    if role == "assistant":
        return Text("assistant", style=STYLE_ROLE_ASSISTANT)
    return Text(role, style=STYLE_DIM)


def format_duration(first_ts: str, last_ts: str) -> str:
    """Compute human-readable duration between two ISO timestamps."""
    if not first_ts or not last_ts:
        return "?"
    try:
        fmt = "%Y-%m-%dT%H:%M:%S"
        t1 = datetime.strptime(first_ts[:19], fmt)
        t2 = datetime.strptime(last_ts[:19], fmt)
        total = int((t2 - t1).total_seconds())
        if total < 0:
            return "?"
        hours, remainder = divmod(total, 3600)
        minutes, _ = divmod(remainder, 60)
        if hours > 0:
            return f"{hours}h {minutes}m"
        return f"{minutes}m"
    except ValueError:
        return "?"


def make_table(**kwargs) -> Table:
    """Create a Table with shared defaults. Pass overrides as kwargs."""
    defaults = dict(
        box=None,
        show_header=True,
        header_style="bold",
        padding=(0, 2),
        expand=False,
    )
    defaults.update(kwargs)
    return Table(**defaults)
