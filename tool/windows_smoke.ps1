$ErrorActionPreference = 'Stop'
$bundle = (Resolve-Path 'build/windows/x64/runner/Release').Path
$originalLocal = $env:LOCALAPPDATA
$isolatedLocal = Join-Path $env:RUNNER_TEMP ('ScanIdSmoke-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $isolatedLocal | Out-Null
$env:LOCALAPPDATA = $isolatedLocal
$process = $null
try {
  $process = Start-Process -FilePath (Join-Path $bundle 'scan_id.exe') -WorkingDirectory $bundle -PassThru
  if ($process.WaitForExit(10000)) {
    throw "Windows app exited during startup with code $($process.ExitCode)."
  }
  $process.Refresh()
  if ($process.MainWindowHandle -eq 0) { throw 'No native window appeared.' }
  $database = Join-Path $isolatedLocal 'ScanId/scan_id/projects.db'
  if (-not (Test-Path $database)) { throw 'Startup did not open the local project database.' }
  Write-Output 'Windows release smoke passed: live native window and isolated local database after 10 seconds.'
  Write-Output 'This is a startup check, not a human/device interaction or printing test.'
} finally {
  if ($null -ne $process -and -not $process.HasExited) { Stop-Process -Id $process.Id -Force }
  $env:LOCALAPPDATA = $originalLocal
  # Only this test-owned temporary directory is removed.
  Remove-Item -Path $isolatedLocal -Recurse -Force
}
