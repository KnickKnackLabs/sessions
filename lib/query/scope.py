from __future__ import annotations

import argparse
import os
from pathlib import Path

import harness
import parse
from usage import aggregate

from .model import ScopeEntry, UsageTotals
from .util import safe_float, safe_int


def entry_from_session(session: parse.Session) -> ScopeEntry:
    meta = session.metadata()
    adapter = harness.resolve(filepath=session.filepath, entries=session.entries)
    return ScopeEntry(
        session_id=str(meta.get("session_id") or ""),
        name=str(meta.get("name") or ""),
        project=str(meta.get("project") or ""),
        slug=str(meta.get("slug") or ""),
        model=str(meta.get("model") or ""),
        first_timestamp=str(meta.get("first_timestamp") or ""),
        last_timestamp=str(meta.get("last_timestamp") or ""),
        total_entries=safe_int(meta.get("total_entries")),
        user_messages=safe_int(meta.get("user_messages")),
        assistant_messages=safe_int(meta.get("assistant_messages")),
        filepath=str(meta.get("filepath") or session.filepath),
        runtime=adapter.__name__.split(".")[-1],
    )


def usage_from_session(session: parse.Session) -> UsageTotals:
    try:
        totals = aggregate(session.usage_records())
    except harness.Unsupported:
        totals = aggregate([])
    cost = totals.get("cost") or {}
    return UsageTotals(
        calls=safe_int(totals.get("calls")),
        input_tokens=safe_int(totals.get("input")),
        output_tokens=safe_int(totals.get("output")),
        cache_read_tokens=safe_int(totals.get("cacheRead")),
        cache_write_tokens=safe_int(totals.get("cacheWrite")),
        total_tokens=safe_int(totals.get("totalTokens")),
        cost_total=safe_float(cost.get("total")),
    )


def session_files(*, project: str, include_agent_prefixed: bool) -> list[Path]:
    files: list[Path] = []
    for harness_name in harness.available():
        adapter = harness.adapter(harness_name)
        try:
            root = adapter.sessions_dir()
        except harness.Unsupported:
            continue
        if not os.path.isdir(root):
            continue
        for project_dir in os.listdir(root):
            project_path = os.path.join(root, project_dir)
            if not os.path.isdir(project_path):
                continue
            for fname in os.listdir(project_path):
                if not fname.endswith(".jsonl"):
                    continue
                if fname.startswith("agent-") and not include_agent_prefixed:
                    continue
                filepath = os.path.join(project_path, fname)
                if project:
                    try:
                        decoded_project = adapter.project(filepath)
                    except harness.Unsupported:
                        decoded_project = project_dir
                    if project not in decoded_project and project not in project_dir:
                        continue
                files.append(Path(filepath))
    files.sort(key=lambda path: -path.stat().st_mtime)
    return files


def include_session(entry: ScopeEntry, *, include_agent_prefixed: bool) -> bool:
    if include_agent_prefixed:
        return True
    message_count = entry.user_messages + entry.assistant_messages
    return message_count > 0 and entry.model != "unknown"


def load_corpus(
    *, project: str, limit: int, include_agent_prefixed: bool
) -> tuple[list[ScopeEntry], dict[str, UsageTotals]]:
    entries: list[ScopeEntry] = []
    usage: dict[str, UsageTotals] = {}
    for path in session_files(
        project=project, include_agent_prefixed=include_agent_prefixed
    ):
        try:
            session = parse.load(str(path))
            entry = entry_from_session(session)
        except Exception:
            continue
        if not include_session(entry, include_agent_prefixed=include_agent_prefixed):
            continue
        entries.append(entry)
        usage[entry.session_id] = usage_from_session(session)
        if limit > 0 and len(entries) >= limit:
            break
    return entries, usage


def load_selected(
    session_ids: list[str],
) -> tuple[list[ScopeEntry], dict[str, UsageTotals]]:
    entries: list[ScopeEntry] = []
    usage: dict[str, UsageTotals] = {}
    for requested in session_ids:
        session = parse.load(parse.find_session(requested))
        entry = entry_from_session(session)
        entries.append(entry)
        usage[entry.session_id] = usage_from_session(session)
    return entries, usage


def scope_entries(
    args: argparse.Namespace,
) -> tuple[list[ScopeEntry], dict[str, UsageTotals]]:
    if args.session_ids:
        return load_selected(args.session_ids)
    return load_corpus(
        project=args.project,
        limit=args.limit,
        include_agent_prefixed=getattr(args, "include_agent_prefixed", False),
    )
