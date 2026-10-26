from __future__ import annotations

import contextlib
import io
import unittest
from types import SimpleNamespace
from unittest.mock import patch

from tool import format_report


class FormatReportTest(unittest.TestCase):
    @patch("tool.format_report.subprocess.run")
    def test_read_only_formatter_passes_exact_command(self, run_mock):
        run_mock.return_value = SimpleNamespace(returncode=0, stdout="", stderr="")
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            result = format_report.main()
        self.assertEqual(result, 0)
        self.assertIn("PASS: dart format reports no changes", output.getvalue())
        run_mock.assert_called_once_with(
            ["dart", "format", "--output=none", "--set-exit-if-changed", "."],
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            check=False,
        )

    @patch("tool.format_report.subprocess.run")
    def test_formatter_failure_is_returned_without_mutation(self, run_mock):
        run_mock.return_value = SimpleNamespace(returncode=1, stdout="Changed files\n", stderr="")
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            result = format_report.main()
        self.assertEqual(result, 1)
        self.assertIn("no files were staged, rewritten, committed, or pushed", output.getvalue())
        run_mock.assert_called_once()


if __name__ == "__main__":
    unittest.main()
