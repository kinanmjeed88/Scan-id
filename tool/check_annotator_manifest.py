#!/usr/bin/env python3
"""Audit the merged manifest for the offline annotation-only Android flavor."""

from __future__ import annotations

import argparse
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

ANDROID = "{http://schemas.android.com/apk/res/android}"
EXPECTED_LABEL = "استوديو الوسوم المرجعية"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("manifest", type=Path)
    args = parser.parse_args()
    if not args.manifest.is_file():
        print("FAIL: merged annotator manifest was not produced.", file=sys.stderr)
        return 1
    root = ET.parse(args.manifest).getroot()
    permission_tags = {
        "uses-permission",
        "uses-permission-sdk-23",
        "uses-permission-sdk-m",
    }
    permissions = sorted(
        node.get(ANDROID + "name", "")
        for node in root
        if node.tag in permission_tags
    )
    if permissions:
        message = "offline annotator declares Android permissions: " + ", ".join(permissions)
        print(f"::error title=Offline annotator permission audit::{message}", file=sys.stderr)
        print(f"FAIL: {message}", file=sys.stderr)
        return 1
    application = root.find("application")
    actual_label = None if application is None else application.get(ANDROID + "label")
    if actual_label != EXPECTED_LABEL:
        message = f"merged annotator application label is {actual_label!r}, expected {EXPECTED_LABEL!r}"
        print(f"::error title=Offline annotator label audit::{message}", file=sys.stderr)
        print(f"FAIL: {message}.", file=sys.stderr)
        return 1
    print("PASS: annotator APK declares no Android permissions and has its independent label.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
