from __future__ import annotations

import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

GATE = Path(__file__).resolve().parents[2] / "tool" / "ci_gate.py"

NESTED_FAILURE = (
    "print('::error title=inner::line one%0Aline two'); raise SystemExit(1)"
)


def run_gate(directory: str, *command: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, str(GATE), "demo", *command],
        cwd=directory,
        capture_output=True,
        text=True,
        encoding="utf-8",
        check=False,
    )


class CiGateTest(unittest.TestCase):
    def test_nested_annotation_is_forwarded_and_decoded(self):
        # A nested gate (formatter, linter) publishes its own annotation. The
        # outer budget must carry that message through instead of dropping it
        # behind generic heuristics, and must not double-escape it.
        with tempfile.TemporaryDirectory() as directory:
            result = run_gate(
                directory, sys.executable, "-c", NESTED_FAILURE
            )

        self.assertEqual(result.returncode, 1)
        self.assertIn("title=demo exit=1", result.stdout)
        self.assertIn("line one", result.stdout)
        self.assertIn("line two", result.stdout)
        # The dedicated summary chunk carries the decoded message and is escaped
        # exactly once; only the raw log tail may still hold the nested escapes.
        summary = result.stdout.split("part=summary::", 1)[1].split("\n", 1)[0]
        self.assertIn("line one%0Aline two", summary)
        self.assertNotIn("%250A", summary)
        self.assertNotIn("title=inner", summary)

    def test_success_is_reported_as_a_notice(self):
        with tempfile.TemporaryDirectory() as directory:
            result = run_gate(directory, sys.executable, "-c", "print('ok')")

        self.assertEqual(result.returncode, 0)
        self.assertIn("::notice title=demo exit=0", result.stdout)
        self.assertNotIn("::error", result.stdout)

    def test_failing_command_keeps_its_exit_status(self):
        with tempfile.TemporaryDirectory() as directory:
            result = run_gate(
                directory, sys.executable, "-c", "print('boom'); raise SystemExit(3)"
            )

        self.assertEqual(result.returncode, 3)
        self.assertIn("title=demo exit=3", result.stdout)


if __name__ == "__main__":
    unittest.main()
