[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$toolRoot = Split-Path -Parent $MyInvocation.MyCommand.Path

Import-Module (Join-Path $toolRoot 'DSH-Trace.psm1') -Force
Import-Module (Join-Path $toolRoot 'DSH-TraceAutopsy.psm1') -Force

function Get-TestProperty {
  param([AllowNull()]$Object, [Parameter(Mandatory = $true)][string]$Name)
  if ($null -eq $Object) { return $null }
  if ($Object -is [System.Collections.IDictionary] -and $Object.Contains($Name)) { return $Object[$Name] }
  $property = $Object.PSObject.Properties[$Name]
  if ($null -eq $property) { return $null }
  return $property.Value
}

function Assert-Test {
  param([Parameter(Mandatory = $true)][bool]$Condition, [Parameter(Mandatory = $true)][string]$Message)
  if (-not $Condition) { throw $Message }
}

function New-RawEvent {
  param(
    [Parameter(Mandatory = $true)][int]$Seq,
    [Parameter(Mandatory = $true)][string]$Type,
    [hashtable]$Data = @{}
  )
  return [ordered]@{ event = [ordered]@{ seq = $Seq; type = $Type; data = $Data } }
}

function New-ToolCallData {
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][string]$CallId,
    [Parameter(Mandatory = $true)][string]$Permission,
    [int]$Turn = 1,
    [int]$Step = 1
  )
  return @{
    turn = $Turn
    step = $Step
    name = $Name
    callId = $CallId
    arguments = @{
      sandbox_permissions = $Permission
      command = 'PRIVATE_COMMAND_SHOULD_NEVER_APPEAR'
      secretValue = 'PRIVATE_ARGUMENT_VALUE_SHOULD_NEVER_APPEAR'
    }
  }
}

function New-ToolResultData {
  param(
    [Parameter(Mandatory = $true)][string]$CallId,
    [Parameter(Mandatory = $true)][bool]$IsError,
    [string]$ErrorCode = ''
  )
  $value = @{
    turn = 1
    step = 2
    message = @{
      source = @{ callId = $CallId }
      content = @(@{
        type = 'tool-result'
        isError = $IsError
        text = 'PRIVATE_RESULT_BODY_SHOULD_NEVER_APPEAR'
      })
    }
  }
  if (-not [string]::IsNullOrWhiteSpace($ErrorCode)) { $value.error = @{ code = $ErrorCode; message = 'PRIVATE_ERROR_BODY_SHOULD_NEVER_APPEAR' } }
  return $value
}

function New-NormalFixture {
  $events = [System.Collections.Generic.List[object]]::new()
  [void]$events.Add((New-RawEvent -Seq 1 -Type 'request/context' -Data @{ provider = 'provider-a'; model = 'model-a'; turn = 1; timestamp = '2026-08-15T00:00:00Z' }))
  [void]$events.Add((New-RawEvent -Seq 2 -Type 'tool/call' -Data ((New-ToolCallData -Name 'read_file' -CallId 'normal-1' -Permission 'read-only') + @{ timestamp = '2026-08-15T00:00:01Z' })))
  [void]$events.Add((New-RawEvent -Seq 3 -Type 'tool/result' -Data ((New-ToolResultData -CallId 'normal-1' -IsError $false) + @{ timestamp = '2026-08-15T00:00:02Z' })))
  [void]$events.Add((New-RawEvent -Seq 4 -Type 'tool/call' -Data ((New-ToolCallData -Name 'write_file' -CallId 'normal-2' -Permission 'workspace-write') + @{ timestamp = '2026-08-15T00:00:03Z' })))
  [void]$events.Add((New-RawEvent -Seq 5 -Type 'tool/result' -Data ((New-ToolResultData -CallId 'normal-2' -IsError $true -ErrorCode 'PERMISSION_DENIED') + @{ timestamp = '2026-08-15T00:00:04Z' })))
  [void]$events.Add((New-RawEvent -Seq 6 -Type 'checkpoint/create' -Data @{ turn = 1; step = 3; timestamp = '2026-08-15T00:00:05Z' }))
  [void]$events.Add((New-RawEvent -Seq 7 -Type 'tool/call' -Data ((New-ToolCallData -Name 'write_file' -CallId 'normal-3' -Permission 'workspace-write') + @{ timestamp = '2026-08-15T00:00:06Z' })))
  [void]$events.Add((New-RawEvent -Seq 8 -Type 'tool/result' -Data ((New-ToolResultData -CallId 'normal-3' -IsError $false) + @{ timestamp = '2026-08-15T00:00:07Z' })))
  [void]$events.Add((New-RawEvent -Seq 9 -Type 'turn/end' -Data @{ turn = 1; reason = @{ kind = 'success' }; timestamp = '2026-08-15T00:00:08Z' }))
  return [ordered]@{ source = 'fixture-normal'; events = @($events); hasMore = $false; toolRegistry = @('read_file', 'write_file') }
}

function New-FaultFixture {
  $events = [System.Collections.Generic.List[object]]::new()
  [void]$events.Add((New-RawEvent -Seq 1 -Type 'request/context' -Data @{ provider = 'provider-a'; model = 'model-a'; turn = 1 }))
  [void]$events.Add((New-RawEvent -Seq 2 -Type 'tool/call' -Data (New-ToolCallData -Name 'bash' -CallId 'fault-1' -Permission 'danger-full-access')))
  [void]$events.Add((New-RawEvent -Seq 3 -Type 'tool/result' -Data (New-ToolResultData -CallId 'fault-1' -IsError $true -ErrorCode 'TIMEOUT')))
  [void]$events.Add((New-RawEvent -Seq 4 -Type 'tool/call' -Data (New-ToolCallData -Name 'bash' -CallId 'fault-2' -Permission 'danger-full-access')))
  [void]$events.Add((New-RawEvent -Seq 5 -Type 'tool/call' -Data (New-ToolCallData -Name 'bash' -CallId 'fault-3' -Permission 'danger-full-access')))
  [void]$events.Add((New-RawEvent -Seq 6 -Type 'tool/call' -Data (New-ToolCallData -Name 'unknown_tool' -CallId 'fault-unknown' -Permission 'read-only')))
  [void]$events.Add((New-RawEvent -Seq 7 -Type 'turn/end' -Data @{ turn = 1; reason = @{ kind = 'error' } }))
  [void]$events.Add((New-RawEvent -Seq 8 -Type 'turn/end' -Data @{ turn = 2; reason = @{ kind = 'error' } }))
  [void]$events.Add((New-RawEvent -Seq 9 -Type 'turn/end' -Data @{ turn = 3; reason = @{ kind = 'error' } }))
  [void]$events.Add((New-RawEvent -Seq 10 -Type 'request/context' -Data @{ provider = 'provider-b'; model = 'model-b'; turn = 4 }))
  [void]$events.Add((New-RawEvent -Seq 30 -Type 'tool/call' -Data (New-ToolCallData -Name 'pwsh' -CallId 'fault-4' -Permission 'workspace-write')))
  [void]$events.Add((New-RawEvent -Seq 31 -Type 'turn/end' -Data @{ turn = 4; reason = @{ kind = 'timeout' } }))
  return [ordered]@{ source = 'fixture-fault'; events = @($events); hasMore = $false; toolRegistry = @('bash', 'pwsh') }
}

function Get-FindingKinds {
  param([Parameter(Mandatory = $true)]$Report)
  return @($Report.findings | ForEach-Object { [string]$_.kind } | Sort-Object -Unique)
}

function Test-EvidenceShape {
  param([Parameter(Mandatory = $true)]$Report)
  foreach ($finding in @($Report.findings)) {
    foreach ($evidence in @($finding.evidence)) {
      $names = if ($evidence -is [System.Collections.IDictionary]) { @($evidence.Keys | ForEach-Object { [string]$_ } | Sort-Object) } else { @($evidence.PSObject.Properties.Name | Sort-Object) }
      if ((@($names) -join ',') -cne 'callId,seq') { return $false }
    }
  }
  return $true
}

try {
  $normal = Invoke-DshTraceAutopsy -InputObject (New-NormalFixture) -ToolRegistry @('read_file', 'write_file')
  Assert-Test ($normal.status -eq 'CLEAN') "normal fixture status was $($normal.status)"
  Assert-Test ([int]$normal.summary.findingCount -eq 0) 'normal fixture produced findings'
  Assert-Test ((Test-DshTraceAutopsyOutput -Report $normal).valid -eq $true) 'normal report failed output contract'

  $fault = Invoke-DshTraceAutopsy -InputObject (New-FaultFixture) -ToolRegistry @('bash', 'pwsh')
  $kinds = @(Get-FindingKinds -Report $fault)
  foreach ($expectedKind in @(
      'retry-storm',
      'pending-no-result-chain',
      'tool-registry-mismatch',
      'error-retry-without-strategy',
      'consecutive-turn-errors',
      'model-provider-switch',
      'timeout-event',
      'long-sequence-gap',
      'high-risk-after-failure-without-checkpoint-or-fork'
    )) {
    Assert-Test ($expectedKind -in $kinds) "fault fixture did not detect $expectedKind"
  }
  Assert-Test ($fault.status -eq 'FINDINGS') "fault fixture status was $($fault.status)"
  Assert-Test ((Test-DshTraceAutopsyOutput -Report $fault).valid -eq $true) 'fault report failed output contract'
  Assert-Test (Test-EvidenceShape -Report $fault) 'finding evidence contained fields other than seq/callId'

  $faultJson = $fault | ConvertTo-Json -Depth 30
  foreach ($forbidden in @('PRIVATE_COMMAND_SHOULD_NEVER_APPEAR', 'PRIVATE_ARGUMENT_VALUE_SHOULD_NEVER_APPEAR', 'PRIVATE_RESULT_BODY_SHOULD_NEVER_APPEAR', 'PRIVATE_ERROR_BODY_SHOULD_NEVER_APPEAR')) {
    Assert-Test ($faultJson -notmatch [regex]::Escape($forbidden)) "metadata report leaked $forbidden"
  }
  Assert-Test ([int]$fault.summary.pendingCount -ge 3) 'fault fixture did not preserve pending count metadata'

  [ordered]@{
    result = 'PASS'
    kind = 'dsh-trace-autopsy-test'
    tests = [ordered]@{
      normalStatus = $normal.status
      normalFindingCount = [int]$normal.summary.findingCount
      faultStatus = $fault.status
      faultFindingCount = [int]$fault.summary.findingCount
      detectedKinds = @($kinds)
      evidenceShape = 'seq+callId-only'
      rawPayloadLeak = $false
    }
    privacy = 'Fixtures contain private-looking command, argument, and result values, but the report keeps only metadata and evidence seq/callId.'
  } | ConvertTo-Json -Depth 20
  exit 0
} catch {
  [ordered]@{
    result = 'FAIL'
    kind = 'dsh-trace-autopsy-test'
    error = $_.Exception.Message
    stack = $_.ScriptStackTrace
  } | ConvertTo-Json -Depth 12
  exit 1
}
