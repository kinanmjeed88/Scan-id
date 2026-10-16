#!/usr/bin/env bash
# Install the repository's Gradle init scripts into the Gradle user home.
#
# Why an init script in GRADLE_USER_HOME/init.d and not `--init-script`:
# `flutter build apk` starts Gradle for two builds -- the root build in android/
# and the included Flutter tools build that android/settings.gradle.kts adds
# through `pluginManagement { includeBuild(...) }` -- and Flutter does not forward
# extra Gradle arguments. Init scripts placed in GRADLE_USER_HOME/init.d are
# applied to every build in the tree, including included builds (Gradle applies
# them to buildSrc builds too since 8.0), which is the only hook that reaches the
# Flutter tools build. See tool/gradle/plugin-repositories.init.gradle for the
# failure (run 38815652328) this protects against.
#
# The copy is verified by digest: the file Gradle loads is the installed one, so a
# truncated or partial copy must never be mistaken for an installed fallback.
# Windows jobs do not use Gradle and do not call this script.
set -euo pipefail
cd "$(dirname "$0")/.."

gradle_user_home="${GRADLE_USER_HOME:-$HOME/.gradle}"
init_dir="$gradle_user_home/init.d"
report_file="$gradle_user_home/scan-id-gradle-plugin-repositories.log"
mkdir -p "$init_dir" diagnostics
# A run must report only what this run's builds did: a stale report from an
# earlier build (or a restored cache) would read as proof that never happened.
rm -f "$report_file"

{
  echo "== Gradle init scripts =="
  echo "GRADLE_USER_HOME=$gradle_user_home"
  echo "installed into=$init_dir"
  echo "fallback report=$report_file"
} | tee diagnostics/gradle-init-scripts.txt

installed=0
for source in tool/gradle/*.init.gradle; do
  if [[ ! -f "$source" ]]; then
    echo "::error title=gradle-init::tool/gradle/*.init.gradle matched no file; the CI fallback repositories would not be installed" >&2
    exit 1
  fi
  target="$init_dir/scan-id-$(basename "$source")"
  cp -- "$source" "$target"
  # Digest equality, not exit status: a partial write is the failure mode this
  # check exists for.
  source_sha="$(sha256sum < "$source" | awk '{print $1}')"
  target_sha="$(sha256sum < "$target" | awk '{print $1}')"
  if [[ "$source_sha" != "$target_sha" ]]; then
    echo "::error title=gradle-init::the installed copy of $source does not match the repository file" >&2
    exit 1
  fi
  echo "installed $(basename "$source") -> $target (sha256 $target_sha)"
  installed=$((installed + 1))
done

echo "gradle loads every *.init.gradle in $init_dir (alphabetically) for each build in the tree: $installed script(s) installed"
