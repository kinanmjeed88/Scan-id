#!/usr/bin/env python3
"""Emit a formatter diff for one Dart file as CI-readable base64 notices."""
from __future__ import annotations

import base64
import difflib
from pathlib import Path
import subprocess
import sys

path = Path(sys.argv[1])
result = subprocess.run(
    ["dart", "format", "--output=show", str(path)],
    check=False,
    capture_output=True,
    text=True,
    encoding="utf-8",
    errors="replace",
)
if result.returncode:
    print(result.stderr, file=sys.stderr, end="")
    raise SystemExit(result.returncode)
original = path.read_text(encoding="utf-8")
formatted = result.stdout
patch = "".join(
    difflib.unified_diff(
        original.splitlines(keepends=True),
        formatted.splitlines(keepends=True),
        fromfile=str(path),
        tofile=f"{path} (dart format)",
    )
)
if not patch:
    print("FORMAT_PREVIEW: no formatter changes")
    raise SystemExit(0)
encoded = base64.b64encode(patch.encode("utf-8")).decode("ascii")
chunk_size = 2400
chunks = [encoded[i:i + chunk_size] for i in range(0, len(encoded), chunk_size)]
for index, chunk in enumerate(chunks, 1):
    print(f"FORMAT_PREVIEW_BASE64 {index}/{len(chunks)} {chunk}")
