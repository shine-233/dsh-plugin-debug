[CmdletBinding()]
param([switch]$KeepTemp)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Preserve the historical command name for local automation while keeping one
# canonical integration implementation. This is not a second product or test
# contract; it forwards the same optional inspection flag and exit code.
$canonical = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'Test-DSHPluginIntegration.ps1'
if (-not (Test-Path -LiteralPath $canonical -PathType Leaf)) {
  throw "Canonical integration test is missing: $canonical"
}

$arguments = @{ SkipCompatibility = $true }
if ($KeepTemp) { $arguments.KeepTemp = $true }
# Do not rely on environment inheritance across the staged Start-Process
# boundary. The explicit switch makes the compatibility wrapper one-way even
# when a published package is tested by another PowerShell process.
$previousSkip = $env:DSH_DEBUG_SKIP_COMPAT_INTEGRATION
$env:DSH_DEBUG_SKIP_COMPAT_INTEGRATION = '1'
& $canonical @arguments
$exitVariable = Get-Variable -Name LASTEXITCODE -ErrorAction SilentlyContinue
$childExitCode = if ($null -ne $exitVariable) { [int]$exitVariable.Value } else { $null }
if ($null -eq $previousSkip) { Remove-Item Env:DSH_DEBUG_SKIP_COMPAT_INTEGRATION -ErrorAction SilentlyContinue } else { $env:DSH_DEBUG_SKIP_COMPAT_INTEGRATION = $previousSkip }
if ($null -eq $childExitCode) {
  $childExitCode = if ($?) { 0 } else { 1 }
}
exit $childExitCode
