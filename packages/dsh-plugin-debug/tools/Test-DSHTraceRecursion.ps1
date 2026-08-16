[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$toolRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$scriptPath = Join-Path $toolRoot 'DSH-TraceRecursion.ps1'
$fixturePath = Join-Path $toolRoot 'fixtures\trace-recursion.json'
$failures = [System.Collections.Generic.List[string]]::new()

function Assert-TraceRecursion {
  param([bool]$Condition, [string]$Message)
  if (-not $Condition) { [void]$failures.Add($Message) }
}

function New-TraceRecursionEvent {
  param([long]$Seq, [string]$Type, [hashtable]$Data = @{})
  return [ordered]@{ seq = $Seq; type = $Type; data = $Data }
}

function New-TraceRecursionInput {
  param([object[]]$Events)
  return [ordered]@{ schemaVersion = 1; events = @($Events) }
}

try {
  if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) { throw 'trace recursion script is missing' }
  if (-not (Test-Path -LiteralPath $fixturePath -PathType Leaf)) { throw 'trace recursion fixture is missing' }
  $fixtureRaw = Get-Content -LiteralPath $fixturePath -Raw -Encoding UTF8
  foreach ($forbiddenField in @('sessionId', 'agentId', 'token', 'command', 'path', 'text')) {
    Assert-TraceRecursion ($fixtureRaw -notmatch ('(?i)"' + [regex]::Escape($forbiddenField) + '"\s*:')) "published recursion fixture contains forbidden field: $forbiddenField"
  }
  . $scriptPath

  $safe = New-TraceRecursionInput -Events @(
    (New-TraceRecursionEvent -Seq 1 -Type 'agent-start'),
    (New-TraceRecursionEvent -Seq 2 -Type 'tool/call'),
    (New-TraceRecursionEvent -Seq 3 -Type 'agent-end')
  )
  $safeReport = Invoke-DshTraceRecursion -InputObject $safe -MaxDepth 2
  Assert-TraceRecursion ($safeReport.result -eq 'PASS' -and $safeReport.input.maxObservedDepth -eq 1) 'balanced shallow trace did not pass'

  $boundary = New-TraceRecursionInput -Events @(
    (New-TraceRecursionEvent -Seq 1 -Type 'agent-start'),
    (New-TraceRecursionEvent -Seq 2 -Type 'tool-workflow/run-start'),
    (New-TraceRecursionEvent -Seq 3 -Type 'tool-workflow/agent-start'),
    (New-TraceRecursionEvent -Seq 4 -Type 'tool-workflow/agent-end'),
    (New-TraceRecursionEvent -Seq 5 -Type 'tool-workflow/run-end'),
    (New-TraceRecursionEvent -Seq 6 -Type 'agent-end')
  )
  $boundaryReport = Invoke-DshTraceRecursion -InputObject $boundary -MaxDepth 3
  Assert-TraceRecursion ($boundaryReport.result -eq 'PASS' -and $boundaryReport.input.maxObservedDepth -eq 3) 'depth boundary was incorrectly reported as recursion'

  $deep = New-TraceRecursionInput -Events @(
    (New-TraceRecursionEvent -Seq 1 -Type 'agent-start' -Data @{ agentId = 'agent-secret-root' }),
    (New-TraceRecursionEvent -Seq 2 -Type 'tool-workflow/run-start' -Data @{ sessionId = 'session-secret' }),
    (New-TraceRecursionEvent -Seq 3 -Type 'tool-workflow/agent-start' -Data @{ message = 'message-must-not-appear' }),
    (New-TraceRecursionEvent -Seq 4 -Type 'tool-workflow/run-start' -Data @{ arguments = @{ token = 'token-must-not-appear' } }),
    (New-TraceRecursionEvent -Seq 5 -Type 'tool-workflow/run-end'),
    (New-TraceRecursionEvent -Seq 6 -Type 'tool-workflow/agent-end'),
    (New-TraceRecursionEvent -Seq 7 -Type 'tool-workflow/run-end'),
    (New-TraceRecursionEvent -Seq 8 -Type 'agent-end')
  )
  $before = $deep | ConvertTo-Json -Compress -Depth 20
  $deepReport = Invoke-DshTraceRecursion -InputObject $deep -MaxDepth 3
  $after = $deep | ConvertTo-Json -Compress -Depth 20
  $deepJson = $deepReport | ConvertTo-Json -Compress -Depth 20
  Assert-TraceRecursion ($deepReport.result -eq 'RECURSION_DETECTED' -and @($deepReport.findings).Count -eq 1) 'depth overflow was not detected'
  Assert-TraceRecursion ($deepReport.findings[0].observedDepth -eq 4 -and $deepReport.findings[0].threshold -eq 3 -and $deepReport.findings[0].closed -eq $true) 'recursion finding contract is incomplete'
  Assert-TraceRecursion ($deepJson -notmatch 'agent-secret-root|session-secret|message-must-not-appear|token-must-not-appear') 'recursion report leaked raw identifiers or payloads'
  Assert-TraceRecursion ($before -ceq $after) 'recursion analysis changed its input object'

  $incomplete = New-TraceRecursionInput -Events @(
    (New-TraceRecursionEvent -Seq 1 -Type 'agent-start'),
    (New-TraceRecursionEvent -Seq 2 -Type 'tool/call')
  )
  $incompleteReport = Invoke-DshTraceRecursion -InputObject $incomplete -MaxDepth 3
  Assert-TraceRecursion ($incompleteReport.result -eq 'MANUAL_REVIEW' -and $incompleteReport.input.openFrameCount -eq 1) 'incomplete lifecycle did not fail closed to manual review'

  $mismatched = New-TraceRecursionInput -Events @(
    (New-TraceRecursionEvent -Seq 1 -Type 'agent-start'),
    (New-TraceRecursionEvent -Seq 2 -Type 'workflow-end')
  )
  $mismatchReport = Invoke-DshTraceRecursion -InputObject $mismatched -MaxDepth 3
  Assert-TraceRecursion ($mismatchReport.result -eq 'MANUAL_REVIEW' -and $mismatchReport.input.ambiguityCount -gt 0) 'mismatched lifecycle did not require manual review'

  $dynamic = New-TraceRecursionInput -Events @(
    (New-TraceRecursionEvent -Seq 1 -Type 'agent-${dynamic}-start')
  )
  $dynamicReport = Invoke-DshTraceRecursion -InputObject $dynamic -MaxDepth 3
  Assert-TraceRecursion ($dynamicReport.result -eq 'MANUAL_REVIEW') 'dynamic lifecycle marker did not require manual review'

  $invalid = New-TraceRecursionInput -Events @(
    (New-TraceRecursionEvent -Seq 2 -Type 'agent-start'),
    (New-TraceRecursionEvent -Seq 1 -Type 'agent-end')
  )
  $invalidReport = Invoke-DshTraceRecursion -InputObject $invalid -MaxDepth 3
  Assert-TraceRecursion ($invalidReport.result -eq 'FAIL' -and $invalidReport.safety.failClosed -eq $true) 'invalid sequence did not fail closed'

  $invalidShape = [ordered]@{
    schemaVersion = 1
    events = [ordered]@{ seq = 1; type = 'agent-start' }
  }
  $invalidShapeReport = Invoke-DshTraceRecursion -InputObject $invalidShape -MaxDepth 3
  Assert-TraceRecursion ($invalidShapeReport.result -eq 'FAIL' -and $invalidShapeReport.safety.failClosed -eq $true) 'non-array events did not fail closed'

  $overflowEvents = [System.Collections.Generic.List[object]]::new()
  for ($index = 1; $index -le 2001; $index++) {
    [void]$overflowEvents.Add((New-TraceRecursionEvent -Seq $index -Type 'tool/call'))
  }
  $overflowReport = Invoke-DshTraceRecursion -InputObject (New-TraceRecursionInput -Events @($overflowEvents)) -MaxDepth 3
  Assert-TraceRecursion ($overflowReport.result -eq 'FAIL' -and $overflowReport.safety.failClosed -eq $true) 'event overflow did not fail closed'

  $powerShell = Get-Command powershell.exe -ErrorAction SilentlyContinue
  if ($null -eq $powerShell) { throw 'Windows PowerShell is required for the CLI fixture' }
  $cliText = (& $powerShell.Source -NoLogo -NoProfile -ExecutionPolicy Bypass -File $scriptPath -InputPath $fixturePath -MaxDepth 3 2>&1 | Out-String).Trim()
  $cliExit = $LASTEXITCODE
  $cliReport = $cliText | ConvertFrom-Json
  Assert-TraceRecursion ($cliExit -eq 0 -and $cliReport.result -eq 'RECURSION_DETECTED') 'CLI fixture did not report recursion'
  Assert-TraceRecursion ($cliText -notmatch 'fixture-agent-secret|fixture-session-secret|fixture-message-secret|fixture-token-secret') 'CLI fixture leaked raw payload data'
} catch {
  [void]$failures.Add("unhandled: $($_.Exception.Message)")
}

if ($failures.Count -gt 0) {
  [ordered]@{
    result = 'FAIL'
    kind = 'dsh-trace-recursion-test'
    failures = @($failures)
    offline = $true
    networkAccessed = $false
  } | ConvertTo-Json -Depth 12
  exit 1
}

[ordered]@{
  result = 'PASS'
  kind = 'dsh-trace-recursion-test'
  metadataOnly = $true
  offline = $true
  networkAccessed = $false
  recursionDetected = $true
  manualReview = $true
  invalidFailClosed = $true
  invalidShapeFailClosed = $true
  overflowFailClosed = $true
  inputUnchanged = $true
  runtimeBlocking = $false
} | ConvertTo-Json -Depth 12
exit 0
