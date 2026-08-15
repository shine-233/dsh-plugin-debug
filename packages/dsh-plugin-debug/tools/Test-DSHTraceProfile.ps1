[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$toolRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $toolRoot 'DSH-Trace.psm1') -Force

function Assert-ProfileTest {
  param(
    [Parameter(Mandatory = $true)][bool]$Condition,
    [Parameter(Mandatory = $true)][string]$Message
  )
  if (-not $Condition) { throw $Message }
}

function New-ProfileEvent {
  param(
    [Parameter(Mandatory = $true)][int]$Seq,
    [Parameter(Mandatory = $true)][string]$Type,
    [hashtable]$Data = @{}
  )
  return [ordered]@{ event = [ordered]@{ seq = $Seq; type = $Type; data = $Data } }
}

function New-ProfileCall {
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][string]$CallId,
    [Parameter(Mandatory = $true)][string]$Timestamp,
    [int]$Turn = 1,
    [int]$Step = 1,
    [string]$Permission = 'read-only'
  )
  return (New-ProfileEvent -Seq $script:nextSeq -Type 'tool/call' -Data @{
      turn = $Turn
      step = $Step
      timestamp = $Timestamp
      name = $Name
      callId = $CallId
      arguments = @{
        sandbox_permissions = $Permission
        command = 'PRIVATE_COMMAND_SHOULD_NOT_APPEAR'
        secretValue = 'PRIVATE_ARGUMENT_SHOULD_NOT_APPEAR'
      }
    })
}

function New-ProfileResult {
  param(
    [Parameter(Mandatory = $true)][string]$CallId,
    [Parameter(Mandatory = $true)][string]$Timestamp,
    [Parameter(Mandatory = $true)][bool]$IsError,
    [int]$Turn = 1,
    [int]$Step = 2,
    [string]$ErrorCode = ''
  )
  $data = @{
    turn = $Turn
    step = $Step
    timestamp = $Timestamp
    message = @{
      source = @{ callId = $CallId }
      content = @(@{ type = 'tool-result'; isError = $IsError; text = 'PRIVATE_RESULT_SHOULD_NOT_APPEAR' })
    }
  }
  if (-not [string]::IsNullOrWhiteSpace($ErrorCode)) {
    $data.error = @{ code = $ErrorCode; message = 'PRIVATE_ERROR_SHOULD_NOT_APPEAR' }
  }
  return (New-ProfileEvent -Seq $script:nextSeq -Type 'tool/result' -Data $data)
}

function Get-ProfileToolRow {
  param([Parameter(Mandatory = $true)]$Profile, [Parameter(Mandatory = $true)][string]$Name)
  return @($Profile.profile.tools.rows | Where-Object { $_.name -ceq $Name })[0]
}

try {
  $script:nextSeq = 1
  $events = [System.Collections.Generic.List[object]]::new()
  [void]$events.Add((New-ProfileEvent -Seq $script:nextSeq -Type 'request/context' -Data @{ turn = 1; timestamp = '2026-08-15T00:00:00Z'; provider = 'fixture-provider'; model = 'fixture-model' })); $script:nextSeq++
  [void]$events.Add((New-ProfileCall -Name 'read_file' -CallId 'profile-read-1' -Timestamp '2026-08-15T00:00:00.100Z')); $script:nextSeq++
  [void]$events.Add((New-ProfileResult -CallId 'profile-read-1' -Timestamp '2026-08-15T00:00:00.500Z' -IsError $false)); $script:nextSeq++
  [void]$events.Add((New-ProfileCall -Name 'write_file' -CallId 'profile-write-1' -Timestamp '2026-08-15T00:00:00.700Z' -Permission 'workspace-write')); $script:nextSeq++
  [void]$events.Add((New-ProfileResult -CallId 'profile-write-1' -Timestamp '2026-08-15T00:00:00.900Z' -IsError $true -ErrorCode 'TIMEOUT')); $script:nextSeq++
  [void]$events.Add((New-ProfileCall -Name 'write_file' -CallId 'profile-write-2' -Timestamp '2026-08-15T00:00:01.000Z' -Permission 'workspace-write')); $script:nextSeq++
  [void]$events.Add((New-ProfileEvent -Seq $script:nextSeq -Type 'turn/end' -Data @{ turn = 1; reason = @{ kind = 'error' }; timestamp = '2026-08-15T00:00:01.500Z' })); $script:nextSeq++
  [void]$events.Add((New-ProfileEvent -Seq $script:nextSeq -Type 'request/context' -Data @{ turn = 2; timestamp = '2026-08-15T00:00:02.000Z'; provider = 'fixture-provider'; model = 'fixture-model' })); $script:nextSeq++
  [void]$events.Add((New-ProfileCall -Name 'read_file' -CallId 'profile-read-2' -Timestamp '2026-08-15T00:00:02.200Z' -Turn 2)); $script:nextSeq++
  [void]$events.Add((New-ProfileResult -CallId 'profile-read-2' -Timestamp '2026-08-15T00:00:02.500Z' -IsError $false -Turn 2)); $script:nextSeq++
  [void]$events.Add((New-ProfileEvent -Seq $script:nextSeq -Type 'turn/end' -Data @{ turn = 2; reason = @{ kind = 'success' }; timestamp = '2026-08-15T00:00:03.000Z' })); $script:nextSeq++

  $trace = ConvertTo-DshTrace -InputObject ([ordered]@{ source = 'profile-fixture'; events = @($events); hasMore = $false }) -TraceSource 'fixture'
  $profile = Get-DshTraceProfile -Trace $trace
  $profileContract = Test-DshTraceProfileContract -Report $profile
  Assert-ProfileTest ($profile.status -eq 'PASS') "profile status was $($profile.status)"
  Assert-ProfileTest ($profileContract.valid -eq $true) 'profile output contract failed'
  Assert-ProfileTest ([int]$profile.profile.wallTime.durationMs -eq 3000) 'relative wall-time duration was not 3000 ms'
  Assert-ProfileTest ([int]$profile.profile.coverage.timestampEventCount -eq 11) 'timestamp event count was not 11'
  Assert-ProfileTest ([int]$profile.profile.turns.turnCount -eq 2) 'turn count was not 2'
  Assert-ProfileTest ([int]$profile.profile.tools.uniqueToolCount -eq 2) 'unique tool count was not 2'
  Assert-ProfileTest ([int]$profile.profile.tools.callCount -eq 4) 'tool call count was not 4'
  Assert-ProfileTest ([int]$profile.profile.tools.errorResultCount -eq 1) 'tool error count was not 1'
  Assert-ProfileTest ([int]$profile.profile.tools.pendingCount -eq 1) 'pending call count was not 1'
  Assert-ProfileTest ([int]$profile.profile.retries.retryGroupCount -eq 1) 'retry group count was not 1'
  Assert-ProfileTest ([int]$profile.profile.retries.retryAttemptCount -eq 1) 'retry attempt count was not 1'
  Assert-ProfileTest ([int]$profile.profile.errors.totalErrorCount -eq 2) 'total error count was not 2'
  $readRow = Get-ProfileToolRow -Profile $profile -Name 'read_file'
  $writeRow = Get-ProfileToolRow -Profile $profile -Name 'write_file'
  Assert-ProfileTest ([int]$readRow.latencyObservedCount -eq 2 -and [int]$readRow.averageLatencyMs -eq 350) 'read latency profile was incorrect'
  Assert-ProfileTest ([int]$writeRow.latencyObservedCount -eq 1 -and [int]$writeRow.maxLatencyMs -eq 200) 'write latency profile was incorrect'
  $profileJson = $profile | ConvertTo-Json -Depth 30
  foreach ($forbidden in @('PRIVATE_COMMAND_SHOULD_NOT_APPEAR', 'PRIVATE_ARGUMENT_SHOULD_NOT_APPEAR', 'PRIVATE_RESULT_SHOULD_NOT_APPEAR', 'PRIVATE_ERROR_SHOULD_NOT_APPEAR')) {
    Assert-ProfileTest ($profileJson -notmatch [regex]::Escape($forbidden)) "profile leaked $forbidden"
  }
  Assert-ProfileTest ($profileJson -notmatch '2026-08-15T00:00:') 'profile leaked an absolute timestamp'

  [ordered]@{
    result = 'PASS'
    kind = 'dsh-trace-profile-test'
    metrics = [ordered]@{
      durationMs = [int]$profile.profile.wallTime.durationMs
      turnCount = [int]$profile.profile.turns.turnCount
      callCount = [int]$profile.profile.tools.callCount
      retryAttemptCount = [int]$profile.profile.retries.retryAttemptCount
      errorCount = [int]$profile.profile.errors.totalErrorCount
      rawPayloadLeak = $false
      absoluteTimestampLeak = $false
    }
    privacy = 'Input contains private-looking payloads; profile contains only bounded metadata and relative durations.'
  } | ConvertTo-Json -Depth 20
  exit 0
} catch {
  [ordered]@{
    result = 'FAIL'
    kind = 'dsh-trace-profile-test'
    error = $_.Exception.Message
    stack = $_.ScriptStackTrace
  } | ConvertTo-Json -Depth 12
  exit 1
}
