#!/usr/bin/env bash
# Report which builds in the Gradle tree received the fallback plugin repositories.
#
# Evidence, never a gate: this script always exits 0. It annotates what the init
# script (tool/gradle/plugin-repositories.init.gradle) reported and warns when the
# evidence is missing or incomplete -- silence must not read as success. The
# Actions log blob store is unreachable for API-only clients, so the annotations
# are what makes the state of the fallback visible.
#
# Usage: tool/report_gradle_plugin_repositories.sh [log file ...]
# The optional log files are a cross-check only: lines that reached a build log
# are not proof that the fallback was installed for that build, so every check is
# made against the report file the init script wrote.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p diagnostics

marker='[scan-id-plugin-repos]'
report="${GRADLE_USER_HOME:-$HOME/.gradle}/scan-id-gradle-plugin-repositories.log"
out=diagnostics/gradle-plugin-repositories.txt
logs=diagnostics/gradle-plugin-repositories-from-logs.txt

{
  echo "== Gradle plugin repositories of every build in the tree =="
  echo "report file: $report"
  if [[ -f "$report" ]]; then
    cat "$report"
  else
    echo "MISSING: no report file at $report"
  fi
} | tr -d '\r' > "$out"

{
  echo "== the same lines as printed by the build (cross-check only) =="
  for log in "$@"; do
    [[ -f "$log" ]] || continue
    echo "-- $log"
    grep -ho '\[scan-id-plugin-repos\].*' "$log" || true
  done
} | tr -d '\r' > "$logs"

cat "$out" "$logs"

lines="$(grep -cF "$marker" "$out" || true)"
if [[ "${lines:-0}" -eq 0 ]]; then
  echo "::warning title=gradle-plugin-repos::the init script reported nothing for this run, so the fallback plugin repositories are unproven (see $out)" >&2
  exit 0
fi
if grep -q 'failed=' "$out"; then
  echo "::warning title=gradle-plugin-repos::the init script reported a failure while configuring repositories; the fallback may not be installed (see $out)" >&2
fi
if ! grep -q 'flutter_tools/gradle' "$out"; then
  echo "::warning title=gradle-plugin-repos::the Flutter tools build (project :gradle, the build that failed in run 38815652328) did not report the plugin-repository fallback; it would resolve from plugins.gradle.org/m2 alone" >&2
fi

grep -F "$marker" "$out" | sort -u | head -6 > diagnostics/gradle-plugin-repositories-summary.txt || true
while IFS= read -r line; do
  echo "::notice title=gradle-plugin-repos::${line}"
done < diagnostics/gradle-plugin-repositories-summary.txt
