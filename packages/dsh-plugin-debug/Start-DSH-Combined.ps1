[CmdletBinding()]
param()

# Single-package entry point for the optional Kimi/Codex overlay. The overlay
# is loaded by the same combined debug launcher; it is an optional provider
# overlay, not another runtime plugin.
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
  @('-EnableAgents', '-EnableCrashGuard', '-KeepAlive')
} else {
  @('-Profile', 'debug', '-EnableAgents', '-EnableCrashGuard', '-KeepAlive')
}
& powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $target @defaults @forwarded
exit $LASTEXITCODE
