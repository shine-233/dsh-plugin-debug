[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [ValidateSet('doctor', 'start', 'diagnostics', 'plugin-health', 'snapshot', 'restore', 'workspace-list', 'workspace-snapshot', 'workspace-restore', 'session-history', 'session-fork', 'known-good-list', 'known-good-save', 'known-good-restore', 'known-good-fixture', 'plugin-enable', 'plugin-disable', 'repair-plan', 'repair-assist', 'self-repair', 'repair-apply', 'repair-revert', 'trace-contract', 'trace-eval', 'trace-live', 'trace-baseline', 'trace-autopsy', 'live-api-fixture', 'trace-autopsy-fixture', 'crash-fixture', 'runtime-supervisor-fixture', 'incident-capture', 'incident-correlation', 'repro-export', 'context-doctor', 'security-audit', 'session-health', 'fail-log', 'provenance', 'pointer-evidence')]
  [string]$Action,
  [Parameter(ValueFromRemainingArguments = $true)]
  [object[]]$Remaining
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$entry = Join-Path $PSScriptRoot 'DSH-Provenance.ps1'
if (-not (Test-Path -LiteralPath $entry -PathType Leaf)) {
  throw "Debug entrypoint is missing: $entry"
}

# Keep the public UX short while preserving the complete, tested action surface
# in the merged dispatcher. Remaining arguments are forwarded verbatim so all
# existing diagnostics and recovery workflows remain available.
& $entry -Action $Action @Remaining
exit $LASTEXITCODE
