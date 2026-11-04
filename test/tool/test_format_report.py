from __future__ import annotations

import contextlib
import io
import tempfile
import unittest
from pathlib import Path
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

    @patch("tool.format_report.subprocess.run")
    def test_formatter_diff_is_published_as_an_annotation(self, run_mock):
        # A CI log can be unreachable; the diff must therefore travel with the
        # check run, newline-escaped, so the author can see the exact rewrite.
        run_mock.return_value = SimpleNamespace(
            returncode=0, stdout="void main() {}\n", stderr=""
        )
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "sample.dart"
            path.write_text("void  main() {}\n", encoding="utf-8")
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                format_report.report_diff(path)
        text = output.getvalue()
        self.assertIn("dart format would rewrite", text)
        self.assertIn(
            f"::error title=dart-format-diff {path.as_posix()} part 1", text
        )
        self.assertIn("%0A", text, "annotation messages must not carry raw newlines")

    @patch("tool.format_report.subprocess.run")
    def test_identical_file_publishes_nothing(self, run_mock):
        run_mock.return_value = SimpleNamespace(
            returncode=0, stdout="void main() {}\n", stderr=""
        )
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "sample.dart"
            path.write_text("void main() {}\n", encoding="utf-8")
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                format_report.report_diff(path)
        self.assertEqual(output.getvalue(), "")


if __name__ == "__main__":
    unittest.main()
