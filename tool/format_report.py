#!/usr/bin/env python3
"""Read-only, authoritative Dart formatting gate.

This script deliberately does not stage files, edit the worktree, commit, or
push. CI only reports the formatter's exit code; formatting changes belong in a
reviewed change on the working branch.
"""

from __future__ import annotations

import subprocess
import sys

COMMAND = ["dart", "format", "--output=none", "--set-exit-if-changed", "."]


def main() -> int:
    result = subprocess.run(
        COMMAND,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        check=False,
    )
    if result.stdout:
        print(result.stdout, end="")
    if result.stderr:
        print(result.stderr, end="", file=sys.stderr)
    if result.returncode:
        print(
            "::error title=dart-format::The read-only dart format gate failed; "
            "no files were staged, rewritten, committed, or pushed."
        )
        return result.returncode
    print("PASS: dart format reports no changes (read-only).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
