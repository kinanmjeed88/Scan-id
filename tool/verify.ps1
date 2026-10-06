$ErrorActionPreference = 'Stop'
Set-Location (Join-Path $PSScriptRoot '..')
flutter pub get --enforce-lockfile
if ($LASTEXITCODE -ne 0) { throw 'Dependency resolution failed.' }
dart format --output=none --set-exit-if-changed .
if ($LASTEXITCODE -ne 0) { throw 'Dart formatting failed.' }
flutter analyze --fatal-infos
if ($LASTEXITCODE -ne 0) { throw 'Flutter analysis failed.' }
flutter test --coverage
if ($LASTEXITCODE -ne 0) { throw 'Flutter tests failed.' }
