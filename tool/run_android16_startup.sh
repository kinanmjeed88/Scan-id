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

# Two reports are expected: one written at launch and one carrying this run's
# stage marks, which Dart publishes when its first frame is up. That publish is
# asynchronous, so the folder is polled instead of pulled immediately.
for _ in $(seq 1 25); do
  if [[ "$(adb shell ls /sdcard/Download/ScanId 2>/dev/null | wc -l)" -ge 2 ]]; then
    break
  fi
  sleep 1
done

# The report must land where a person can reach it without a computer. Every
# launch writes one at start ("previous-run") and one once a frame is up, so all
# of them are pulled and searched: the stage marks of a run that died are carried
# into the next launch's report through the app-private log.
adb shell ls -lt /sdcard/Download/ScanId > diagnostics/android16/report-listing.log 2>&1 || true
rm -rf diagnostics/android16/reports
if ! adb pull /sdcard/Download/ScanId diagnostics/android16/reports > diagnostics/android16/report-pull.log 2>&1; then
  cat diagnostics/android16/report-listing.log || true
  echo "::error title=startup-report::No report file was written to Download/ScanId." >&2
  exit 1
fi
mapfile -t reports < <(find diagnostics/android16/reports -type f -name '*.txt' ! -name 'report-listing.log' | sort)
if (( ${#reports[@]} == 0 )); then
  cat diagnostics/android16/report-listing.log || true
  echo "::error title=startup-report::The Download/ScanId folder held no report file." >&2
  exit 1
fi

missing=()
for marker in \
  'probe.installed' \
  'native.preflight.abi' \
  'native.preflight.ort_environment' \
  'flutter_plugins.registration.complete' \
  'historical process exits' \
  'app.first_home_frame'; do
  if ! grep -Fq "$marker" "${reports[@]}"; then
    missing+=("$marker")
  fi
done
# Bounded, secretless excerpt in the annotation channel: the artifact store is
# not always reachable, and an annotation is.
excerpt="$(grep -hE 'native.preflight|pageSize|supportedAbis|versionName|probe.installed|registration|first_home_frame' "${reports[@]}" \
  | head -n 14 | tr '\n' '~' | sed -e 's/%/%25/g' -e 's/\r/%0D/g')"
if (( ${#missing[@]} )); then
  echo "::error title=startup-report::The reports are missing: ${missing[*]} :: $excerpt" >&2
  exit 1
fi
echo "::notice title=startup-report-android16::${#reports[@]} report(s), first home frame reached on API 36 (x86_64) :: $excerpt"
