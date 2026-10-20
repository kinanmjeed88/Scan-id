#!/usr/bin/env bash
set -euo pipefail

mkdir -p diagnostics/android-instrumentation
if [[ ! -x android/gradlew ]]; then
  echo "Flutter's Android build did not provide executable android/gradlew." \
    | tee diagnostics/android-instrumentation/connected-debug-android-test.log
  echo "::error title=android-gradle-wrapper::android/gradlew is missing or not executable"
  exit 1
fi
if [[ ! -f android/gradle/wrapper/gradle-wrapper.jar ]]; then
  echo "Flutter's Android build did not provide android/gradle/wrapper/gradle-wrapper.jar." \
    | tee diagnostics/android-instrumentation/connected-debug-android-test.log
  echo "::error title=android-gradle-wrapper::gradle-wrapper.jar is missing"
  exit 1
fi

set +e
(cd android && ./gradlew :app:connectedDebugAndroidTest --no-daemon --stacktrace --console=plain) \
  2>&1 | tee diagnostics/android-instrumentation/connected-debug-android-test.log
gradle_status=${PIPESTATUS[0]}
set -e

metrics_file=diagnostics/android-instrumentation/native-jpeg-crop-metrics.log
adb exec-out run-as iq.scanid.scan_id cat files/native-jpeg-crop-metrics.log \
  > "$metrics_file" \
  || echo "::warning title=android-crop-metrics::instrumentation metrics file was not available to pull"

test_report="$(python3 - <<'PY' 2>/dev/null || true
import glob
import xml.etree.ElementTree as ET

results = {}
paths = glob.glob(
    "build/app/outputs/androidTest-results/connected/debug/**/*.xml",
    recursive=True,
)
for path in paths:
    try:
        root = ET.parse(path).getroot()
    except (ET.ParseError, OSError):
        continue
    for case in root.iter("testcase"):
        name = f"{case.get('classname', '')}#{case.get('name', '')}"
        failures = [child for child in case if child.tag in ("failure", "error")]
        details = results.setdefault(name, [])
        for failure in failures:
            message = " ".join(failure.get("message", "").split())
            stack = " ".join((failure.text or "").split())[:500]
            details.append(f"{failure.tag}: {message}; {stack}")

failed = sum(bool(details) for details in results.values())
skipped = 0
for path in paths:
    try:
        root = ET.parse(path).getroot()
    except (ET.ParseError, OSError):
        continue
    skipped += sum(1 for case in root.iter("testcase") if any(c.tag == "skipped" for c in case))
print(f"androidTests={len(results)} failures={failed} skipped={skipped}")
for name, details in results.items():
    for detail in details:
        print(f"{name}: {detail}")
PY
)"

if [[ -s "$metrics_file" ]]; then
  metrics_report="$(awk '
    /^case=/ {
      count++
      if (index($0, "case=orientation-") == 1) orientations++
      if (index($0, "case=budget-16000000 ") == 1) full = $0
      if (index($0, "case=budget-16004000 ") == 1) over = $0
      if (index($0, "case=bounded-png-rejection ") == 1) bounded = $0
      if (index($0, "case=success-after-bounded-png-rejection ") == 1) recovery = $0
    }
    END {
      printf "cropMetrics=%d EXIFRegionCases=%d", count, orientations
      if (full != "") printf "; %s", full
      if (over != "") printf "; %s", over
      if (bounded != "") printf "; %s", bounded
      if (recovery != "") printf "; %s", recovery
    }
  ' "$metrics_file")"
else
  metrics_report="cropMetrics=unavailable"
fi

{
  printf 'commit=%s\nrun=%s\n' "${GITHUB_SHA:-unknown}" "${GITHUB_RUN_ID:-unknown}"
  printf '%s\n%s\n' "$test_report" "$metrics_report"
} > diagnostics/android-instrumentation/summary.txt

if (( gradle_status != 0 )); then
  gradle_summary="$(
    { grep -E '(^FAILURE:|^\* What went wrong:|^Execution failed for task|^> Task .*FAILED|^e: |error:|^Caused by:|^There were failing tests|^.*AssertionError)' \
        diagnostics/android-instrumentation/connected-debug-android-test.log || true; } \
      | tail -n 20
  )"
  details="$(printf '%s\n%s\n%s' "$test_report" "$metrics_report" "$gradle_summary" \
    | head -c 2600 | sed -e 's/%/%25/g' -e 's/\r/%0D/g' | tr '\n' '~')"
  echo "::error title=android-gradle-failure-summary::Gradle exit=$gradle_status; $details"
else
  details="$(printf '%s\n%s' "$test_report" "$metrics_report" \
    | head -c 2600 | sed -e 's/%/%25/g' -e 's/\r/%0D/g' | tr '\n' '~')"
  echo "::notice title=android-instrumentation-evidence::$details"
fi

exit "$gradle_status"
