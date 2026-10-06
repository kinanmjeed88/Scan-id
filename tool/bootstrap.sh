#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
command -v flutter >/dev/null || { echo 'Flutter 3.35.7 is required.' >&2; exit 1; }
# Without --overwrite, Flutter preserves our existing lib/, tests and pubspec.
if [[ ! -f android/app/build.gradle.kts || ! -f windows/CMakeLists.txt ]]; then
  flutter create --no-pub --platforms=android,windows --org iq.scanid --project-name scan_id .
fi
flutter pub get --enforce-lockfile
