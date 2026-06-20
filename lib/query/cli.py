from __future__ import annotations

import argparse
import sys
from pathlib import Path

from .browser import open_html, render_html, write_html_file
from .db import build_db
from .help import schema_text
from .query import rows_for_query
from .render import render
from .util import resolve_path


def resolve_sql_file(value: str) -> Path:
    requested = Path(value).expanduser()
    path = resolve_path(requested)
    if path.exists() or requested.is_absolute():
        return path
    package_path = Path(__file__).resolve().parents[2] / requested
    if package_path.exists():
        return package_path
    return path


def read_sql(args: argparse.Namespace) -> str | None:
    if args.sql_file:
        return resolve_sql_file(args.sql_file).read_text()
    return args.sql


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Query local sessions through an ephemeral SQLite projection")
    parser.add_argument("session_ids", nargs="*", help="Optional session ID prefixes to query")
    parser.add_argument("--project", default="", help="Project substring filter when querying a corpus")
    parser.add_argument("--limit", type=int, default=20, help="Max sessions for corpus scope")
    parser.add_argument("--text", choices=["none", "commands", "compact", "full"], default="commands", help="Text columns to insert into the ephemeral DB")
    parser.add_argument("--max-output-chars", type=int, default=4000, help="Output excerpt budget for --text compact")
    parser.add_argument("--max-message-chars", type=int, default=2000, help="Message excerpt budget for --text compact")
    parser.add_argument("--sql", default="", help="SQL SELECT/WITH/PRAGMA query")
    parser.add_argument("--sql-file", default="", help="File containing SQL query")
    parser.add_argument("--format", choices=["table", "grid", "html", "tsv", "csv", "json", "jsonl"], default="table", help="Output format")
    parser.add_argument("--max-col-width", type=int, default=80, help="Max display width per column for --format grid")
    parser.add_argument("--max-cell-lines", type=int, default=12, help="Max wrapped lines per cell for --format grid; 0 means unlimited")
    parser.add_argument("--color", choices=["auto", "always", "never"], default="auto", help="Color mode for grid separators; auto dims separators on a TTY")
    parser.add_argument("--browser", action="store_true", help="Render results to temporary HTML and open in the default browser")
    parser.add_argument("--title", default="sessions query", help="HTML/browser result title")
    parser.add_argument("--out", default="", help="Write query output to a file")
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    sql = read_sql(args)
    if not sql:
        print(schema_text())
        return 0
    conn = build_db(args)
    names, rows = rows_for_query(conn, sql)
    output = resolve_path(args.out) if args.out else None
    if args.browser:
        html_path = write_html_file(names, rows, title=args.title, output=output)
        open_html(html_path)
        print(html_path)
        return 0
    if args.format == "html":
        if output:
            write_html_file(names, rows, title=args.title, output=output)
        else:
            render_html(names, rows, sys.stdout, title=args.title)
        return 0
    render(
        names,
        rows,
        fmt=args.format,
        output=output,
        max_col_width=args.max_col_width,
        max_cell_lines=args.max_cell_lines,
        color=args.color,
    )
    return 0
