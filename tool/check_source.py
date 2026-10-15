#!/usr/bin/env python3
"""Structural audit only. This does NOT analyze Dart or execute Flutter tests."""
import struct
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

# Launcher artwork: the icon is shipped branding, not a build artifact, so every
# density is pinned to the exact pixel size the platform loads and the manifests
# are checked to still point at it. Guards against a silent blank/stale icon.
res = ROOT / "android/app/src/main/res"


def png_size(path):
    data = path.read_bytes()
    assert data[:8] == b"\x89PNG\r\n\x1a\n", f"Not a PNG: {path}"
    return struct.unpack(">II", data[16:24])


for density, size in (("mdpi", 48), ("hdpi", 72), ("xhdpi", 96), ("xxhdpi", 144), ("xxxhdpi", 192)):
    assert png_size(res / f"mipmap-{density}/ic_launcher.png") == (size, size)
for density, size in (("mdpi", 432), ("hdpi", 648), ("xhdpi", 864), ("xxhdpi", 1152), ("xxxhdpi", 1440)):
    assert png_size(res / f"drawable-{density}/ic_launcher_foreground.png") == (size, size)
for density, size in (("mdpi", 128), ("hdpi", 192), ("xhdpi", 256), ("xxhdpi", 384), ("xxxhdpi", 512)):
    assert png_size(res / f"drawable-{density}/launch_image.png") == (size, size)
assert png_size(ROOT / "design/icons-v3/selected-phone-to-page-1024.png") == (1024, 1024)
assert app.get(android + "icon") == "@mipmap/ic_launcher"
adaptive = (res / "mipmap-anydpi-v26/ic_launcher.xml").read_text(encoding="utf-8")
assert "@color/ic_launcher_background" in adaptive, "Adaptive icon lost its background layer"
assert "@drawable/ic_launcher_foreground" in adaptive, "Adaptive icon lost its foreground layer"
colors = ET.parse(res / "values/colors.xml").getroot().find("color")
assert colors.get("name") == "ic_launcher_background"
# AAPT fails the whole build (':app:processDebugResources') when any @drawable /
# @color / @mipmap / @xml reference points at a resource that is not in res/, so
# resolve every local reference the app's own resource XML makes.
declared_colors = {
    node.get("name")
    for values in res.glob("values*/colors.xml")
    for node in ET.parse(values).getroot().findall("color")
}
for xml_file in sorted(res.rglob("*.xml")):
    for kind, name in re.findall(r"@(drawable|mipmap|color|xml)/([A-Za-z0-9_.]+)", xml_file.read_text(encoding="utf-8")):
        if kind == "color":
            assert name in declared_colors, f"{xml_file}: @color/{name} is not declared in values/colors.xml"
        elif kind == "xml":
            assert (res / "xml" / f"{name}.xml").is_file(), f"{xml_file}: @xml/{name} has no res/xml/{name}.xml"
        else:
            # Path.glob() yields a generator, and any() over a generator of
            # generators is always True, so the inner any() must consume it.
            assert any(
                any((res / directory).glob(f"{name}.*")) for directory in res.glob(f"{kind}*")
            ), f"{xml_file}: @{kind}/{name} resolves to no file under res/{kind}*/"
for drawable in ("drawable", "drawable-v21"):
    splash = (res / f"{drawable}/launch_background.xml").read_text(encoding="utf-8")
    assert "@drawable/launch_image" in splash, f"Splash {drawable} lost the icon artwork"
# Runner.rc embeds this file, and rc.exe rejects an ICO with a broken header.
ico = (ROOT / "windows/runner/resources/app_icon.ico").read_bytes()
assert ico[:6][:4] == b"\x00\x00\x01\x00", "app_icon.ico is not an icon file"
entries = struct.unpack("<H", ico[4:6])[0]
assert entries >= 5, "app_icon.ico must carry several sizes for Windows shell scaling"
assert "resources\\\\app_icon.ico" in (ROOT / "windows/runner/Runner.rc").read_text(encoding="utf-8")

count = sum(len(re.findall(r"\btest(?:Widgets)?\(", file.read_text(encoding="utf-8")))
            for file in files if file.name.endswith("_test.dart"))
print(f"PASS: {len(files)} Dart files have resolvable local imports; domain boundaries checked.")
print("PASS: Android XML parses, release manifest has no permissions and disables automatic backup.")
print(f"PASS: Launcher artwork present at every density and referenced by both platforms "
      f"(Windows icon carries {entries} sizes).")
print(f"INVENTORY: {count} declared Dart/Flutter tests. NOT executed by this audit.")
