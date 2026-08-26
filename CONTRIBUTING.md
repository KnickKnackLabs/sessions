# Contributing

## Harness boundary

`sessions` has a generic core plus per-harness adapters.

Keep these generic in core task/library code:

- session-tool entries that harnesses ignore (`wake`, `harness`, `system_prompt`, `process_start`, `process_exit`);
- task orchestration (`new`, `wake`, `run`, `ps`, `wait`, `usage`, etc.);
- filtering, process-liveness checks, and output formatting that operate on generic entries.

Keep harness-specific knowledge in `lib/harness/<name>.sh` and `lib/harness/<name>.py`:

- exact executable resolution from Sessions' declared tool context;
- session file locations and path encoding;
- native JSONL message schemas;
- launch arguments for a harness binary;
- translation of generic one-run policies such as project trust;
- fallback parsing of harness-owned transcript/event shapes.

A harness must translate a non-default generic policy or reject it explicitly.
It must never silently ignore a policy it cannot honor.

`wake` preflights non-default policy before appending wake or context entries
because it launches `run` only after those mutations.
Low-level `run` delegates policy handling to the selected execution adapter
and records its attempted process plus exit, including an adapter rejection.
Do not duplicate execution-adapter policy in the Bash wrapper merely to suppress
that audit trail.

For example, `sessions run` writes generic `process_start` / `process_exit` records, and `sessions ps` reads those generic records. If a future harness exposes its own process metadata, parse that in the harness adapter and convert it to the generic shape instead of baking the harness schema into `ps`.

## Python mise tasks

Python file tasks that need packages should use the uv/PEP 723 pattern:

```python
#!/usr/bin/env -S uv run --script
# /// script
# dependencies = ["rich"]
# ///
```

Import shared repo libraries with:

```python
import os
import sys
sys.path.insert(0, os.environ["MISE_CONFIG_ROOT"] + "/lib")
```

Do not add a mise-managed `python` tool just because a task uses `uv run --script`; `uv` owns the script interpreter unless the repo has a separate reason to expose Python as a tool.

## Parallel BATS contract

`mise run test` uses Rush to schedule independent `.bats` files with a measured
four-job default. Tests inside each file remain serial because BATS'
within-file semaphore polling is disproportionately slow for short tests.

Use `mise run test --jobs 1` for serial debugging. Parallel suites must isolate
mutable state per file and process through `$BATS_TEST_TMPDIR`, unique process
names, or `mktemp`. Do not add fixed shared files, ports, services, or repository
mutations without either isolating them or deliberately retaining a serial
boundary.

The public `.mise/tasks/test` sets repository policy and forwards arguments to
BATS. BATS owns default-target selection, option parsing, path handling, runner
selection, and validation. `test/test-task.bats` exercises the public Sessions
test path with real BATS behavior.

## Validation

Run targeted tests first, then the full suite before merge:

```sh
mise run test ps run lint
mise run test
readme build --check
git diff --check
```

The BATS suite includes `test/lint.bats`, which runs the configured Codebase lint portfolio through its aggregate public command.
