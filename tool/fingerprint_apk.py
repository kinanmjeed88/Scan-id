#!/usr/bin/env python3
"""Summarize an APK in one line: size, hash, contents, and what is deflated.

The artifact a phone downloads is a zip of the APK, so its size says nothing
about the APK: the same 329 MB package uploads as 203 MB when its entries are
deflated inside and as 169 MB when they are stored. Two uploads that differ by
34 MB therefore prove nothing on their own, and two APKs that are the same size
can still hand Dart a different payload. This prints the facts that separate
those cases: entry count, uncompressed and compressed totals, how many bytes
are stored versus deflated, and the Dart payload the app starts from
(`kernel_blob.bin` for a debug build, `libapp.so` for an AOT one).

Usage: fingerprint_apk.py <label>=<path> [...]
"""

from __future__ import annotations

import hashlib
import sys
import zipfile
from pathlib import Path


def short_hash(archive: zipfile.ZipFile, name: str) -> str:
    digest = hashlib.sha256()
    with archive.open(name) as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()[:12]


def describe(label: str, path: Path) -> str:
    with zipfile.ZipFile(path) as archive:
        entries = [info for info in archive.infolist() if not info.is_dir()]
        stored = [info for info in entries if info.compress_type == 0]
        deflated = [info for info in entries if info.compress_type == 8]
        other = len(entries) - len(stored) - len(deflated)
        sizes = sum(info.file_size for info in entries)
        compressed = sum(info.compress_size for info in entries)
        parts = [
            f"{label} file={path.stat().st_size:,}B",
            f"apkSha={hashlib.sha256(path.read_bytes()).hexdigest()[:12]}",
            f"entries={len(entries)}",
            f"uncompressed={sizes:,}",
            f"inZipCompressed={compressed:,}",
            f"stored={len(stored)}/{sum(i.file_size for i in stored):,}B",
            f"deflated={len(deflated)}",
            f"otherZipMethods={other}",
        ]
        names = {info.filename: info for info in entries}
        for candidate in ("assets/flutter_assets/kernel_blob.bin",):
            info = names.get(candidate)
            if info is None:
                parts.append("kernelBlob=absent")
            else:
                parts.append(
                    f"kernelBlob={info.file_size:,}B/"
                    f"{'stored' if info.compress_type == 0 else 'deflated'}/"
                    f"sha={short_hash(archive, candidate)}"
                )
        aot = sorted(name for name in names if name.startswith("lib/") and name.endswith("libapp.so"))
        parts.append("libappSo=" + (",".join(aot) if aot else "absent"))
    return " ".join(parts)


def main() -> int:
    pairs = sys.argv[1:]
    if not pairs:
        print(__doc__)
        return 2
    rows = []
    for pair in pairs:
        label, _, raw = pair.partition("=")
        path = Path(raw)
        if not path.is_file():
            print(f"::error title=apk-fingerprint::missing APK {path}")
            return 1
        rows.append(describe(label, path))
        print(describe(label, path))
    # One annotation: the job that runs this also publishes the differential
    # findings, and GitHub keeps about ten annotations per job.
    print("::notice title=apk-fingerprint::" + " || ".join(rows))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
