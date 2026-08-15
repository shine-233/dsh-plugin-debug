[CmdletBinding()]
param()

# Start the bundled DSH runtime with the debug plugin, Crash Guard and the
# bounded runtime supervisor enabled. The caller may append any normal
# Start-DSH.ps1 arguments (for example -Port, -Profile or -NoBrowser).
$target = Join-Path $PSScriptRoot 'tools\Start-DSH.ps1'
if (-not (Test-Path -LiteralPath $target -PathType Leaf)) {
  throw "debug launcher is missing: $target"
}

$forwarded = @($args)
$hasProfile = $false
foreach ($argument in $forwarded) {
  if ([string]$argument -ieq '-Profile') { $hasProfile = $true; break }
}
$defaults = if ($hasProfile) {
  @('-EnableCrashGuard', '-KeepAlive')
} else {
  @('-Profile', 'debug', '-EnableCrashGuard', '-KeepAlive')
}
& powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $target @defaults @forwarded
exit $LASTEXITCODE
