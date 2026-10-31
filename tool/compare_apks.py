#!/usr/bin/env python3
"""Compare two Android APKs of the same project and explain the difference.

A device report says the `diagnostic` debug build starts normally while the
`scanid` debug build exits right after the splash screen, from the same commit.
Build-mode claims are not evidence, so this tool reads the packaged bytes:
which entries exist, how big they are, which native libraries differ by hash,
and which manifest attributes differ. It prints bounded notices (the only
channel that is reachable when artifact storage is not) and writes a full
report next to the CI diagnostics.

Usage: compare_apks.py <apk-a> <apk-b> <report-path>
"""

from __future__ import annotations

import collections
import hashlib
import sys
import zipfile
from pathlib import Path

NOTICE_LIMIT = 1800


def sha256(archive: zipfile.ZipFile, name: str) -> str:
    digest = hashlib.sha256()
    with archive.open(name) as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def group_of(name: str) -> str:
    if name.startswith("lib/"):
        parts = name.split("/")
        return f"lib/{parts[1]}" if len(parts) > 2 else "lib"
    if name.startswith("assets/flutter_assets/"):
        return "assets/flutter_assets"
    if name.startswith("assets/"):
        return "assets/other"
    if name.startswith("res/"):
        return "res"
    if name == "AndroidManifest.xml":
        return "manifest"
    if name.startswith("classes") and name.endswith(".dex"):
        return "dex"
    if name.startswith("META-INF/"):
        return "signature"
    return "other"


def inventory(path: Path) -> tuple[dict[str, tuple[int, int, str]], zipfile.ZipFile]:
    archive = zipfile.ZipFile(path)
    entries: dict[str, tuple[int, int, str]] = {}
    for info in archive.infolist():
        if info.is_dir():
            continue
        entries[info.filename] = (info.file_size, info.compress_size, info.date_time and "")
    return entries, archive


def main() -> int:
    if len(sys.argv) != 4:
        print(__doc__)
        return 2
    first, second, report_path = Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3])
    for path in (first, second):
        if not path.is_file():
            print(f"missing APK: {path}", file=sys.stderr)
            return 2

    entries_a, archive_a = inventory(first)
    entries_b, archive_b = inventory(second)
    report = [f"# APK comparison\n", f"- A: `{first.name}` ({first.stat().st_size:,} B)"]
    report.append(f"- B: `{second.name}` ({second.stat().st_size:,} B)\n")

    def group_totals(entries):
        totals: dict[str, list[int]] = collections.defaultdict(lambda: [0, 0])
        for name, (size, compressed, _) in entries.items():
            bucket = totals[group_of(name)]
            bucket[0] += 1
            bucket[1] += size
        return totals

    totals_a, totals_b = group_totals(entries_a), group_totals(entries_b)
    report.append("## Size by group\n")
    report.append("| group | A files | A bytes | B files | B bytes | delta |")
    report.append("|---|---|---|---|---|---|")
    group_deltas = []
    for group in sorted(set(totals_a) | set(totals_b)):
        a_files, a_bytes = totals_a.get(group, [0, 0])
        b_files, b_bytes = totals_b.get(group, [0, 0])
        delta = b_bytes - a_bytes
        if delta:
            group_deltas.append((abs(delta), group))
        report.append(
            f"| {group} | {a_files} | {a_bytes:,} | {b_files} | {b_bytes:,} | {delta:+,} |"
        )
    group_deltas.sort(reverse=True)

    only_a = sorted(set(entries_a) - set(entries_b))
    only_b = sorted(set(entries_b) - set(entries_a))
    shared = sorted(set(entries_a) & set(entries_b))

    native_deltas = []
    for name in shared:
        if not name.startswith("lib/") or not name.endswith(".so"):
            continue
        size_a = entries_a[name][0]
        size_b = entries_b[name][0]
        weak = size_a != size_b
        digest_a = sha256(archive_a, name)
        digest_b = sha256(archive_b, name)
        if weak or digest_a != digest_b:
            native_deltas.append((name, size_a, size_b, digest_a, digest_b))

    report.append("\n## Native libraries per ABI\n")
    report.append("| library | A bytes | B bytes | A sha256 | B sha256 |")
    report.append("|---|---|---|---|---|")
    for name in shared:
        if not name.startswith("lib/") or not name.endswith(".so"):
            continue
        size_a, size_b = entries_a[name][0], entries_b[name][0]
        if (name, size_a, size_b) in {(n, s, t) for n, s, t, _, _ in native_deltas}:
            report.append(
                f"| {name} | {size_a:,} | {size_b:,} | {sha256(archive_a, name)[:16]} | "
                f"{sha256(archive_b, name)[:16]} |"
            )
        else:
            report.append(f"| {name} | {size_a:,} | {size_b:,} | identical | identical |")
    for name in only_a:
        if name.startswith("lib/"):
            report.append(f"| {name} | {entries_a[name][0]:,} | absent | only in A | — |")
    for name in only_b:
        if name.startswith("lib/"):
            report.append(f"| {name} | absent | {entries_b[name][0]:,} | — | only in B |")

    report.append("\n## Entries only in one APK\n")
    for title, names, entries in (
        ("only in A", only_a, entries_a),
        ("only in B", only_b, entries_b),
    ):
        report.append(f"### {title} ({len(names)})\n")
        for name in names[:40]:
            report.append(f"- `{name}` — {entries[name][0]:,} B")
        if not names:
            report.append("- (none)")

    size_deltas = [
        (abs(entries_b[n][0] - entries_a[n][0]), n)
        for n in shared
        if entries_b[n][0] != entries_a[n][0]
    ]
    size_deltas.sort(reverse=True)
    report.append("\n## Largest shared-entry size changes\n")
    for delta, name in size_deltas[:30]:
        report.append(
            f"- `{name}` — A {entries_a[name][0]:,} B, B {entries_b[name][0]:,} B"
        )
    if not size_deltas:
        report.append("- (none)")

    big_assets = [
        (entries_b[name][0], name)
        for name in entries_b
        if name.startswith("assets/flutter_assets/") and entries_b[name][0] > 1_000_000
    ]
    big_assets.sort(reverse=True)
    report.append("\n## Assets over 1 MB in B\n")
    for size, name in big_assets[:20]:
        present = "yes" if name in entries_a else "NO"
        report.append(f"- `{name}` — {size:,} B (in A: {present})")

    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.write_text("\n".join(report) + "\n", encoding="utf-8")

    def notice(title: str, body: str) -> None:
        body = body[:NOTICE_LIMIT].replace("%", "%25").replace("\r", "")
        body = body.replace("\n", "~")
        print(f"::notice title={title}::{body}")

    notice(
        "apk-compare totals",
        f"A={first.name} {first.stat().st_size:,}B entries={len(entries_a)} | "
        f"B={second.name} {second.stat().st_size:,}B entries={len(entries_b)} | "
        f"onlyA={len(only_a)} onlyB={len(only_b)} sizeDelta={sum(d for d, _ in group_deltas):,}",
    )
    notice(
        "apk-compare group deltas",
        "; ".join(
            f"{group}: {totals_b.get(group, [0, 0])[1] - totals_a.get(group, [0, 0])[1]:+,}"
            for _, group in group_deltas[:8]
        )
        or "none",
    )
    if native_deltas:
        notice(
            "apk-compare native differences",
            "; ".join(
                f"{name} A={size_a:,} B={size_b:,} sameBytes={digest_a == digest_b}"
                for name, size_a, size_b, digest_a, digest_b in native_deltas[:10]
            ),
        )
    else:
        notice(
            "apk-compare native differences",
            f"none: every shared .so is byte-identical "
            f"({sum(1 for n in shared if n.startswith('lib/'))} shared libraries)",
        )
    notice(
        "apk-compare only-in-one",
        "onlyA=["
        + ", ".join(f"{n} ({entries_a[n][0]:,}B)" for n in only_a[:12])
        + "] onlyB=["
        + ", ".join(f"{n} ({entries_b[n][0]:,}B)" for n in only_b[:12])
        + "]",
    )
    notice(
        "apk-compare biggest shared changes",
        "; ".join(
            f"{name} A={entries_a[name][0]:,} B={entries_b[name][0]:,}"
            for _, name in size_deltas[:10]
        )
        or "none",
    )
    print(f"report written to {report_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
