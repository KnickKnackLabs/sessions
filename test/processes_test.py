#!/usr/bin/env python3
"""Unit tests for the process-roster parser and PID probes."""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "lib"))

import processes  # noqa: E402


class LinuxProcStartTimeTests(unittest.TestCase):
    @staticmethod
    def proc_stat(comm: str, start: str = "12345") -> str:
        rest = "S " + " ".join(str(index) for index in range(1, 19))
        return f"123 ({comm}) {rest} {start} 999"

    def test_parser_handles_parenthesized_process_names(self) -> None:
        self.assertEqual(
            processes._linux_proc_stat_start_time(self.proc_stat("sleep")), "12345"
        )
        self.assertEqual(
            processes._linux_proc_stat_start_time(self.proc_stat("sleep space")),
            "12345",
        )
        self.assertEqual(
            processes._linux_proc_stat_start_time(self.proc_stat("weird) name")),
            "12345",
        )
        self.assertEqual(processes._linux_proc_stat_start_time("bad stat"), "")
        self.assertEqual(
            processes._linux_proc_stat_start_time(self.proc_stat("zero", "0")), ""
        )
        self.assertEqual(
            processes._linux_proc_stat_start_time(self.proc_stat("nondigit", "abc")),
            "",
        )


class ProcessSessionLoadingTests(unittest.TestCase):
    def test_lifecycle_scan_does_not_decode_message_bodies(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / (
                "2026-08-20T00-00-00-000Z_00000000-0000-4000-8000-000000000000.jsonl"
            )
            entries = [
                {
                    "type": "session",
                    "id": "00000000-0000-4000-8000-000000000000",
                    "timestamp": "2026-08-20T00:00:00.000Z",
                },
                {
                    "type": "message",
                    "message": {
                        "role": "assistant",
                        "content": [
                            {
                                "type": "toolCall",
                                "arguments": {"entry": {"type": "process_start"}},
                            }
                        ],
                    },
                },
                {
                    "type": "process_start",
                    "id": "start",
                    "pid": 123,
                    "pid_start_time": "ps:synthetic",
                },
            ]
            path.write_text(
                "\n".join(json.dumps(entry) for entry in entries) + "\n",
                encoding="utf-8",
            )

            original_loads = processes.json.loads

            def guarded_loads(raw: str) -> object:
                if '"type": "message"' in raw:
                    raise AssertionError("message body was decoded")
                return original_loads(raw)

            with patch.object(processes.json, "loads", side_effect=guarded_loads):
                session = processes.load_process_session(str(path))

        self.assertEqual(
            [entry["type"] for entry in session.entries],
            ["session", "process_start"],
        )

    def test_project_filter_applies_before_transcript_open(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            sessions = Path(directory) / "agent" / "sessions"
            for index, name in enumerate(("alpha", "beta"), start=1):
                project = sessions / f"--Users-test-{name}--"
                project.mkdir(parents=True)
                session_id = f"00000000-0000-4000-8000-{index:012d}"
                path = project / f"2026-08-20T00-00-00-000Z_{session_id}.jsonl"
                path.write_text(
                    json.dumps(
                        {
                            "type": "session",
                            "id": session_id,
                            "timestamp": "2026-08-20T00:00:00.000Z",
                        }
                    )
                    + "\n",
                    encoding="utf-8",
                )

            opened: list[str] = []
            original = processes.load_process_session

            def tracked_load(path: str) -> processes.parse.Session:
                opened.append(path)
                return original(path)

            with (
                patch.dict(os.environ, {"PI_DIR": directory}),
                patch.object(
                    processes, "load_process_session", side_effect=tracked_load
                ),
            ):
                rows = processes.collect_process_rows(
                    project_filter="alpha", include_all=True
                )

        self.assertEqual(rows, [])
        self.assertEqual(len(opened), 1)
        self.assertIn("alpha", opened[0])


class ProcessProbeTests(unittest.TestCase):
    def test_batches_fallback_probes_and_preserves_exact_tokens(self) -> None:
        completed = SimpleNamespace(
            returncode=0,
            stdout=("101 Wed Aug 20 12:00:01 2026\n202 Wed Aug 20 12:00:02 2026\n"),
            stderr="",
        )
        with (
            patch(
                "processes._linux_process_start_time_token", return_value=""
            ) as linux,
            patch("processes.subprocess.run", return_value=completed) as run,
        ):
            probe = processes.probe_process_start_times([101, 202, 101])

        self.assertEqual(
            probe.tokens,
            {
                101: "ps:Wed Aug 20 12:00:01 2026",
                202: "ps:Wed Aug 20 12:00:02 2026",
            },
        )
        self.assertEqual(probe.unknown, set())
        self.assertEqual(linux.call_count, 2)
        self.assertEqual(run.call_count, 1)
        self.assertEqual(run.call_args.args[0][:3], ["ps", "-p", "101,202"])
        self.assertIsNone(processes._ps_start_time_tokens("unparseable"))

    def test_isolates_malformed_inputs_and_probe_rows(self) -> None:
        mixed = SimpleNamespace(
            returncode=0,
            stdout="101 Wed Aug  20 12:00:01 2026   \nunparseable\n",
            stderr="",
        )
        with (
            patch("processes._linux_process_start_time_token", return_value=""),
            patch("processes.subprocess.run", return_value=mixed),
        ):
            probe = processes.probe_process_start_times([101, 202])
        self.assertEqual(probe.tokens, {101: "ps:Wed Aug 20 12:00:01 2026"})
        self.assertEqual(probe.unknown, {202})

        bad_token = SimpleNamespace(
            returncode=0, stdout="101 not-a-start-time\n", stderr=""
        )
        with (
            patch("processes._linux_process_start_time_token", return_value=""),
            patch("processes.subprocess.run", return_value=bad_token),
        ):
            probe = processes.probe_process_start_times([101])
        self.assertEqual(probe.tokens, {})
        self.assertEqual(probe.unknown, {101})

        empty_success = SimpleNamespace(returncode=0, stdout="", stderr="")
        with (
            patch("processes._linux_process_start_time_token", return_value=""),
            patch("processes.subprocess.run", return_value=empty_success),
        ):
            probe = processes.probe_process_start_times([101])
        self.assertEqual(probe.tokens, {})
        self.assertEqual(probe.unknown, {101})

        valid = SimpleNamespace(
            returncode=0,
            stdout="101 Wed Aug 20 12:00:01 2026\n",
            stderr="",
        )
        with (
            patch("processes._linux_process_start_time_token", return_value=""),
            patch("processes.subprocess.run", return_value=valid) as run,
        ):
            probe = processes.probe_process_start_times([101, 2**63])
        self.assertEqual(probe.tokens, {101: "ps:Wed Aug 20 12:00:01 2026"})
        self.assertEqual(probe.unknown, {2**63})
        self.assertEqual(run.call_args.args[0][2], "101")

        known = processes.ProcessStartTimeProbe(
            tokens={101: "ps:synthetic"}, unknown=set()
        )
        for malformed_pid in ("101", 101.5, True, None, -1):
            with self.subTest(pid=malformed_pid):
                start = {
                    "pid": malformed_pid,
                    "pid_start_time": "ps:synthetic",
                }
                self.assertEqual(
                    processes.process_liveness_status(start, known), "unknown"
                )
        self.assertEqual(
            processes.process_liveness_status(
                {"pid": 101, "pid_start_time": "ps:synthetic"}, known
            ),
            "live",
        )

    def test_failed_probes_remain_unknown(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / (
                "2026-08-20T00-00-00-000Z_00000000-0000-4000-8000-000000000000.jsonl"
            )
            entries = [
                {
                    "type": "session",
                    "id": "00000000-0000-4000-8000-000000000000",
                    "timestamp": "2026-08-20T00:00:00.000Z",
                },
                {
                    "type": "process_start",
                    "id": "start",
                    "pid": 123,
                    "pid_start_time": "ps:synthetic",
                },
            ]
            path.write_text(
                "\n".join(json.dumps(entry) for entry in entries) + "\n",
                encoding="utf-8",
            )

            with (
                patch("processes._linux_process_start_time_token", return_value=""),
                patch(
                    "processes.subprocess.run",
                    side_effect=subprocess.TimeoutExpired("ps", 2),
                ),
            ):
                rows = processes.session_process_rows(str(path))

        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0].status, "unknown")

        failed = SimpleNamespace(
            returncode=1, stdout="", stderr="ps: invalid process id"
        )
        with (
            patch("processes._linux_process_start_time_token", return_value=""),
            patch("processes.subprocess.run", return_value=failed),
        ):
            probe = processes.probe_process_start_times([123, 999999])
        self.assertEqual(probe.tokens, {})
        self.assertEqual(probe.unknown, {123, 999999})


if __name__ == "__main__":
    unittest.main()
