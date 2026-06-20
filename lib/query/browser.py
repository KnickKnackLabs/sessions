from __future__ import annotations

import html
import sqlite3
import tempfile
import webbrowser
from pathlib import Path
from typing import TextIO


def _value(value: object) -> str:
    return "" if value is None else str(value)


def _summary(text: str, limit: int = 96) -> str:
    one_line = " ".join(text.split())
    if len(one_line) <= limit:
        return one_line or "—"
    return one_line[: limit - 1] + "…"


def _cell_html(value: object) -> str:
    text = _value(value)
    escaped = html.escape(text)
    if "\n" in text or len(text) > 140:
        summary = html.escape(_summary(text))
        return f"<details><summary>{summary}</summary><pre>{escaped}</pre></details>"
    return escaped


def render_html(
    names: list[str], rows: list[sqlite3.Row], out: TextIO, *, title: str
) -> None:
    safe_title = html.escape(title)
    out.write(
        "<!doctype html>\n"
        "<meta charset='utf-8'>\n"
        f"<title>{safe_title}</title>\n"
        "<style>\n"
        ":root { color-scheme: light dark; --border: #6666; --muted: #888; }\n"
        "body { font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; margin: 1rem; }\n"
        "h1 { font-size: 1.1rem; margin: 0 0 .75rem; }\n"
        ".controls { position: sticky; top: 0; z-index: 3; padding: .5rem 0; background: Canvas; }\n"
        "input { font: inherit; width: min(60rem, 95vw); padding: .35rem .5rem; }\n"
        ".meta { color: var(--muted); margin: .4rem 0 .8rem; }\n"
        ".wrap { overflow: auto; max-height: 82vh; border: 1px solid var(--border); }\n"
        "table { border-collapse: collapse; width: max-content; min-width: 100%; }\n"
        "th, td { border: 1px solid var(--border); padding: .3rem .45rem; vertical-align: top; max-width: 44rem; }\n"
        "th { position: sticky; top: 0; z-index: 2; background: Canvas; text-align: left; }\n"
        "tr:nth-child(even) td { background: color-mix(in srgb, CanvasText 4%, Canvas); }\n"
        "pre { white-space: pre-wrap; margin: .35rem 0 0; }\n"
        "summary { cursor: pointer; color: LinkText; }\n"
        ".num { text-align: right; }\n"
        "</style>\n"
        "<div class='controls'>\n"
        f"<h1>{safe_title}</h1>\n"
        "<input id='filter' placeholder='filter rows…' autofocus>\n"
        f"<div class='meta'><span id='shown'>{len(rows)}</span> / {len(rows)} rows</div>\n"
        "</div>\n"
        "<div class='wrap'>\n<table id='results'>\n<thead><tr>"
    )
    for name in names:
        out.write(f"<th>{html.escape(name)}</th>")
    out.write("</tr></thead>\n<tbody>\n")
    for row in rows:
        out.write("<tr>")
        for name in names:
            value = row[name]
            cls = " class='num'" if isinstance(value, (int, float)) else ""
            out.write(f"<td{cls}>{_cell_html(value)}</td>")
        out.write("</tr>\n")
    out.write(
        "</tbody>\n</table>\n</div>\n"
        "<script>\n"
        "const filter = document.getElementById('filter');\n"
        "const shown = document.getElementById('shown');\n"
        "const rows = Array.from(document.querySelectorAll('#results tbody tr'));\n"
        "filter.addEventListener('input', () => {\n"
        "  const q = filter.value.toLowerCase();\n"
        "  let n = 0;\n"
        "  for (const row of rows) {\n"
        "    const ok = row.innerText.toLowerCase().includes(q);\n"
        "    row.style.display = ok ? '' : 'none';\n"
        "    if (ok) n++;\n"
        "  }\n"
        "  shown.textContent = n;\n"
        "});\n"
        "</script>\n"
    )


def write_html_file(
    names: list[str], rows: list[sqlite3.Row], *, title: str, output: Path | None = None
) -> Path:
    if output is None:
        handle = tempfile.NamedTemporaryFile(
            prefix="sessions-query-", suffix=".html", delete=False, mode="w"
        )
        path = Path(handle.name)
        with handle:
            render_html(names, rows, handle, title=title)
        return path
    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open("w") as f:
        render_html(names, rows, f, title=title)
    return output


def open_html(path: Path) -> bool:
    return webbrowser.open(path.resolve().as_uri())
