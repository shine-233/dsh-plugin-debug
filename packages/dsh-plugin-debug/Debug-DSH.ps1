[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [ValidateSet('doctor', 'start', 'diagnostics', 'plugin-health', 'snapshot', 'restore', 'workspace-list', 'workspace-snapshot', 'workspace-restore', 'session-history', 'session-fork', 'known-good-list', 'known-good-save', 'known-good-restore', 'known-good-fixture', 'plugin-enable', 'plugin-disable', 'repair-plan', 'repair-assist', 'self-repair', 'repair-apply', 'repair-revert', 'plugin-bisect-plan', 'plugin-dependency-graph', 'plugin-preflight', 'diagnostics-diff', 'trace-contract', 'trace-eval', 'trace-live', 'trace-baseline', 'trace-loop', 'trace-recursion', 'trace-autopsy', 'guardian-status', 'live-api-fixture', 'trace-autopsy-fixture', 'trace-loop-fixture', 'trace-recursion-fixture', 'guardian-status-fixture', 'crash-fixture', 'runtime-supervisor-fixture', 'incident-capture', 'incident-correlation', 'repro-export', 'context-doctor', 'security-audit', 'session-health', 'fail-log', 'provenance', 'pointer-evidence')]
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
# A nested script that calls `exit 2` can be normalized to exit 1 when it is
# invoked in-process by Windows PowerShell. Run the merged dispatcher in a
# child PowerShell instead, while still passing a named argument vector. This
# preserves busy/unavailable distinctions for callers and keeps repeated values
# such as InputPath intact.
if ($Action -eq 'guardian-status') {
  $guardianStatusScript = Join-Path (Split-Path -Parent $entry) 'tools\Get-DSHGuardianStatus.ps1'
  if (-not (Test-Path -LiteralPath $guardianStatusScript -PathType Leaf)) {
    throw "Guardian status helper is missing: $guardianStatusScript"
  }
  $guardianArguments = @{}
  $guardianHost = if ($invokeArguments.ContainsKey('HostName')) { [string]$invokeArguments.HostName } else { '127.0.0.1' }
  $guardianPort = if ($invokeArguments.ContainsKey('Port')) { [int]$invokeArguments.Port } else { 3081 }
  $guardianArguments.Url = "http://${guardianHost}:$guardianPort/api/dsh-plugin-debug/guardian/status"
  if ($invokeArguments.ContainsKey('InputPath')) {
    $guardianArguments.InputPath = [string]@($invokeArguments.InputPath)[0]
  }
  if ($invokeArguments.ContainsKey('TimeoutSec')) {
    $guardianArguments.TimeoutSec = [int]$invokeArguments.TimeoutSec
  }
  $LASTEXITCODE = 0
  & $guardianStatusScript @guardianArguments
  $guardianExit = if (Test-Path variable:LASTEXITCODE) { [int]$LASTEXITCODE } else { 0 }
  exit $guardianExit
}

$hostCommand = Get-Command powershell.exe -ErrorAction SilentlyContinue
if ($null -eq $hostCommand) { $hostCommand = Get-Command pwsh -ErrorAction SilentlyContinue }
if ($null -eq $hostCommand) { throw 'PowerShell host is required for the Debug dispatcher' }
# Native PowerShell process argument marshalling cannot reliably preserve a
# repeated string[] parameter (for example two -InputPath values). Serialize
# the already-parsed named arguments through an environment variable instead,
# then reconstruct the hashtable in the child before invoking the dispatcher.
$childInvocation = [ordered]@{ Action = $Action }
foreach ($name in $invokeArguments.Keys) { $childInvocation[$name] = $invokeArguments[$name] }
$previousChildScript = $env:DSH_DEBUG_CHILD_SCRIPT
$previousChildArgs = $env:DSH_DEBUG_CHILD_ARGS
$childCommand = '$parsedArgs = ConvertFrom-Json -InputObject $env:DSH_DEBUG_CHILD_ARGS; $invokeArgs = @{}; if ($null -ne $parsedArgs) { foreach ($property in $parsedArgs.PSObject.Properties) { $invokeArgs[$property.Name] = $property.Value } }; & $env:DSH_DEBUG_CHILD_SCRIPT @invokeArgs; $childExit = if (Test-Path variable:LASTEXITCODE) { [int]$LASTEXITCODE } else { 0 }; exit $childExit'
$encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($childCommand))
try {
  $env:DSH_DEBUG_CHILD_SCRIPT = [IO.Path]::GetFullPath($entry)
  $env:DSH_DEBUG_CHILD_ARGS = ConvertTo-Json -InputObject $childInvocation -Compress -Depth 20
  & $hostCommand.Source -NoLogo -NoProfile -ExecutionPolicy Bypass -EncodedCommand $encodedCommand
  $childExit = if (Test-Path variable:LASTEXITCODE) { [int]$LASTEXITCODE } else { 0 }
} finally {
  if ($null -eq $previousChildScript) { Remove-Item Env:DSH_DEBUG_CHILD_SCRIPT -ErrorAction SilentlyContinue } else { $env:DSH_DEBUG_CHILD_SCRIPT = $previousChildScript }
  if ($null -eq $previousChildArgs) { Remove-Item Env:DSH_DEBUG_CHILD_ARGS -ErrorAction SilentlyContinue } else { $env:DSH_DEBUG_CHILD_ARGS = $previousChildArgs }
}
exit $childExit
