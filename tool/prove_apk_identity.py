#!/usr/bin/env python3
"""Prove each differential APK is the variant its filename claims.

The reduced diagnostic variants exist only if `-PscanIdProbeAction` reached
Gradle. Each action maps to its own applicationId suffix, and the startup
recorder writes that action into its report, so the packaged manifest is the
proof: a silent fallback to the default action would produce packages that
look different on the phone for the wrong reason, and the comparison built on
top of them would be worthless.

Usage: prove_apk_identity.py <directory containing *.apk>
"""

from __future__ import annotations

import hashlib
import sys
import zipfile
from pathlib import Path

# Package names the packaged manifest must declare for each build label. The
# `full` variant keeps the historical suffix because it is the build the phone
# already starts successfully, and it must stay installable as an update of it.
EXPECTED = {
    "scanid-debug": b"iq.scanid.scan_id",
    "diagnostic-full": b"iq.scanid.scan_id.startupdiag",
    "diagnostic-off": b"iq.scanid.scan_id.startupdiagoff",
    "diagnostic-load": b"iq.scanid.scan_id.startupdiagload",
    "diagnostic-env": b"iq.scanid.scan_id.startupdiagenv",
}


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__)
        return 2
    directory = Path(sys.argv[1])
    failures: list[str] = []
    rows: list[str] = []
    for label, package in EXPECTED.items():
        path = directory / f"{label}.apk"
        if not path.is_file():
            failures.append(f"{label}: missing {path}")
            continue
        with zipfile.ZipFile(path) as archive:
            manifest = archive.read("AndroidManifest.xml")
        # A binary AndroidManifest stores strings as UTF-16, and a resource-table
        # string pool may use UTF-8, so both encodings are accepted. The suffixed
        # name can only be present when the suffix was actually applied: the plain
        # debug build does not contain "startupdiag" anywhere in its manifest.
        present = any(
            needle in manifest for needle in (package, package.decode().encode("utf-16-le"))
        )
        if not present:
            failures.append(f"{label}: manifest does not declare {package.decode()}")
            continue
        digest = hashlib.sha256(path.read_bytes()).hexdigest()[:16]
        rows.append(
            f"{label}: package={package.decode()} bytes={path.stat().st_size:,} sha256[:16]={digest}"
        )
        print(f"PASS {rows[-1]}")
    # One annotation for all five: the job that runs this also publishes the
    # differential findings, and GitHub keeps about ten annotations per job.
    if rows:
        print("::notice title=apk-identity::" + " | ".join(rows))
    if failures:
        for failure in failures:
            print(f"::error title=apk-identity::{failure}")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
