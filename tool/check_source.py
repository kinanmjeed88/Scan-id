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
# The app is offline by design. Two permissions exist, both for the update flow a
# person starts on purpose: INTERNET reaches the release feed (without it every
# check dies in EACCES), REQUEST_INSTALL_PACKAGES lets the system installer
# accept a verified package. Everything else — camera, storage, media, location —
# must stay undeclared, so the declared set is compared as a whole rather than
# searched for a few names someone happened to think of.
RELEASE_PERMISSIONS = {
    "android.permission.INTERNET",
    "android.permission.REQUEST_INSTALL_PACKAGES",
}
kotlin = "\n".join(
    path.read_text(encoding="utf-8")
    for path in (ROOT / "android/app/src/main/kotlin").rglob("*.kt")
)
declared = {item.get(android + "name") for item in manifest.findall("uses-permission")}
assert declared == RELEASE_PERMISSIONS, f"unexpected release permissions: {sorted(declared)}"
# A provider the manifest names but no Kotlin class defines is a crash at install
# time (ClassNotFoundException), which no Dart test can see.
authorities = set()
for node in app.findall("provider"):
    name = node.get(android + "name").rsplit(".", 1)[-1]
    assert f"class {name} :" in kotlin, f"{name} has no Kotlin class"
    resource = node.find("meta-data").get(android + "resource")
    authority = node.get(android + "authorities")
    # A shared authority would let one feature read another feature's files, so
    # every provider gets its own suffix and its own single declared directory.
    assert authority.startswith("${applicationId}."), f"{name}: authorities must be app-scoped"
    authorities.add(authority.rsplit(".", 1)[-1])
    paths = ROOT / f"android/app/src/main/res/xml/{resource.removeprefix('@xml/')}.xml"
    assert paths.is_file(), f"{name}: {resource} has no file"
    # Every provider is scoped to one directory of its own and is not exported,
    # so a grant can only ever name the files that feature wrote.
    assert node.get(android + "exported") == "false", f"{name} must stay unexported"
    assert len(ET.parse(paths).getroot()) == 1, f"{name}: expected exactly one declared path"
assert len(authorities) == len(
    app.findall("provider")
), "two providers share one authority"
# The install handoff works only while three files agree on one directory name.
# A rename on one side alone would either leave the installer refusing a package
# it may not read, or widen the grant beyond the update feature.
UPDATE_DIRECTORY = "scan-updates"
update_paths = (ROOT / "android/app/src/main/res/xml/update_paths.xml").read_text(
    encoding="utf-8"
)
assert f'path="{UPDATE_DIRECTORY}/"' in update_paths, "update_paths.xml moved"
assert f'DIRECTORY = "{UPDATE_DIRECTORY}"' in kotlin, "UpdateInstaller.kt moved"
ota = (ROOT / "lib/application/ota_update.dart").read_text(encoding="utf-8")
assert f"updateDirectoryName = '{UPDATE_DIRECTORY}'" in ota, "the Dart side moved"
assert "updateDownloadDirectory" in ota, "the update directory has no resolver"
# An install permission is only defensible while the code that consumes it can name
# the publisher: the digest published next to a file proves arrival, not authorship,
# because both come from the same release. So the pin, the compiled constant and the
# Kotlin comparison must stay one chain — otherwise the shipped app trusts its feed.
PINS = {}
for name in ("release-management.yml", "android-signed-release.yml"):
    text = (ROOT / ".github/workflows" / name).read_text(encoding="utf-8")
    found = re.findall(r"EXPECTED_CERT_SHA256:\s*'([0-9a-f]{64})'", text)
    assert found, f"{name} no longer pins a release certificate fingerprint"
    PINS[name] = set(found)
assert PINS["release-management.yml"] == PINS["android-signed-release.yml"], (
    "the release workflows pin different certificates: "
    f"{sorted(PINS['release-management.yml'])} vs {sorted(PINS['android-signed-release.yml'])}"
)
gradle = (ROOT / "android/app/build.gradle.kts").read_text(encoding="utf-8")
# AGP 8 generates BuildConfig only on request, so a dropped flag would break the
# build; a dropped field would break it later, on a user's phone, silently.
assert "buildConfig = true" in gradle, "BuildConfig is not generated, so the pin cannot be read"
assert '"EXPECTED_UPDATE_CERT_SHA256"' in gradle, "the certificate pin is not compiled into the app"
assert 'requestsReleasePackage && expectedCertSha256.isEmpty()' in gradle, (
    "a release could be packaged with no publisher anchor at all"
)
for needed in (
    "getPackageArchiveInfo",
    "GET_SIGNING_CERTIFICATES",
    "apkContentsSigners",
    "GET_SIGNATURES",
    "BuildConfig.EXPECTED_UPDATE_CERT_SHA256",
    "publisherRefusal",
):
    assert needed in kotlin, f"the installer lost the publisher check ({needed})"
# Order is the contract: the answer must be read before the intent is built, and a
# refusal must be decided before any permission screen opens. No host test can see
# this, and a plausible-looking edit can silently break it.
ORDER = (
    "val packageFile = verifiedFile(raw)",
    "val refusal = publisherRefusal(packageFile)",
    "if (refusal != null)",
    '"signature"',
    "startInstall(packageFile, reply)",
)
positions = []
for step in ORDER:
    assert step in kotlin, f"the install handoff no longer contains: {step!r}"
    positions.append(kotlin.index(step))
assert positions == sorted(positions), "the publisher check no longer runs before the handoff"
# A refusal the person cannot read is a bug in the one place a bug must not be.
installer_dart = (ROOT / "lib/application/update_installer.dart").read_text(encoding="utf-8")
assert "'signature' =>" in installer_dart, "the publisher refusal has no sentence to show"

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
print("PASS: Android XML parses; the release manifest declares only the two update "
      "permissions and every provider is class-backed, unexported and single-path.")
print("PASS: the release certificate pin is declared once, compiled into the build, "
      "and compared against the package signer before the installer is offered it.")
print(f"PASS: Launcher artwork present at every density and referenced by both platforms "
      f"(Windows icon carries {entries} sizes).")
print(f"INVENTORY: {count} declared Dart/Flutter tests. NOT executed by this audit.")
