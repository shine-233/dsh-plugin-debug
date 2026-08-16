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
$hasPort = $false
foreach ($argument in $forwarded) {
  if ([string]$argument -ieq '-Profile' -or [string]$argument -match '^-Profile=') { $hasProfile = $true }
  if ([string]$argument -ieq '-Port' -or [string]$argument -match '^-Port=') { $hasPort = $true }
}
$defaults = if ($hasProfile) {
  @('-EnableCrashGuard', '-KeepAlive')
} else {
  @('-Profile', 'debug', '-Port', '3081', '-EnableCrashGuard', '-KeepAlive')
}
if ($hasProfile -and -not $hasPort) { $defaults = @($defaults + '-Port' + '3081') }
& powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $target @defaults @forwarded
exit $LASTEXITCODE
