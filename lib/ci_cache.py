"""GitHub Actions cache inventory and bounded invalidation for Sessions."""

from __future__ import annotations

import json
import os
import subprocess
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any
from urllib.parse import urlparse

CACHE_KEY_PREFIX = "mise-v1-"


class CacheError(RuntimeError):
    """A cache operation could not be completed safely."""


@dataclass(frozen=True)
class RepoScope:
    name: str
    host: str


@dataclass(frozen=True)
class Cache:
    id: int
    key: str
    ref: str
    created_at: str
    last_accessed_at: str
    size_in_bytes: int


def _run(command: list[str], *, cwd: Path, unset_env: tuple[str, ...] = ()) -> str:
    environment = os.environ.copy()
    for variable in unset_env:
        environment.pop(variable, None)
    result = subprocess.run(
        command,
        cwd=cwd,
        env=environment,
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        detail = result.stderr.strip() or result.stdout.strip() or "no error detail"
        raise CacheError(f"command failed ({result.returncode}): {detail}")
    return result.stdout


def _gh() -> str:
    return os.environ.get("SESSIONS_GH", "gh")


def repository(root: Path) -> RepoScope:
    output = _run(
        [_gh(), "repo", "view", "--json", "nameWithOwner,url"],
        cwd=root,
        unset_env=("GH_REPO", "GH_HOST"),
    )
    try:
        metadata = json.loads(output)
        name = metadata["nameWithOwner"]
        url = metadata["url"]
    except (json.JSONDecodeError, KeyError, TypeError) as error:
        raise CacheError("GitHub CLI returned invalid repository metadata") from error
    if not isinstance(name, str) or name.count("/") != 1 or not all(name.split("/")):
        raise CacheError("GitHub CLI returned an invalid repository name")
    if not isinstance(url, str):
        raise CacheError("GitHub CLI returned an invalid repository URL")
    parsed = urlparse(url)
    if (
        parsed.scheme != "https"
        or parsed.hostname is None
        or parsed.username is not None
    ):
        raise CacheError("GitHub CLI returned an invalid repository URL")
    return RepoScope(name=name, host=parsed.hostname)


def current_ref(root: Path) -> str:
    branch = _run(["git", "branch", "--show-current"], cwd=root).strip()
    if not branch:
        raise CacheError(
            "current checkout is detached; run this task from a Sessions source branch"
        )
    return f"refs/heads/{branch}"


def _cache_from_json(value: Any) -> Cache:
    if not isinstance(value, dict):
        raise CacheError("GitHub CLI returned invalid cache metadata")
    try:
        cache_id = value["id"]
        key = value["key"]
        ref = value["ref"]
        created_at = value["created_at"]
        last_accessed_at = value["last_accessed_at"]
        size_in_bytes = value["size_in_bytes"]
    except KeyError as error:
        raise CacheError("GitHub CLI returned invalid cache metadata") from error
    if (
        type(cache_id) is not int
        or cache_id <= 0
        or not isinstance(key, str)
        or not isinstance(ref, str)
        or not isinstance(created_at, str)
        or not isinstance(last_accessed_at, str)
        or type(size_in_bytes) is not int
        or size_in_bytes < 0
    ):
        raise CacheError("GitHub CLI returned invalid cache metadata")
    return Cache(
        id=cache_id,
        key=key,
        ref=ref,
        created_at=created_at,
        last_accessed_at=last_accessed_at,
        size_in_bytes=size_in_bytes,
    )


def list_caches(root: Path, scope: RepoScope, ref: str) -> list[Cache]:
    output = _run(
        [
            _gh(),
            "api",
            "--hostname",
            scope.host,
            "--method",
            "GET",
            f"repos/{scope.name}/actions/caches",
            "-f",
            f"ref={ref}",
            "-F",
            "per_page=100",
            "--paginate",
            "--slurp",
        ],
        cwd=root,
    )
    try:
        pages = json.loads(output)
    except json.JSONDecodeError as error:
        raise CacheError("GitHub CLI returned invalid cache JSON") from error
    if not isinstance(pages, list):
        raise CacheError("GitHub CLI returned invalid paginated cache JSON")

    caches: list[Cache] = []
    for page in pages:
        if not isinstance(page, dict) or not isinstance(
            page.get("actions_caches"), list
        ):
            raise CacheError("GitHub CLI returned invalid paginated cache JSON")
        caches.extend(_cache_from_json(value) for value in page["actions_caches"])

    return sorted(
        (
            cache
            for cache in caches
            if cache.ref == ref and cache.key.startswith(CACHE_KEY_PREFIX)
        ),
        key=lambda cache: (cache.created_at, cache.id),
        reverse=True,
    )


def _parse_timestamp(value: str) -> datetime:
    normalized = value[:-1] + "+00:00" if value.endswith("Z") else value
    try:
        parsed = datetime.fromisoformat(normalized)
    except ValueError as error:
        raise CacheError(
            f"GitHub CLI returned invalid cache timestamp: {value}"
        ) from error
    if parsed.tzinfo is None:
        raise CacheError(f"GitHub CLI returned timezone-free cache timestamp: {value}")
    return parsed.astimezone(timezone.utc)


def _age(created_at: str, *, now: datetime | None = None) -> str:
    current = now or datetime.now(timezone.utc)
    seconds = max(0, int((current - _parse_timestamp(created_at)).total_seconds()))
    if seconds < 60:
        return f"{seconds}s"
    if seconds < 3600:
        return f"{seconds // 60}m"
    if seconds < 86400:
        return f"{seconds // 3600}h"
    return f"{seconds // 86400}d"


def _size(size_in_bytes: int) -> str:
    return f"{size_in_bytes} bytes ({size_in_bytes / 1024 / 1024:.1f} MiB)"


def describe(cache: Cache) -> str:
    return "\n".join(
        [
            f"ID: {cache.id}",
            f"Key: {cache.key}",
            f"Ref: {cache.ref}",
            f"Created: {cache.created_at} (age {_age(cache.created_at)})",
            f"Last accessed: {cache.last_accessed_at}",
            f"Size: {_size(cache.size_in_bytes)}",
        ]
    )


def show_status(root: Path) -> None:
    scope = repository(root)
    ref = current_ref(root)
    caches = list_caches(root, scope, ref)

    print(f"Repository: {scope.name}")
    print(f"GitHub host: {scope.host}")
    print(f"Cache family: {CACHE_KEY_PREFIX}")
    print(f"Ref: {ref}")
    print(f"Caches: {len(caches)}")
    for cache in caches:
        print()
        print(describe(cache))


def _validate_ids(cache_ids: list[str]) -> list[int]:
    parsed: list[int] = []
    for value in cache_ids:
        if not value.isascii() or not value.isdigit() or int(value) <= 0:
            raise CacheError(f"invalid cache ID: {value}")
        cache_id = int(value)
        if cache_id in parsed:
            raise CacheError(f"duplicate cache ID: {cache_id}")
        parsed.append(cache_id)
    if not parsed:
        raise CacheError("at least one explicit cache ID is required")
    return parsed


def invalidate(root: Path, cache_ids: list[str], *, confirmed: bool) -> None:
    requested = _validate_ids(cache_ids)
    scope = repository(root)
    ref = current_ref(root)
    scoped = {cache.id: cache for cache in list_caches(root, scope, ref)}

    outside = [cache_id for cache_id in requested if cache_id not in scoped]
    if outside:
        joined = ", ".join(str(cache_id) for cache_id in outside)
        raise CacheError(
            f"cache ID(s) not found in {scope.name} family {CACHE_KEY_PREFIX} on {ref}: {joined}"
        )

    print(f"Repository: {scope.name}")
    print(f"GitHub host: {scope.host}")
    print(f"Cache family: {CACHE_KEY_PREFIX}")
    print(f"Ref: {ref}")
    print(f"Selected caches: {len(requested)}")
    for cache_id in requested:
        print()
        print(describe(scoped[cache_id]))

    if not confirmed:
        print()
        print("Dry run only. Rerun with --yes to delete these exact cache IDs.")
        return

    failures: list[str] = []
    for cache_id in requested:
        try:
            _run(
                [
                    _gh(),
                    "api",
                    "--hostname",
                    scope.host,
                    "--method",
                    "DELETE",
                    f"repos/{scope.name}/actions/caches/{cache_id}",
                    "--silent",
                ],
                cwd=root,
            )
            print(f"Deleted cache ID {cache_id}")
        except CacheError as error:
            failure = f"cache ID {cache_id}: {error}"
            failures.append(failure)
            print(f"Failed to delete {failure}")

    try:
        remaining = {cache.id for cache in list_caches(root, scope, ref)}
    except CacheError as error:
        failures.append(f"verification failed: {error}")
    else:
        not_absent = [cache_id for cache_id in requested if cache_id in remaining]
        for cache_id in requested:
            if cache_id not in remaining:
                print(f"Verified absent: cache ID {cache_id}")

        if not_absent:
            joined = ", ".join(str(cache_id) for cache_id in not_absent)
            failures.append(f"cache ID(s) still present after invalidation: {joined}")
    if failures:
        raise CacheError("; ".join(failures))
