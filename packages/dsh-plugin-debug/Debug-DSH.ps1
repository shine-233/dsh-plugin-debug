[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [ValidateSet('doctor', 'start', 'diagnostics', 'plugin-health', 'snapshot', 'restore', 'workspace-list', 'workspace-snapshot', 'workspace-restore', 'session-history', 'session-fork', 'known-good-list', 'known-good-save', 'known-good-restore', 'known-good-fixture', 'plugin-enable', 'plugin-disable', 'repair-plan', 'repair-assist', 'self-repair', 'repair-apply', 'repair-revert', 'plugin-bisect-plan', 'plugin-dependency-graph', 'plugin-preflight', 'diagnostics-diff', 'trace-contract', 'trace-eval', 'trace-live', 'trace-baseline', 'trace-loop', 'trace-autopsy', 'live-api-fixture', 'trace-autopsy-fixture', 'trace-loop-fixture', 'crash-fixture', 'runtime-supervisor-fixture', 'incident-capture', 'incident-correlation', 'repro-export', 'context-doctor', 'security-audit', 'session-health', 'fail-log', 'provenance', 'pointer-evidence')]
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
# in the merged dispatcher. Parse remaining tokens into a named hashtable before
# splatting; an array splat would bind -Action and its value positionally.
$invokeArguments = @{}
$tokens = @($Remaining | ForEach-Object { if ($null -ne $_) { [string]$_ } })
$index = 0
while ($index -lt $tokens.Count) {
  $token = [string]$tokens[$index]
  $tokenMatch = [regex]::Match($token, '^-([A-Za-z][A-Za-z0-9]*)(?::(.*))?$')
  if (-not $tokenMatch.Success) {
    throw "unexpected argument token: $token"
  }
  $name = $tokenMatch.Groups[1].Value
  $hasColon = $tokenMatch.Groups[2].Success
  $inlineValue = if ($hasColon) { $tokenMatch.Groups[2].Value } else { '' }
  $value = $null
  $valueProvided = $false
  $hasNextToken = $index + 1 -lt $tokens.Count
  $nextToken = if ($hasNextToken) { [string]$tokens[$index + 1] } else { '' }
  $nextIsParameter = $hasNextToken -and $nextToken -match '^-([A-Za-z][A-Za-z0-9]*)(?::.*)?$'
  if ($hasColon) {
    if ($inlineValue.Length -gt 0) {
      $value = [string]$inlineValue
      $valueProvided = $true
      $index++
    } elseif ($hasNextToken -and -not $nextIsParameter) {
      # PowerShell can pass '-Name:' and its value as separate tokens.
      $value = $nextToken
      $valueProvided = $true
      $index += 2
    } else {
      # Preserve an explicitly empty colon value; it is different from a
      # switch and lets the target cmdlet apply its own validation/default.
      $value = ''
      $valueProvided = $true
      $index++
    }
  } elseif ($hasNextToken -and -not $nextIsParameter) {
    $value = $nextToken
    $valueProvided = $true
    $index += 2
  }
  if ($valueProvided) {
    if ($invokeArguments.ContainsKey($name)) {
      $invokeArguments[$name] = @($invokeArguments[$name]) + @($value)
    } else {
      $invokeArguments[$name] = $value
    }
  } else {
    $invokeArguments[$name] = $true
    $index++
  }
}
& $entry -Action $Action @invokeArguments
exit $LASTEXITCODE
