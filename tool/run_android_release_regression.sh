#!/usr/bin/env bash
# Actual signed Release R8 regression. Build/install/launch the Release APK with
# a disposable one-day test key, then require the Dart probe's result marker in
# logcat and the Release R8 mapping. No VM service, Profile substitute,
# androidTest orchestrator, production secret, or uploaded APK is involved.
# verify.yml's missing-production-signing guard runs BEFORE this script.
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
timeout 30 adb -s "$serial" uninstall iq.scanid.scan_id >/dev/null 2>&1 || true
timeout 20 adb -s "$serial" logcat -c || true
target="$PWD/integration_test/release_intake_main.dart"
export KEYSTORE_BASE64="$(base64 -w 0 "$keystore")"
export KEYSTORE_STORE_PASSWORD="$password"
export KEYSTORE_KEY_ALIAS=scan-id-r8-test
export KEYSTORE_KEY_PASSWORD="$password"
export EXPECTED_CERT_SHA256="$fingerprint"
export REQUIRE_RELEASE_SIGNING=true

set +e
timeout 900 flutter build apk --release --flavor scanid --target "$target" \
  > diagnostics/android-release/intake.log 2>&1
status=$?
apk=build/app/outputs/flutter-apk/app-scanid-release.apk
if (( status == 0 )) && [[ ! -f "$apk" ]]; then
  echo 'Release APK was not produced.' >> diagnostics/android-release/intake.log
  status=1
fi
if (( status == 0 )); then
  timeout 180 adb -s "$serial" install -r "$apk" >> diagnostics/android-release/intake.log 2>&1
  status=$?
fi
if (( status == 0 )); then
  timeout 60 adb -s "$serial" shell am start -W -n iq.scanid.scan_id/.MainActivity \
    >> diagnostics/android-release/intake.log 2>&1
  status=$?
fi
marker=''
if (( status == 0 )); then
  deadline=$((SECONDS + 480))
  while (( SECONDS < deadline )); do
    timeout 20 adb -s "$serial" logcat -d -v threadtime \
      > diagnostics/android-release/logcat.log 2>/dev/null || true
    marker="$(grep -F 'SCANID_RELEASE_INTAKE_RESULT ' diagnostics/android-release/logcat.log | tail -n 1 || true)"
    [[ -n "$marker" ]] && break
    if grep -Eq 'FATAL EXCEPTION|Fatal signal' diagnostics/android-release/logcat.log; then
      break
    fi
    sleep 5
  done
  [[ -n "$marker" ]] || status=1
fi
set -e

timeout 30 adb -s "$serial" logcat -d -v threadtime \
  > diagnostics/android-release/logcat.log 2>/dev/null || true
grep -E 'SCANID_RELEASE_INTAKE_RESULT|FATAL EXCEPTION|Fatal signal|JNI DETECTED ERROR|UnsatisfiedLinkError|NoSuchMethodError|NoSuchFieldError' \
  diagnostics/android-release/logcat.log \
  > diagnostics/android-release/native-summary.log 2>/dev/null || true

# Require the probe's structured success evidence, not merely a launched app.
if python3 - <<'PY' > diagnostics/android-release/result-summary.txt
import json
from pathlib import Path
text = Path('diagnostics/android-release/logcat.log').read_text(errors='replace')
lines = [line.split('SCANID_RELEASE_INTAKE_RESULT ', 1)[1]
         for line in text.splitlines() if 'SCANID_RELEASE_INTAKE_RESULT ' in line]
if not lines:
    print('releaseIntakeResult=missing')
    raise SystemExit(1)
result = json.loads(lines[-1])
evidence = result.get('evidence') or {}
print(f"releaseIntakeResult={result.get('status')} imported={evidence.get('importedCount')} "
      f"assets={evidence.get('assetCount')} items={evidence.get('itemCount')} "
      f"docAlignerRuns={evidence.get('docAlignerRuns')}")
if result.get('status') != 'success':
    print(result.get('error'))
    raise SystemExit(1)
for key in ('importedCount', 'assetCount', 'itemCount'):
    if evidence.get(key) != 1:
        raise SystemExit(1)
if evidence.get('originalUnchanged') is not True or evidence.get('retryOriginalUnchanged') is not True:
    raise SystemExit(1)
phases = set(evidence.get('nativePhases') or [])
if not {'docquad-inference', 'docaligner-inference', 'ocr-inference'} <= phases:
    raise SystemExit(1)
if int(evidence.get('docAlignerRuns') or 0) < 1:
    raise SystemExit(1)
PY
then
  :
else
  status=1
fi

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

summary="$(grep -E 'FAILURE:|What went wrong|Execution failed|Caused by:|ERROR:|Missing class|^e: |error:|releaseIntakeResult=' diagnostics/android-release/intake.log diagnostics/android-release/result-summary.txt | head -n 40 | head -c 2500 | sed -e 's/%/%25/g' -e 's/\r/%0D/g' | tr '\n' '~')"
if [[ -n "$summary" ]]; then
  echo "::notice title=android-release-intake-summary::$summary" >&2
fi
tail -n 60 diagnostics/android-release/intake.log
cat diagnostics/android-release/result-summary.txt
if (( status != 0 )); then
  cat diagnostics/android-release/native-summary.log >&2 || true
  detail="$( { tail -c 1600 diagnostics/android-release/intake.log; echo; tail -c 1600 diagnostics/android-release/native-summary.log; } | sed -e 's/%/%25/g' -e 's/\r/%0D/g' | tr '\n' '~')"
  echo "::error title=android-release-intake-log::exit=$status $detail" >&2
  echo "::error title=android-release-intake::Signed Release R8 intake regression failed (exit=$status). See uploaded evidence." >&2
  exit "$status"
fi
# Capture the Release package itself. Until this step existed the workflow built a
# signed Release APK, installed it, and then discarded it, so the release package
# could never be measured and every release-size figure in the reports had to be
# carried over from an unrelated debug build. This is CI evidence under the
# ordinary artifact retention window, signed with the disposable one-day test key
# above; it is not a published release and carries no production certificate.
release_apk=diagnostics/android-release/scan-id-scanid-release.apk
cp "$apk" "$release_apk"
python3 - "$release_apk" > diagnostics/android-release/apk-summary.txt <<'PYAPK'
import hashlib
import sys
import zipfile

path = sys.argv[1]
with open(path, "rb") as handle:
    payload = handle.read()
digest = hashlib.sha256(payload).hexdigest()
print(f"releaseApkBytes={len(payload)}")
print(f"releaseApkSha256={digest}")
print(f"releaseApkMiB={len(payload) / 1048576:.1f}")

with zipfile.ZipFile(path) as bundle:
    entries = [(info, bundle.read(info.filename)) for info in bundle.infolist()]

stored = [info for info, _ in entries if info.compress_type == zipfile.ZIP_STORED]
deflated = [info for info, _ in entries if info.compress_type == zipfile.ZIP_DEFLATED]
print(f"entries={len(entries)} stored={len(stored)} deflated={len(deflated)}")
print(f"uncompressedBytes={sum(info.file_size for info, _ in entries)}")

natives = {}
for info, _ in entries:
    if info.filename.startswith("lib/") and info.filename.endswith(".so"):
        parts = info.filename.split("/")
        natives.setdefault(parts[1], []).append(
            (parts[2], info.file_size, info.compress_size)
        )
print(f"abis={','.join(sorted(natives)) or 'none'}")
for abi in sorted(natives):
    for name, raw, packed in sorted(natives[abi]):
        print(f"native {abi}/{name} raw={raw} packed={packed}")

for info, _ in entries:
    if info.filename.endswith(".onnx") or info.filename.endswith(".ort"):
        print(f"model {info.filename} raw={info.file_size} "
              f"packed={info.compress_size}")
PYAPK
cat diagnostics/android-release/apk-summary.txt

echo '::notice title=android-release-intake::Actual signed Release/AOT native inference, import, reopen and retry passed with a disposable test key; the Release package is attached as CI evidence only, not published.'
