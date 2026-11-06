#!/usr/bin/env python3
"""Guard the Android JNI names used by the bundled ONNX Runtime.

Flutter 3.35.7 enables R8 for release APKs and loads android/app/proguard-rules.pro.
The pinned flutter_onnxruntime revision does not supply consumer keep rules.
Its Java API is also called by name from libonnxruntime4j_jni.so; retaining a
class name alone does not retain the constructors, fields and methods JNI uses.

This is a packaging-contract check, not a claim that a device runtime test ran.
The separate Android release integration test exercises the actual JNI calls.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
RULES_PATH = Path("android/app/proguard-rules.pro")
REQUIRED_RULE = re.compile(
    r"^-keep\s+class\s+ai\.onnxruntime\.\*\*\s*\{\s*\*;\s*\}$"
)


def verify(root: Path = ROOT) -> list[str]:
    path = root / RULES_PATH
    if not path.is_file():
        return [f"{RULES_PATH.as_posix()} is missing; Release R8 can rename ONNX JNI classes/members."]
    directives = []
    for line in path.read_text(encoding="utf-8").splitlines():
        directive = line.split("#", 1)[0].strip()
        if directive:
            directives.append(" ".join(directive.split()))
    if not any(REQUIRED_RULE.fullmatch(directive) for directive in directives):
        return [
            f"{RULES_PATH.as_posix()} must contain "
            "-keep class ai.onnxruntime.** { *; } to preserve native lookups."
        ]
    return []


def main() -> int:
    errors = verify()
    for error in errors:
        print(f"FAIL: {error}", file=sys.stderr)
    if errors:
        return 1
    print("PASS: ONNX Runtime JNI classes and members are kept in R8 release builds.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
