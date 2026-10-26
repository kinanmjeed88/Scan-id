#!/usr/bin/env python3
"""Guard the local-only Mostmskat corpus from every GitHub Actions checkout.

`actions/checkout@v5` uses a partial blob filter when sparse-checkout is set.
These checks ensure the repository's workflows also exclude the private corpus
from the runner worktree, including reusable and manually-dispatched workflows.
"""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github" / "workflows"
REQUIRED = (
    "sparse-checkout: |",
    "/*",
    "!/Mostmskat/",
    "sparse-checkout-cone-mode: false",
)


def verify() -> list[str]:
    failures: list[str] = []
    checkout_count = 0

    # Sparse checkout is defense in depth, not permission to keep local document
    # data in the public Git tree. Check the index so the guard also works before
    # a local commit (the worktree corpus itself may remain available offline).
    tracked = subprocess.run(
        ["git", "ls-files", "--cached", "-z", "--", "Mostmskat"],
        cwd=ROOT,
        check=True,
        capture_output=True,
    ).stdout
    if tracked:
        failures.append(
            f"Mostmskat/ contains {sum(bool(path) for path in tracked.split(bytes([0])))} tracked index path(s); "
            "keep the authorized local corpus out of Git."
        )
    ignore_file = ROOT / ".gitignore"
    ignore_lines = ignore_file.read_text(encoding="utf-8").splitlines()
    if "/Mostmskat/" not in ignore_lines:
        failures.append(".gitignore must explicitly ignore /Mostmskat/.")
    for workflow in sorted(WORKFLOWS.glob("*.yml")):
        lines = workflow.read_text(encoding="utf-8").splitlines()
        for index, line in enumerate(lines):
            if "uses: actions/checkout@" not in line:
                continue
            checkout_count += 1
            # Checkout inputs occur directly below the uses line. Stop at the
            # next workflow step so a later action cannot satisfy this check.
            indent = len(line) - len(line.lstrip())
            block = [line]
            for following in lines[index + 1 :]:
                if following.lstrip().startswith("- "):
                    next_indent = len(following) - len(following.lstrip())
                    if next_indent <= indent:
                        break
                block.append(following)
            normalized_block = [item.strip() for item in block]
            missing = [item for item in REQUIRED if item not in normalized_block]
            if missing:
                failures.append(
                    f"{workflow.relative_to(ROOT)}:{index + 1}: checkout is missing "
                    + ", ".join(repr(item) for item in missing)
                )

    if checkout_count == 0:
        failures.append("No actions/checkout action found; review the CI workflow set.")
    if not failures:
        print(
            f"PASS: all {checkout_count} GitHub Actions checkout(s) exclude "
            "Mostmskat/ with sparse partial checkout."
        )
    return failures


def main() -> int:
    failures = verify()
    if failures:
        print("FAIL: private CI checkout guard found violations:", file=sys.stderr)
        for failure in failures:
            print(f"  - {failure}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
