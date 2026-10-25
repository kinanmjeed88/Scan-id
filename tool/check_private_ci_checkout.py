#!/usr/bin/env python3
"""Guard the local-only Mostmskat corpus from every GitHub Actions checkout.

`actions/checkout@v5` uses a partial blob filter when sparse-checkout is set.
These checks ensure the repository's workflows also exclude the private corpus
from the runner worktree, including reusable and manually-dispatched workflows.
"""

from __future__ import annotations

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
