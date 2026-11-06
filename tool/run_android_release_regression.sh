#!/usr/bin/env bash
# Actual signed Release R8 regression. Android instrumentation receives the Dart
# result over a test-only MethodChannel, so no VM service, Profile substitute, or
# integration_test dev plugin is needed in the Release package. A fresh one-day
# test key signs this local test build; no production secret is read and no APK
# is uploaded. verify.yml's missing-production-signing guard runs BEFORE this.
set -euo pipefail

command -v keytool >/dev/null || { echo 'keytool (JDK 17) is required.' >&2; exit 1; }
command -v openssl >/dev/null || { echo 'openssl is required for a disposable test key.' >&2; exit 1; }
serial="${ANDROID_SERIAL:-emulator-5554}"
mkdir -p diagnostics/android-release
signing_dir="$(mktemp -d "${RUNNER_TEMP:-/tmp}/scan-id-r8-test-key.XXXXXX")"
trap 'rm -rf "$signing_dir"' EXIT
keystore="$signing_dir/test.p12"
password="$(openssl rand -hex 32)"
# No set -x, no password on stdout, and no persistent key material.
keytool -genkeypair -keystore "$keystore" -storetype PKCS12 \
  -alias scan-id-r8-test -keyalg RSA -keysize 2048 -validity 1 \
  -dname 'CN=Scan ID disposable Release regression' \
  -storepass "$password" -keypass "$password" \
  > "$signing_dir/keytool.log" 2>&1 || {
    echo '::error title=android-r8-test-key::Could not create the disposable test keystore.' >&2
    exit 1
  }
fingerprint="$(keytool -list -v -keystore "$keystore" -storepass "$password" \
  | awk '/SHA256:/ {print $2; exit}' | tr -d ':' | tr 'A-F' 'a-f')"
[[ "$fingerprint" =~ ^[0-9a-f]{64}$ ]] || {
  echo '::error title=android-r8-test-key::No valid test certificate fingerprint.' >&2
  exit 1
}

timeout 60 adb -s "$serial" wait-for-device
# The preceding debug instrumentation may have installed the same applicationId
# with a different certificate. This disposable emulator holds no user data.
adb -s "$serial" uninstall iq.scanid.scan_id >/dev/null 2>&1 || true
adb -s "$serial" logcat -c
target="$PWD/integration_test/release_intake_main.dart"
export KEYSTORE_BASE64="$(base64 -w 0 "$keystore")"
export KEYSTORE_STORE_PASSWORD="$password"
export KEYSTORE_KEY_ALIAS=scan-id-r8-test
export KEYSTORE_KEY_PASSWORD="$password"
export EXPECTED_CERT_SHA256="$fingerprint"
export REQUIRE_RELEASE_SIGNING=true

set +e
timeout 900 flutter build apk --release --flavor scanid \
  --target "$target" > diagnostics/android-release/intake.log 2>&1
status=$?
if (( status == 0 )); then
  (cd android && timeout 1500 ./gradlew :app:connectedScanidReleaseAndroidTest \
    --no-daemon --stacktrace --console=plain \
    -PscanIdReleaseIntakeTest=true \
    -Ptarget="$target" \
    -Ptarget-platform=android-x64 \
    -Pandroid.testInstrumentationRunnerArguments.class=iq.scanid.scan_id.ReleaseIntakeInstrumentationTest) \
    >> diagnostics/android-release/intake.log 2>&1
  status=$?
fi
set -e

adb -s "$serial" logcat -d -v threadtime \
  > diagnostics/android-release/logcat.log 2>/dev/null || true
grep -E 'ScanIdReleaseIntake|FATAL EXCEPTION|Fatal signal|JNI DETECTED ERROR|UnsatisfiedLinkError|NoSuchMethodError|NoSuchFieldError|Tests on|FAILURE:' \
  diagnostics/android-release/logcat.log \
  > diagnostics/android-release/native-summary.log 2>/dev/null || true

# Require a real successful JUnit case, not merely Gradle exit zero.
if python3 - <<'PY' > diagnostics/android-release/junit-summary.txt
from pathlib import Path
import xml.etree.ElementTree as ET
name = 'iq.scanid.scan_id.ReleaseIntakeInstrumentationTest'
cases = []
for path in Path('build/app/outputs/androidTest-results/connected').rglob('TEST-*.xml'):
    try:
        root = ET.parse(path).getroot()
    except (ET.ParseError, OSError):
        continue
    cases.extend(case for case in root.iter('testcase') if case.get('classname') == name)
failed = sum(any(child.tag in {'failure', 'error', 'skipped'} for child in case) for case in cases)
print(f'releaseIntakeTests={len(cases)} failuresOrSkips={failed}')
if len(cases) != 1 or failed:
    raise SystemExit(1)
PY
then
  junit_status=0
else
  junit_status=$?
fi
if (( junit_status != 0 )); then status=1; fi

# Prove the actual Release R8 transformation preserved the JNI name contract.
mapping=build/app/outputs/mapping/scanidRelease/mapping.txt
if [[ ! -s "$mapping" ]]; then
  echo '::error title=android-r8-mapping::Release R8 mapping is missing; this is not proof of a minimized build.' >&2
  status=1
else
  cp "$mapping" diagnostics/android-release/mapping.txt
  for class in OrtEnvironment OrtSession OnnxTensor OnnxValue TensorInfo NodeInfo; do
    if ! grep -Fq "ai.onnxruntime.$class -> ai.onnxruntime.$class:" "$mapping"; then
      echo "::error title=android-r8-mapping::JNI class was not preserved: $class" >&2
      status=1
    fi
  done
fi

# A stack trace tail alone can miss R8's actual diagnostic. Publish the named
# failure lines too, bounded to the check-annotation limit.
summary="$(grep -E 'FAILURE:|What went wrong|Execution failed|Caused by:|ERROR:|Missing class|^e: |error:|> Task .*FAILED' diagnostics/android-release/intake.log | head -n 45 | head -c 3000 | sed -e 's/%/%25/g' -e 's/\r/%0D/g' | tr '\n' '~')"
if [[ -n "$summary" ]]; then
  echo "::error title=android-release-intake-summary::$summary" >&2
fi
tail -n 80 diagnostics/android-release/intake.log
cat diagnostics/android-release/junit-summary.txt
if (( status != 0 )); then
  cat diagnostics/android-release/native-summary.log >&2 || true
  detail="$(tail -c 6000 diagnostics/android-release/intake.log | sed -e 's/%/%25/g' -e 's/\r/%0D/g' | tr '\n' '~')"
  echo "::error title=android-release-intake-log::exit=$status $detail" >&2
  echo "::error title=android-release-intake::Signed Release R8 intake regression failed (exit=$status). See uploaded evidence." >&2
  exit "$status"
fi
echo '::notice title=android-release-intake::Actual signed Release/AOT native inference, import, reopen and retry passed with a disposable test key; no APK was published.'
