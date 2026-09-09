#!/usr/bin/env bats

load helpers

setup() {
  CACHE_TMP="$BATS_TEST_TMPDIR/cache-test"
  mkdir -p "$CACHE_TMP/bin"
  export GH_CACHE_STATE="$CACHE_TMP/deleted"
  export GH_CACHE_LOG="$CACHE_TMP/calls.jsonl"
  export GH_CACHE_GET_COUNT="$CACHE_TMP/get-count"
  export SESSIONS_GH="$CACHE_TMP/bin/gh"
  : > "$GH_CACHE_STATE"
  : > "$GH_CACHE_LOG"
  printf '0\n' > "$GH_CACHE_GET_COUNT"

  cat > "$SESSIONS_GH" <<'PY'
#!/usr/bin/env python3
import json
import os
import sys

args = sys.argv[1:]
with open(os.environ["GH_CACHE_LOG"], "a", encoding="utf-8") as log:
    print(json.dumps(args), file=log)

if args[:2] == ["repo", "view"]:
    expected = ["repo", "view", "--json", "nameWithOwner,url"]
    if args != expected:
        print(f"unexpected repo arguments: {args}", file=sys.stderr)
        raise SystemExit(64)
    if "GH_REPO" in os.environ or "GH_HOST" in os.environ:
        print("ambient GitHub repository scope leaked into discovery", file=sys.stderr)
        raise SystemExit(65)
    print(
        json.dumps(
            {
                "nameWithOwner": "KnickKnackLabs/sessions",
                "url": "https://github.com/KnickKnackLabs/sessions",
            }
        )
    )
    raise SystemExit(0)

if not args or args[0] != "api":
    print(f"unexpected gh arguments: {args}", file=sys.stderr)
    raise SystemExit(64)

method = args[args.index("--method") + 1]
endpoint = next((arg for arg in args if arg.startswith("repos/")), "")

if method == "GET":
    expected = [
        "api",
        "--hostname",
        "github.com",
        "--method",
        "GET",
        "repos/KnickKnackLabs/sessions/actions/caches",
        "-f",
        "ref=refs/heads/main",
        "-F",
        "per_page=100",
        "--paginate",
        "--slurp",
    ]
    if args != expected:
        print(f"unexpected cache inventory arguments: {args}", file=sys.stderr)
        raise SystemExit(64)
    with open(os.environ["GH_CACHE_GET_COUNT"], encoding="utf-8") as count_file:
        get_count = int(count_file.read()) + 1
    with open(os.environ["GH_CACHE_GET_COUNT"], "w", encoding="utf-8") as count_file:
        print(get_count, file=count_file)
    if os.environ.get("GH_CACHE_LIST_FAIL") == "true" or os.environ.get(
        "GH_CACHE_LIST_FAIL_ON"
    ) == str(get_count):
        print("injected cache list failure", file=sys.stderr)
        raise SystemExit(42)
    with open(os.environ["GH_CACHE_STATE"], encoding="utf-8") as state:
        deleted = {int(line) for line in state if line.strip()}
    pages = [
        [
            {
                "id": 101,
                "key": "mise-v1-linux-x64-config-4140",
                "ref": "refs/heads/main",
                "created_at": "2026-09-04T16:00:00Z",
                "last_accessed_at": "2026-09-04T17:00:00Z",
                "size_in_bytes": 287621989,
            },
            {
                "id": 303,
                "key": "unrelated-cache",
                "ref": "refs/heads/main",
                "created_at": "2026-09-04T16:10:00Z",
                "last_accessed_at": "2026-09-04T17:10:00Z",
                "size_in_bytes": 10,
            },
            {
                "id": 404,
                "key": "mise-v1-linux-x64-config-4140",
                "ref": "refs/heads/other",
                "created_at": "2026-09-04T16:15:00Z",
                "last_accessed_at": "2026-09-04T17:15:00Z",
                "size_in_bytes": 20,
            },
        ],
        [
            {
                "id": 202,
                "key": "mise-v1-macos-arm64-config-4140",
                "ref": "refs/heads/main",
                "created_at": "2026-09-04T16:05:00Z",
                "last_accessed_at": "2026-09-04T17:05:00Z",
                "size_in_bytes": 243178718,
            }
        ],
    ]
    visible_pages = [
        [cache for cache in page if cache["id"] not in deleted] for page in pages
    ]
    print(
        json.dumps(
            [
                {"total_count": len(page), "actions_caches": page}
                for page in visible_pages
            ]
        )
    )
    raise SystemExit(0)

if method == "DELETE":
    cache_id = int(endpoint.rsplit("/", 1)[-1])
    expected = [
        "api",
        "--hostname",
        "github.com",
        "--method",
        "DELETE",
        f"repos/KnickKnackLabs/sessions/actions/caches/{cache_id}",
        "--silent",
    ]
    if args != expected:
        print(f"unexpected cache deletion arguments: {args}", file=sys.stderr)
        raise SystemExit(64)
    if os.environ.get("GH_CACHE_DELETE_FAIL_ID") == str(cache_id):
        print("injected cache deletion failure", file=sys.stderr)
        raise SystemExit(43)
    with open(os.environ["GH_CACHE_STATE"], "a", encoding="utf-8") as state:
        print(cache_id, file=state)
    raise SystemExit(0)

print(f"unexpected gh method: {method}", file=sys.stderr)
raise SystemExit(64)
PY
  chmod +x "$SESSIONS_GH"
}

@test "ci:cache:status shows exact caches in the current mise family and ref" {
  run sessions ci:cache:status

  [ "$status" -eq 0 ]
  [[ "$output" == *"Repository: KnickKnackLabs/sessions"* ]]
  [[ "$output" == *"Cache family: mise-v1-"* ]]
  [[ "$output" == *"Ref: refs/heads/main"* ]]
  [[ "$output" == *"Caches: 2"* ]]
  [[ "$output" == *"ID: 101"* ]]
  [[ "$output" == *"Key: mise-v1-linux-x64-config-4140"* ]]
  [[ "$output" == *"Size: 287621989 bytes"* ]]
  [[ "$output" == *"Created: 2026-09-04T16:00:00Z (age "* ]]
  [[ "$output" == *"ID: 202"* ]]
  [[ "$output" != *"ID: 303"* ]]
  [[ "$output" != *"ID: 404"* ]]
}

@test "ci:cache:status ignores ambient repository and host overrides" {
  export GH_REPO="someone-else/wrong-repository"
  export GH_HOST="wrong.example"

  run sessions ci:cache:status

  [ "$status" -eq 0 ]
  [[ "$output" == *"Repository: KnickKnackLabs/sessions"* ]]
  [[ "$output" == *"GitHub host: github.com"* ]]
  [[ "$output" == *"Caches: 2"* ]]
}

@test "ci:cache:status propagates GitHub cache inventory failures" {
  export GH_CACHE_LIST_FAIL=true

  run sessions ci:cache:status

  [ "$status" -eq 1 ]
  [[ "$output" == *"injected cache list failure"* ]]
}

@test "ci:cache:invalidate previews exact IDs without deleting" {
  run sessions ci:cache:invalidate 101 202

  [ "$status" -eq 0 ]
  [[ "$output" == *"Selected caches: 2"* ]]
  [[ "$output" == *"Dry run only"* ]]
  [ ! -s "$GH_CACHE_STATE" ]
  ! grep -q 'DELETE' "$GH_CACHE_LOG"
}

@test "ci:cache:invalidate rejects IDs outside the current family and ref" {
  run sessions ci:cache:invalidate 303 --yes

  [ "$status" -eq 1 ]
  [[ "$output" == *"not found in KnickKnackLabs/sessions family mise-v1- on refs/heads/main: 303"* ]]
  [ ! -s "$GH_CACHE_STATE" ]
}

@test "ci:cache:invalidate validates every ID before deleting any" {
  run sessions ci:cache:invalidate 101 404 --yes

  [ "$status" -eq 1 ]
  [[ "$output" == *"refs/heads/main: 404"* ]]
  [ ! -s "$GH_CACHE_STATE" ]
  ! grep -q 'DELETE' "$GH_CACHE_LOG"
}

@test "ci:cache:invalidate rejects duplicate and malformed IDs" {
  run sessions ci:cache:invalidate 101 101 --yes
  [ "$status" -eq 1 ]
  [[ "$output" == *"duplicate cache ID: 101"* ]]
  [ ! -s "$GH_CACHE_STATE" ]

  run sessions ci:cache:invalidate nope --yes
  [ "$status" -eq 1 ]
  [[ "$output" == *"invalid cache ID: nope"* ]]
  [ ! -s "$GH_CACHE_STATE" ]
}

@test "ci:cache:invalidate deletes only explicit IDs and verifies absence" {
  run sessions ci:cache:invalidate 101 --yes

  [ "$status" -eq 0 ]
  [[ "$output" == *"Deleted cache ID 101"* ]]
  [[ "$output" == *"Verified absent: cache ID 101"* ]]
  [ "$(cat "$GH_CACHE_STATE")" = "101" ]
  ! grep -q 'actions/caches/202' "$GH_CACHE_LOG"
}

@test "ci:cache:invalidate reports deletion failures after absence checks" {
  export GH_CACHE_DELETE_FAIL_ID=202

  run sessions ci:cache:invalidate 101 202 --yes

  [ "$status" -eq 1 ]
  [[ "$output" == *"Deleted cache ID 101"* ]]
  [[ "$output" == *"Verified absent: cache ID 101"* ]]
  [[ "$output" == *"cache ID 202: command failed (43): injected cache deletion failure"* ]]
  [[ "$output" == *"cache ID(s) still present after invalidation: 202"* ]]
  [ "$(cat "$GH_CACHE_STATE")" = "101" ]
}

@test "ci:cache:invalidate preserves deletion failures when verification fails" {
  export GH_CACHE_DELETE_FAIL_ID=202
  export GH_CACHE_LIST_FAIL_ON=2

  run sessions ci:cache:invalidate 101 202 --yes

  [ "$status" -eq 1 ]
  [[ "$output" == *"Deleted cache ID 101"* ]]
  [[ "$output" == *"cache ID 202: command failed (43): injected cache deletion failure"* ]]
  [[ "$output" == *"verification failed: command failed (42): injected cache list failure"* ]]
  [[ "$output" != *"Verified absent"* ]]
  [ "$(cat "$GH_CACHE_STATE")" = "101" ]
}

@test "ci:cache:invalidate has no broad all-caches mode" {
  run sessions ci:cache:invalidate 101 --all

  [ "$status" -ne 0 ]
  [ ! -s "$GH_CACHE_STATE" ]
  ! grep -q 'DELETE' "$GH_CACHE_LOG"
}
