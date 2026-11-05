#!/usr/bin/env bash
# Secretless R8/AOT regression for PRs. Flutter host-driven integration tests
# need a VM service, so this runs PROFILE AOT with R8 explicitly enabled through
# the CI-only scanIdR8Profile Gradle property. It exercises the same Java/JNI
# shrinking contract that broke the signed release build. A fresh, one-day test
# key signs only the local integration-test APK, which is never uploaded.
# Production signing secrets and the production certificate pin are neither read
# nor changed. The normal missing-signing guard runs BEFORE this script in
# verify.yml and must still fail without credentials.
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
  -dname 'CN=Scan ID disposable R8 regression' \
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
# The preceding instrumentation step may have installed a debug-signed package
# with the same applicationId. Remove it so the disposable test signature can be
# installed cleanly; this emulator is disposable and holds no user data.
adb -s "$serial" uninstall iq.scanid.scan_id >/dev/null 2>&1 || true
adb -s "$serial" logcat -c
set +e
KEYSTORE_BASE64="$(base64 -w 0 "$keystore")" \
KEYSTORE_STORE_PASSWORD="$password" \
KEYSTORE_KEY_ALIAS=scan-id-r8-test \
KEYSTORE_KEY_PASSWORD="$password" \
EXPECTED_CERT_SHA256="$fingerprint" \
REQUIRE_RELEASE_SIGNING=true \
ORG_GRADLE_PROJECT_scanIdR8Profile=true \
timeout 1200 flutter test integration_test/release_intake_test.dart \
  -d "$serial" --flavor scanid --profile --reporter expanded \
  > diagnostics/android-release/intake.log 2>&1
status=$?
set -e
adb -s "$serial" logcat -d -v threadtime \
  > diagnostics/android-release/logcat.log 2>/dev/null || true
grep -E 'FATAL EXCEPTION|Fatal signal|JNI DETECTED ERROR|UnsatisfiedLinkError|NoSuchMethodError|NoSuchFieldError|All tests passed|Some tests failed' \
  diagnostics/android-release/logcat.log \
  > diagnostics/android-release/native-summary.log 2>/dev/null || true

# Prove that R8 actually ran and preserved the names JNI looks up. The test
# alone could otherwise be mislabeled while running an unshrinking JVM build.
mapping=build/app/outputs/mapping/scanidProfile/mapping.txt
if [[ ! -s "$mapping" ]]; then
  echo '::error title=android-r8-mapping::Profile R8 mapping is missing; this is not proof of a minimized build.' >&2
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

tail -n 60 diagnostics/android-release/intake.log
if (( status != 0 )); then
  cat diagnostics/android-release/native-summary.log >&2 || true
  # The emulator action does not turn ordinary stdout into check annotations.
  # Publish a bounded, escaped log tail so an API-only client can diagnose the
  # failure even when the artifact/log blob hosts are unreachable.
  detail="$(tail -c 3000 diagnostics/android-release/intake.log | sed -e 's/%/%25/g' -e 's/\r/%0D/g' | tr '\n' '~')"
  echo "::error title=android-release-intake-log::exit=$status $detail" >&2
  echo "::error title=android-release-intake::R8/AOT intake regression failed (exit=$status). See the uploaded log and mapping." >&2
  exit "$status"
fi
grep -Fq 'All tests passed!' diagnostics/android-release/intake.log || {
  echo '::error title=android-release-intake::No successful test tally was reported.' >&2
  exit 1
}
echo '::notice title=android-release-intake::R8/profile-AOT native inference, import, reopen and retry passed with a disposable test key; no release artifact was published.'
