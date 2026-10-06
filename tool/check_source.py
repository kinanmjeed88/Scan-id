#!/usr/bin/env python3
"""Structural audit only. This does NOT analyze Dart or execute Flutter tests."""
from pathlib import Path
import re
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parent.parent
files = sorted((ROOT / "lib").rglob("*.dart")) + sorted((ROOT / "test").rglob("*.dart"))
for file in files:
    source = file.read_text(encoding="utf-8")
    for target in re.findall(r"(?:import|export)\s+'([^']+)'", source):
        if target.startswith("package:scan_id/"):
            resolved = ROOT / "lib" / target.removeprefix("package:scan_id/")
        elif ":" not in target:
            resolved = file.parent / target
        else:
            continue
        assert resolved.is_file(), f"Unresolved local import in {file}: {target}"
    if file.is_relative_to(ROOT / "lib/domain"):
        assert "package:flutter" not in source, f"Domain depends on Flutter: {file}"
        assert "dart:io" not in source, f"Domain depends on file IO: {file}"
    assert "\x00" not in source, f"Literal NUL byte in {file}"

android = "{http://schemas.android.com/apk/res/android}"
manifest = ET.parse(ROOT / "android/app/src/main/AndroidManifest.xml").getroot()
app = manifest.find("application")
assert app is not None
assert app.get(android + "allowBackup") == "false"
assert app.get(android + "fullBackupContent") == "false"
assert app.get(android + "dataExtractionRules") == "@xml/data_extraction_rules"
assert not manifest.findall("uses-permission"), "Unexpected release permission"
rules = ET.parse(ROOT / "android/app/src/main/res/xml/data_extraction_rules.xml").getroot()
for mode in ("cloud-backup", "device-transfer"):
    assert {item.get("domain") for item in rules.findall(mode + "/exclude")} == {
        "root", "file", "database", "sharedpref", "external"
    }

count = sum(len(re.findall(r"\btest(?:Widgets)?\(", file.read_text(encoding="utf-8")))
            for file in files if file.name.endswith("_test.dart"))
print(f"PASS: {len(files)} Dart files have resolvable local imports; domain boundaries checked.")
print("PASS: Android XML parses, release manifest has no permissions and disables automatic backup.")
print(f"INVENTORY: {count} declared Dart/Flutter tests. NOT executed by this audit.")
