$ErrorActionPreference = 'Stop'
Set-Location (Join-Path $PSScriptRoot '..')
if (-not (Get-Command flutter -ErrorAction SilentlyContinue)) {
  throw 'Flutter 3.35.7 is required.'
}
# Do not add --overwrite: existing application code must be preserved.
if (-not (Test-Path 'android/app/build.gradle.kts') -or -not (Test-Path 'windows/CMakeLists.txt')) {
  flutter create --no-pub --platforms=android,windows --org iq.scanid --project-name scan_id .
  if ($LASTEXITCODE -ne 0) { throw 'Native runner generation failed.' }
}
flutter pub get --enforce-lockfile
if ($LASTEXITCODE -ne 0) { throw 'Dependency resolution failed.' }
