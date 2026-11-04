#!/usr/bin/env python3
"""Read-only, authoritative Dart formatting gate.

This script deliberately does not stage files, edit the worktree, commit, or
push. CI only reports the formatter's exit code; formatting changes belong in a
reviewed change on the working branch.

When the gate fails it also prints the formatter's own expected output for each
offending file as a unified diff. CI cannot rewrite the workspace, so without the
diff a failure only says *which* file is unformatted and the author has to guess
at the exact line breaks the formatter wants. The diff is a read-only report of
what `dart format` would write.
"""

from __future__ import annotations

import difflib
import subprocess
import sys
from pathlib import Path

COMMAND = ["dart", "format", "--output=none", "--set-exit-if-changed", "."]
SHOW_COMMAND = ["dart", "format", "--output=show"]
MAX_DIFF_LINES_PER_FILE = 400
# A CI log is not always reachable (GitHub serves it from object storage, which
# some network policies block). Annotations travel with the check run itself, so
# the same diff is also published there, chunked to stay well inside the limit.
ANNOTATION_CHUNK_CHARS = 3_500
MAX_ANNOTATIONS_PER_FILE = 4


def run(command: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        command,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        check=False,
    )


def emit_annotation(message: str, *, path: Path, part: int) -> None:
    """Publish one chunk of the formatter diff as a workflow annotation."""
    escaped = message.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")
    print(
        f"::error title=dart-format-diff {path.as_posix()} part {part} "
        f"file={path.as_posix()}::{escaped}"
    )


def report_diff(path: Path) -> None:
    shown = run([*SHOW_COMMAND, str(path)])
    if shown.returncode:
        print(f"::warning title=dart-format::could not format {path}")
        return
    expected = [
        line
        for line in shown.stdout.splitlines(keepends=True)
        if not line.startswith("Formatted ")
    ]
    current = path.read_text(encoding="utf-8").splitlines(keepends=True)
    diff = list(
        difflib.unified_diff(
            current,
            expected,
            fromfile=f"a/{path.as_posix()}",
            tofile=f"b/{path.as_posix()}",
            n=2,
        )
    )
    if not diff:
        return
    print(f"--- dart format would rewrite {path} ---")
    for line in diff[:MAX_DIFF_LINES_PER_FILE]:
        print(line.rstrip("\n"))
    if len(diff) > MAX_DIFF_LINES_PER_FILE:
        print(f"... {len(diff) - MAX_DIFF_LINES_PER_FILE} more diff lines")
    text = "\n".join(line.rstrip("\n") for line in diff[:MAX_DIFF_LINES_PER_FILE])
    for part, start in enumerate(
        range(0, len(text), ANNOTATION_CHUNK_CHARS), start=1
    ):
        if part > MAX_ANNOTATIONS_PER_FILE:
            print(f"... {path.as_posix()}: annotation budget exhausted")
            break
        emit_annotation(text[start : start + ANNOTATION_CHUNK_CHARS], path=path, part=part)


def main() -> int:
    result = run(COMMAND)
    if result.stdout:
        print(result.stdout, end="")
    if result.stderr:
        print(result.stderr, end="", file=sys.stderr)
    if result.returncode:
        for raw in result.stdout.splitlines():
            name = raw.strip()
            if not name.endswith(".dart"):
                continue
            path = Path(name)
            if path.is_file():
                report_diff(path)
        print(
            "::error title=dart-format::The read-only dart format gate failed; "
            "no files were staged, rewritten, committed, or pushed."
        )
        return result.returncode
    print("PASS: dart format reports no changes (read-only).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
