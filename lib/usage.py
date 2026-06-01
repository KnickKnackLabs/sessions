"""Shared helpers for aggregating normalized session usage records."""

TOKEN_KEYS = ("input", "output", "cacheRead", "cacheWrite", "totalTokens")
COST_KEYS = ("input", "output", "cacheRead", "cacheWrite", "total")


def empty_totals() -> dict:
    return {
        "calls": 0,
        "input": 0,
        "output": 0,
        "cacheRead": 0,
        "cacheWrite": 0,
        "totalTokens": 0,
        "cost": {k: 0.0 for k in COST_KEYS},
    }


def add_record(totals: dict, record: dict) -> None:
    totals["calls"] += 1
    for key in TOKEN_KEYS:
        totals[key] += int(record.get(key) or 0)
    cost = record.get("cost") or {}
    for key in COST_KEYS:
        totals["cost"][key] += float(cost.get(key) or 0.0)


def aggregate(records: list) -> dict:
    totals = empty_totals()
    for record in records:
        add_record(totals, record)
    return totals


def aggregate_by_model(records: list) -> dict:
    groups = {}
    for record in records:
        model = record.get("model") or "unknown"
        provider = record.get("provider") or ""
        key = f"{provider}/{model}" if provider else model
        if key not in groups:
            groups[key] = empty_totals()
            groups[key]["model"] = model
            groups[key]["provider"] = provider
        add_record(groups[key], record)
    return groups


def filter_records_by_date(records: list, after: str = "", before: str = "") -> list:
    filtered = []
    for record in records:
        day = (record.get("timestamp") or "")[:10]
        if after and day < after:
            continue
        if before and day > before:
            continue
        filtered.append(record)
    return filtered


def format_tokens(value: int) -> str:
    return f"{int(value):,}"


def format_cost(value: float) -> str:
    return f"${value:,.4f}" if abs(value) < 100 else f"${value:,.2f}"


def avg(value, calls: int):
    return value / calls if calls else 0
