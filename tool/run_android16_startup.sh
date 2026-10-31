#!/usr/bin/env bash
# Launch the diagnostic build on an Android 16 (API 36) emulator and keep the
# evidence the recorder writes for a device with no computer attached.
#
# The emulator here is x86_64, so this is not ARM64 evidence. It answers a
# narrower question: does the startup path that reports an exit after the splash
# screen still reach the first home frame on the Android version the reporter
# runs, and does the phone-only report actually appear in Downloads with every
# stage recorded?
set -euo pipefail

mkdir -p diagnostics/android16

apk="$(find startup-apk -name '*.apk' -print -quit)"
if [[ -z "$apk" ]]; then
  echo "::error title=android16-startup::The diagnostic APK artifact was empty." >&2
  exit 1
fi

adb wait-for-device
adb logcat -c
adb install -r "$apk" > diagnostics/android16/install.log 2>&1
adb shell monkey -p iq.scanid.scan_id.startupdiag \
  -c android.intent.category.LAUNCHER 1 > diagnostics/android16/launch.log 2>&1 || true

reached_home=0
for _ in $(seq 1 30); do
  adb logcat -d -v threadtime > diagnostics/android16/startup.log 2>/dev/null || true
  if grep -Fq 'app.first_home_frame' diagnostics/android16/startup.log; then
    reached_home=1
    break
  fi
  sleep 2
done

grep -E 'ScanIdStartup|ScanIdProbe|FATAL EXCEPTION|AndroidRuntime|Fatal signal|UnsatisfiedLinkError|OutOfMemoryError|ExceptionInInitializerError' \
  diagnostics/android16/startup.log > diagnostics/android16/startup-summary.log 2>/dev/null || true

if [[ "$reached_home" -ne 1 ]]; then
  cat diagnostics/android16/startup-summary.log || true
  echo "::error title=android16-startup::The diagnostic build did not reach the first home frame on Android 16." >&2
  exit 1
fi

# The report must land where a person can reach it without a computer.
adb shell ls -l /sdcard/Download/ScanId > diagnostics/android16/report-listing.log 2>&1 || true
report="$(adb shell ls /sdcard/Download/ScanId 2>/dev/null | tr -d '\r' | head -n 1)"
if [[ -z "$report" ]]; then
  cat diagnostics/android16/report-listing.log || true
  echo "::error title=startup-report::No report file was written to Download/ScanId." >&2
  exit 1
fi
adb shell cat "/sdcard/Download/ScanId/$report" > diagnostics/android16/report.txt

missing=()
for marker in \
  'probe.installed' \
  'native.preflight.abi' \
  'native.preflight.ort_environment' \
  'flutter_plugins.registration.complete' \
  'historical process exits' \
  'app.first_home_frame'; do
  if ! grep -Fq "$marker" diagnostics/android16/report.txt; then
    missing+=("$marker")
  fi
done
if (( ${#missing[@]} )); then
  sed -n '1,160p' diagnostics/android16/report.txt || true
  echo "::error title=startup-report::The report is missing: ${missing[*]}" >&2
  exit 1
fi

summary="$(grep -E 'native.preflight|pageSize|supportedAbis|versionName' diagnostics/android16/report.txt \
  | head -n 8 | tr '\n' '~' | sed -e 's/%/%25/g' -e 's/\r/%0D/g')"
echo "::notice title=startup-report-android16::The diagnostic build reached the first home frame on API 36 (x86_64) and wrote $report :: $summary"
