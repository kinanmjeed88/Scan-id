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

adb exec-out run-as iq.scanid.scan_id cat files/native-jpeg-crop-metrics.log \
  > diagnostics/android-instrumentation/native-jpeg-crop-metrics.log \
  || echo "::warning title=android-crop-metrics::instrumentation metrics file was not available to pull"

exit "$gradle_status"
