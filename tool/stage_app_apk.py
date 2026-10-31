#!/usr/bin/env python3
"""Keep the published APK the one the build produced, and prove it.

`flutter test integration_test/<file> -d <device> --flavor <flavor>` builds an
APK whose Dart entry point is the test file, and it writes it to the same
`build/app/outputs/flutter-apk/app-<flavor>-debug.apk` path as the app build.
The instrumentation step in `verify.yml` runs exactly that for the `scanid`
flavor, so afterwards the file at that path is the test harness: it starts,
runs the tests, and exits. A job that uploads that path publishes the harness
and the phone that installs it sees the splash screen and then the app closing,
while a flavor the test does not target (the diagnostic build) keeps working.

Two subcommands:

  stage --apk <built apk> --out <directory>
      Move the APK somewhere the instrumentation step cannot reach and record
      what was staged (APK hash, entry count, Dart payload hash).

  check --apk <apk about to be published> --expected <expected.json>
      Refuse to publish a package that is not the staged one, and report what
      the build directory holds now, so a rewrite by a later step is visible
      instead of silent.

Usage:
  stage_app_apk.py stage --apk PATH --out DIR
  stage_app_apk.py check --apk PATH --expected FILE [--built PATH]
"""

from __future__ import annotations

import hashlib
import json
import shutil
import sys
import zipfile
from pathlib import Path

DART_PAYLOAD = "assets/flutter_assets/kernel_blob.bin"


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def payload_hash(apk: Path) -> str | None:
    with zipfile.ZipFile(apk) as archive:
        try:
            data = archive.read(DART_PAYLOAD)
        except KeyError:
            return None
    return hashlib.sha256(data).hexdigest()


def fingerprint(apk: Path) -> dict:
    with zipfile.ZipFile(apk) as archive:
        entries = [info for info in archive.infolist() if not info.is_dir()]
    return {
        "apk": str(apk),
        "bytes": apk.stat().st_size,
        "sha256": sha256(apk),
        "entries": len(entries),
        "uncompressed": sum(info.file_size for info in entries),
        "dartPayload": payload_hash(apk),
    }


def stage(apk: Path, out: Path) -> int:
    if not apk.is_file():
        print(f"::error title=stage-apk::missing APK to stage: {apk}")
        return 1
    out.mkdir(parents=True, exist_ok=True)
    staged = out / apk.name
    # Moved, not copied: a debug APK is ~329 MB, twice is 658 MB of runner disk
    # for nothing, and once it is out of the build directory no later step can
    # publish a replacement by accident.
    # Fingerprint before the move: the record must describe the file as built.
    record = fingerprint(apk)
    shutil.move(str(apk), staged)
    record["apk"] = str(staged)
    (out / "expected.json").write_text(json.dumps(record, indent=2), encoding="utf-8")
    print(
        f"staged {staged} sha256={record['sha256'][:16]} bytes={record['bytes']:,} "
        f"entries={record['entries']} dartPayload={(record['dartPayload'] or '')[:16]}"
    )
    return 0


def check(apk: Path, expected_path: Path, built: Path | None) -> int:
    expected = json.loads(expected_path.read_text(encoding="utf-8"))
    if not apk.is_file():
        print(f"::error title=shipped-apk::missing APK to publish: {apk}")
        return 1
    actual = fingerprint(apk)
    problems = []
    if actual["sha256"] != expected["sha256"]:
        problems.append("APK hash differs from the staged build")
    if actual["entries"] != expected["entries"]:
        problems.append(f"entry count {actual['entries']} != {expected['entries']}")
    if actual["dartPayload"] != expected["dartPayload"]:
        problems.append("Dart payload differs from the staged build")
    if actual["dartPayload"] is None:
        problems.append("no assets/flutter_assets/kernel_blob.bin: this is not a debug app package")

    print(
        f"::notice title=shipped-apk::publishing {apk.name} "
        f"sha256={actual['sha256'][:16]} bytes={actual['bytes']:,} entries={actual['entries']} "
        f"dartPayload={(actual['dartPayload'] or '')[:16]}"
    )

    # Evidence that a later step rewrote the build output, reported instead of
    # silently passing: this is exactly what the instrumentation step does to the
    # flavor it targets.
    if built is not None:
        if not built.is_file():
            print(f"::warning title=shipped-apk::build output {built} is gone")
        else:
            now = fingerprint(built)
            state = "unchanged" if now["sha256"] == expected["sha256"] else "REWRITTEN"
            print(
                f"::notice title=shipped-apk build-dir::{built.name} is {state} since the build: "
                f"bytes={now['bytes']:,} entries={now['entries']} "
                f"dartPayload={(now['dartPayload'] or '')[:16]}"
            )

    if problems:
        for problem in problems:
            print(f"::error title=shipped-apk::{problem}")
        return 1
    print("PASS: the package being published is the package the build produced.")
    return 0


def main() -> int:
    args = sys.argv[1:]
    if not args:
        print(__doc__)
        return 2
    command, rest = args[0], args[1:]
    options: dict[str, str] = {}
    index = 0
    while index < len(rest):
        key = rest[index].removeprefix("--")
        if index + 1 >= len(rest):
            print(f"missing value for --{key}", file=sys.stderr)
            return 2
        options[key] = rest[index + 1]
        index += 2
    if command == "stage":
        return stage(Path(options["apk"]), Path(options["out"]))
    if command == "check":
        built = Path(options["built"]) if "built" in options else None
        return check(Path(options["apk"]), Path(options["expected"]), built)
    print(__doc__)
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
