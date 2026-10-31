#!/usr/bin/env python3
"""Explain how two or more APKs built from the same commit really differ.

A phone runs the `diagnostic` build and exits after the splash screen with the
plain `scanid` debug build, from the same commit, so "the builds are the same"
cannot be assumed. This tool reads what is actually packaged and reports:

  * per-group entry counts and sizes, uncompressed and compressed, because two
    APKs can hold identical files and still differ by tens of megabytes if one
    stores an entry and the other deflates it;
  * every shared native library with its SHA-256, so a silently different
    engine or runtime is visible;
  * the zip method (stored/deflated) and the data offset alignment of each
    entry: with `extractNativeLibs=false` a shared library is mapped straight
    out of the APK, and a misaligned or re-deflated one is exactly the kind of
    difference that loads on one device and fails on another;
  * a text diff of the merged manifests, which is where `debuggable`,
    `extractNativeLibs`, application/activity names and providers live.

Everything is published as GitHub annotations because artifact storage is not
reachable from the phone-only diagnosis path, and written to a Markdown report.

Usage: compare_apks.py --config <json>

The JSON file is:
    {
      "report": "diagnostics/apk-differential.md",
      "baseline": {"label": "scanid-debug", "apk": "...", "manifest": "..."},
      "variants": [{"label": "...", "apk": "...", "manifest": "..."}, ...]
    }
"""

from __future__ import annotations

import collections
import difflib
import hashlib
import json
import sys
import zipfile
from pathlib import Path

NOTICE_LIMIT = 1700
LOCAL_HEADER = 30


def sha256_of(archive: zipfile.ZipFile, name: str) -> str:
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


class Apk:
    def __init__(self, label: str, path: Path) -> None:
        self.label = label
        self.path = path
        self.file_size = path.stat().st_size
        self.archive = zipfile.ZipFile(path)
        self.entries: dict[str, dict[str, int]] = {}
        for info in self.archive.infolist():
            if info.is_dir():
                continue
            name_bytes = len(info.filename.encode("utf-8"))
            self.entries[info.filename] = {
                "size": info.file_size,
                "compressed": info.compress_size,
                "method": info.compress_type,
                "data_offset": info.header_offset + LOCAL_HEADER + name_bytes + len(info.extra),
            }
        self.uncompressed = sum(e["size"] for e in self.entries.values())
        self.compressed = sum(e["compressed"] for e in self.entries.values())
        self.groups: dict[str, list[int]] = collections.defaultdict(lambda: [0, 0, 0])
        for name, entry in self.entries.items():
            bucket = self.groups[group_of(name)]
            bucket[0] += 1
            bucket[1] += entry["size"]
            bucket[2] += entry["compressed"]

    @property
    def total_compressed(self) -> int:
        return sum(e["compressed"] for e in self.entries.values())


def method_name(method: int) -> str:
    return {0: "stored", 8: "deflated", 12: "bzip2", 93: "zstd"}.get(method, f"method{method}")


def is_native(name: str) -> bool:
    return name.startswith("lib/") and name.endswith(".so")


def compare(baseline: Apk, variant: Apk, manifests: dict[str, dict[str, str]]) -> dict:
    only_base = sorted(set(baseline.entries) - set(variant.entries))
    only_var = sorted(set(variant.entries) - set(baseline.entries))
    shared = sorted(set(baseline.entries) & set(variant.entries))

    native_mismatch = []
    for name in shared:
        if not is_native(name):
            continue
        digest_base = sha256_of(baseline.archive, name)
        digest_var = sha256_of(variant.archive, name)
        if digest_base != digest_var:
            native_mismatch.append((name, digest_base, digest_var))

    method_mismatch = []
    alignment = []
    for name in shared:
        base_entry, var_entry = baseline.entries[name], variant.entries[name]
        if base_entry["method"] != var_entry["method"]:
            method_mismatch.append(
                (
                    name,
                    base_entry["method"],
                    base_entry["size"],
                    base_entry["compressed"],
                    var_entry["method"],
                    var_entry["compressed"],
                )
            )
        # Only a shared library is mapped out of the APK in place, so only its
        # alignment decides whether the loader can use it directly.
        if is_native(name):
            alignment.append(
                (
                    name,
                    base_entry["data_offset"] % 16384,
                    var_entry["data_offset"] % 16384,
                    base_entry["method"],
                    var_entry["method"],
                )
            )

    compressed_deltas = sorted(
        (
            (variant.entries[n]["compressed"] - baseline.entries[n]["compressed"], n)
            for n in shared
            if variant.entries[n]["compressed"] != baseline.entries[n]["compressed"]
        ),
        key=lambda item: -abs(item[0]),
    )

    manifest_diff: list[str] = []
    base_manifest = manifests.get(baseline.label, {})
    var_manifest = manifests.get(variant.label, {})
    for key in ("merged", "source"):
        left, right = base_manifest.get(key), var_manifest.get(key)
        if not left or not right:
            continue
        diff = difflib.unified_diff(
            Path(left).read_text(encoding="utf-8").splitlines(),
            Path(right).read_text(encoding="utf-8").splitlines(),
            fromfile=f"{baseline.label}:{key}",
            tofile=f"{variant.label}:{key}",
            lineterm="",
            n=1,
        )
        manifest_diff.extend(line for line in diff if line[:1] in "+-@")

    return {
        "only_base": only_base,
        "only_var": only_var,
        "native_mismatch": native_mismatch,
        "method_mismatch": method_mismatch,
        "alignment": alignment,
        "compressed_deltas": compressed_deltas,
        "manifest_diff": manifest_diff,
    }


def notice(title: str, body: str) -> None:
    body = body[:NOTICE_LIMIT].replace("%", "%25").replace("\r", "")
    body = body.replace("\n", "~")
    print(f"::notice title={title}::{body}")


def main() -> int:
    args = sys.argv[1:]
    if len(args) != 2 or args[0] != "--config":
        print(__doc__)
        return 2
    config = json.loads(Path(args[1]).read_text(encoding="utf-8"))

    baseline = Apk(
        config["baseline"]["label"],
        Path(config["baseline"]["apk"]),
    )
    variants = [Apk(item["label"], Path(item["apk"])) for item in config["variants"]]
    manifests = {
        item["label"]: {k: item[k] for k in ("merged", "source") if item.get(k)}
        for item in [config["baseline"], *config["variants"]]
    }

    report = ["# APK differential", ""]
    report.append("Same commit, same flavor family, one variable at a time.")
    report.append("")
    report.append("| build | APK bytes | uncompressed bytes | compressed bytes | entries |")
    report.append("|---|---|---|---|---|")
    for apk in [baseline, *variants]:
        report.append(
            f"| `{apk.label}` | {apk.file_size:,} | {apk.uncompressed:,} | "
            f"{apk.compressed:,} | {len(apk.entries)} |"
        )
    report.append("")

    # One comparison per variant, reused by the report and by the annotations,
    # because hashing every shared native library is the expensive part.
    results = [(variant, compare(baseline, variant, manifests)) for variant in variants]

    summary_lines = []
    for variant, result in results:
        size_delta = variant.file_size - baseline.file_size
        summary_lines.append(
            f"{variant.label}: file{size_delta:+,} uncompressed"
            f"{variant.uncompressed - baseline.uncompressed:+,} "
            f"compressed{variant.compressed - baseline.compressed:+,} "
            f"onlyBase={len(result['only_base'])} onlyVariant={len(result['only_var'])} "
            f"soDiff={len(result['native_mismatch'])} "
            f"methodDiff={len(result['method_mismatch'])} "
            f"manifestLines={len(result['manifest_diff'])}"
        )

        report.append(f"## `{variant.label}` vs `{baseline.label}`")
        report.append("")
        report.append(
            f"- APK file: {baseline.file_size:,} B → {variant.file_size:,} B "
            f"({size_delta:+,} B)"
        )
        report.append(
            f"- uncompressed content: {baseline.uncompressed:,} B → "
            f"{variant.uncompressed:,} B ({variant.uncompressed - baseline.uncompressed:+,} B)"
        )
        report.append(
            f"- compressed content: {baseline.compressed:,} B → {variant.compressed:,} B "
            f"({variant.compressed - baseline.compressed:+,} B)"
        )
        report.append("")
        report.append("### Size by group (uncompressed → compressed)")
        report.append("")
        report.append("| group | baseline files | variant files | baseline bytes | variant bytes | baseline zip | variant zip |")
        report.append("|---|---|---|---|---|---|---|")
        for group in sorted(set(baseline.groups) | set(variant.groups)):
            base = baseline.groups.get(group, [0, 0, 0])
            var = variant.groups.get(group, [0, 0, 0])
            report.append(
                f"| {group} | {base[0]} | {var[0]} | {base[1]:,} | {var[1]:,} | "
                f"{base[2]:,} | {var[2]:,} |"
            )
        report.append("")
        report.append("### Entries only in one build")
        report.append("")
        for title, names, apk in (
            ("only in baseline", result["only_base"], baseline),
            ("only in variant", result["only_var"], variant),
        ):
            report.append(f"- {title}: {len(names)}")
            for name in names[:20]:
                report.append(f"  - `{name}` — {apk.entries[name]['size']:,} B")
        report.append("")
        report.append("### Native library hashes")
        report.append("")
        if result["native_mismatch"]:
            for name, left, right in result["native_mismatch"]:
                report.append(f"- `{name}` differs: {left[:16]} vs {right[:16]}")
        else:
            shared_native = sum(1 for n in baseline.entries if is_native(n) and n in variant.entries)
            report.append(f"- all {shared_native} shared native libraries are byte-identical")
        report.append("")
        report.append("### Zip method differences")
        report.append("")
        if result["method_mismatch"]:
            for name, left_method, size, left_comp, right_method, right_comp in result["method_mismatch"]:
                report.append(
                    f"- `{name}` ({size:,} B): baseline {method_name(left_method)} → "
                    f"{left_comp:,} B, variant {method_name(right_method)} → {right_comp:,} B"
                )
        else:
            report.append("- none")
        report.append("")
        report.append("### Native library alignment (data offset modulo 16 KiB)")
        report.append("")
        misaligned = [
            (name, base_mod, var_mod)
            for name, base_mod, var_mod, base_method, var_method in result["alignment"]
            if base_mod != var_mod or var_mod % 16384
        ]
        for name, base_mod, var_mod in misaligned[:20]:
            report.append(f"- `{name}`: baseline {base_mod}, variant {var_mod}")
        if not misaligned:
            report.append("- every shared library sits at the same 16 KiB-aligned offset")
        report.append("")
        report.append("### Largest compressed-size changes")
        report.append("")
        for delta, name in result["compressed_deltas"][:25]:
            report.append(
                f"- `{name}`: {baseline.entries[name]['compressed']:,} → "
                f"{variant.entries[name]['compressed']:,} ({delta:+,})"
            )
        if not result["compressed_deltas"]:
            report.append("- none")
        report.append("")
        report.append("### Merged manifest diff")
        report.append("")
        if result["manifest_diff"]:
            report.extend(f"- `{line}`" for line in result["manifest_diff"][:60])
        else:
            report.append("- no difference")

    report_path = Path(config["report"])
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.write_text("\n".join(report) + "\n", encoding="utf-8")

    # GitHub keeps about ten annotations per job, and this job exists only for
    # this comparison, so the findings are aggregated into one notice per
    # question instead of one per variant.
    notice("apk-diff summary", " | ".join(summary_lines))

    methods = [
        f"{variant.label}: {name} {method_name(m)}->{method_name(vm)} "
        f"{left:,}->{right:,} B"
        for variant, result in results
        for name, m, size, left, vm, right in result["method_mismatch"]
    ]
    notice(
        "apk-diff zip methods",
        "; ".join(methods[:8]) if methods else
        "no entry changed compression method: the file-size difference is not a stored/deflated switch",
    )

    native = [
        f"{variant.label}: {name} {left[:12]}!={right[:12]}"
        for variant, result in results
        for name, left, right in result["native_mismatch"]
    ]
    shared_native = sum(1 for n in baseline.entries if is_native(n))
    notice(
        "apk-diff native libraries",
        "; ".join(native[:8]) if native else
        f"every shared native library is byte-identical in all variants ({shared_native} libraries per APK)",
    )

    compressed = [
        f"{variant.label}: {name} "
        f"{baseline.entries[name]['compressed']:,}->{variant.entries[name]['compressed']:,}"
        for variant, result in results
        for _, name in result["compressed_deltas"][:4]
    ]
    notice(
        "apk-diff compressed sizes",
        "; ".join(compressed[:8]) if compressed else "no compressed size changed",
    )

    alignment = [
        f"{variant.label}: {name} {base_mod}->{var_mod}"
        for variant, result in results
        for name, base_mod, var_mod, _, _ in result["alignment"]
        if base_mod != var_mod or var_mod % 16384
    ]
    notice(
        "apk-diff alignment",
        "; ".join(alignment[:8]) if alignment else
        "every shared library sits at the same 16 KiB-aligned offset in every variant",
    )

    manifests_notice = [
        f"{variant.label}: " + " ".join(result["manifest_diff"][:10])
        for variant, result in results
        if result["manifest_diff"]
    ]
    notice(
        "apk-diff manifests",
        " || ".join(manifests_notice[:3]) if manifests_notice else
        "merged manifests produce no attribute difference",
    )

    entries = [
        f"{variant.label}: onlyBase={result['only_base'][:4]} onlyVariant={result['only_var'][:4]}"
        for variant, result in results
        if result["only_base"] or result["only_var"]
    ]
    notice(
        "apk-diff entries",
        "; ".join(entries[:6]) if entries else
        "the entry list is identical in the baseline and in every variant",
    )

    print(f"report written to {report_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
