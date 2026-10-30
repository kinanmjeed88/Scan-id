#!/usr/bin/env python3
"""Temporary read-only formatter output bridge for the restricted runner."""
from __future__ import annotations
import base64
import subprocess
import sys
from pathlib import Path

files = [
    "lib/imaging/boundary_proposal_cascade.dart",
    "lib/imaging/docaligner_model.dart",
    "test/imaging/boundary_proposal_cascade_test.dart",
    "test/imaging/docaligner_model_test.dart",
]
for name in files:
    result = subprocess.run(
        ["dart", "format", "--output=show", name],
        check=False,
        capture_output=True,
    )
    if result.returncode:
        print(f"::error title=format-preview-failed::{name}")
        sys.exit(result.returncode)
    source = result.stdout
    if not source:
        source = Path(name).read_bytes()
    encoded = base64.b64encode(source).decode("ascii")
    print(f"::notice title=format-preview-{Path(name).name}::{encoded}")
