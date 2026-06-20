from __future__ import annotations

import csv
import io
import json
import sqlite3
import sys
from pathlib import Path
from typing import Any


def render_tsv(names: list[str], rows: list[sqlite3.Row], out: io.TextIOBase) -> None:
    writer = csv.writer(out, delimiter="\t", lineterminator="\n")
    writer.writerow(names)
    for row in rows:
        writer.writerow([row[name] for name in names])


def render_csv(names: list[str], rows: list[sqlite3.Row], out: io.TextIOBase) -> None:
    writer = csv.writer(out, lineterminator="\n")
    writer.writerow(names)
    for row in rows:
        writer.writerow([row[name] for name in names])


def render_json(names: list[str], rows: list[sqlite3.Row], out: io.TextIOBase) -> None:
    json.dump([{name: row[name] for name in names} for row in rows], out, indent=2)
    out.write("\n")


def render_jsonl(names: list[str], rows: list[sqlite3.Row], out: io.TextIOBase) -> None:
    for row in rows:
        out.write(json.dumps({name: row[name] for name in names}, sort_keys=True) + "\n")


def render_table(names: list[str], rows: list[sqlite3.Row], out: io.TextIOBase) -> None:
    values = [["" if row[name] is None else str(row[name]) for name in names] for row in rows]
    widths = [len(name) for name in names]
    for row in values:
        for idx, value in enumerate(row):
            widths[idx] = min(80, max(widths[idx], len(value)))

    def trim(value: str, width: int) -> str:
        return value if len(value) <= width else value[: max(0, width - 1)] + "…"

    out.write("  ".join(name.ljust(widths[idx]) for idx, name in enumerate(names)) + "\n")
    out.write("  ".join("-" * width for width in widths) + "\n")
    for row in values:
        out.write("  ".join(trim(value, widths[idx]).ljust(widths[idx]) for idx, value in enumerate(row)) + "\n")


def wrap_grid_cell(value: Any, *, width: int, max_lines: int) -> list[str]:
    text = "" if value is None else str(value)
    raw_lines = text.splitlines() or [""]
    wrapped: list[str] = []
    for line in raw_lines:
        if not line:
            wrapped.append("")
            continue
        remaining = line
        while len(remaining) > width:
            wrapped.append(remaining[:width])
            remaining = remaining[width:]
        wrapped.append(remaining)
    if max_lines > 0 and len(wrapped) > max_lines:
        omitted = len(wrapped) - max_lines + 1
        wrapped = wrapped[: max_lines - 1] + [f"… ({omitted} lines omitted)"]
    return wrapped


def render_grid(
    names: list[str],
    rows: list[sqlite3.Row],
    out: io.TextIOBase,
    *,
    max_col_width: int,
    max_cell_lines: int,
    color: str,
) -> None:
    raw_values = [["" if row[name] is None else str(row[name]) for name in names] for row in rows]
    widths = [min(max_col_width, len(name)) for name in names]
    for row in raw_values:
        for idx, value in enumerate(row):
            line_width = max((len(line) for line in value.splitlines()), default=0)
            widths[idx] = min(max_col_width, max(widths[idx], line_width))

    use_dim = color == "always" or (color == "auto" and out.isatty())

    def sep(text: str) -> str:
        if not use_dim:
            return text
        return f"\033[2m{text}\033[0m"

    def border(left: str, middle: str, right: str) -> str:
        line = left + middle.join("─" * (width + 2) for width in widths) + right
        return sep(line) + "\n"

    def render_row(cells: list[Any], *, header: bool = False) -> None:
        wrapped_cells = [
            wrap_grid_cell(cell, width=widths[idx], max_lines=max_cell_lines)
            for idx, cell in enumerate(cells)
        ]
        row_height = max(len(cell_lines) for cell_lines in wrapped_cells) if wrapped_cells else 1
        for line_idx in range(row_height):
            parts = []
            for col_idx, cell_lines in enumerate(wrapped_cells):
                text = cell_lines[line_idx] if line_idx < len(cell_lines) else ""
                parts.append(" " + text.ljust(widths[col_idx]) + " ")
            out.write(sep("│") + sep("│").join(parts) + sep("│") + "\n")
        if header:
            out.write(border("├", "┼", "┤"))

    out.write(border("┌", "┬", "┐"))
    render_row(names, header=True)
    for idx, row in enumerate(raw_values):
        render_row(row)
        if idx != len(raw_values) - 1:
            out.write(border("├", "┼", "┤"))
    out.write(border("└", "┴", "┘"))


def render(
    names: list[str],
    rows: list[sqlite3.Row],
    *,
    fmt: str,
    output: Path | None,
    max_col_width: int,
    max_cell_lines: int,
    color: str,
) -> None:
    out: io.TextIOBase
    should_close = False
    if output:
        output.parent.mkdir(parents=True, exist_ok=True)
        out = output.open("w")
        should_close = True
    else:
        out = sys.stdout
    try:
        if fmt == "tsv":
            render_tsv(names, rows, out)
        elif fmt == "csv":
            render_csv(names, rows, out)
        elif fmt == "json":
            render_json(names, rows, out)
        elif fmt == "jsonl":
            render_jsonl(names, rows, out)
        elif fmt == "grid":
            render_grid(
                names,
                rows,
                out,
                max_col_width=max_col_width,
                max_cell_lines=max_cell_lines,
                color=color,
            )
        else:
            render_table(names, rows, out)
    finally:
        if should_close:
            out.close()
