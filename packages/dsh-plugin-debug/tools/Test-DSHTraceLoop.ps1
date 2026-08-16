[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$toolRoot = Split-Path -Parent $MyInvocation.MyCommand.Path

function Assert-TraceLoopTest {
  param(
    [Parameter(Mandatory = $true)][bool]$Condition,
    [Parameter(Mandatory = $true)][string]$Message
  )
  if (-not $Condition) { throw $Message }
}

function New-TraceLoopCallEvent {
  param(
    [Parameter(Mandatory = $true)][int]$Seq,
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][string]$CallId,
    [Parameter(Mandatory = $true)]$Arguments
  )
  return [ordered]@{
    event = [ordered]@{
      seq = $Seq
      type = 'tool/call'
      data = [ordered]@{
        name = $Name
        callId = $CallId
        arguments = $Arguments
      }
    }
  }
}

function New-TraceLoopResultEvent {
  param(
    [Parameter(Mandatory = $true)][int]$Seq,
    [Parameter(Mandatory = $true)][string]$CallId,
    [Parameter(Mandatory = $true)][bool]$IsError
  )
  return [ordered]@{
    event = [ordered]@{
      seq = $Seq
      type = 'tool/result'
      data = [ordered]@{
        message = [ordered]@{
          source = [ordered]@{ callId = $CallId }
          content = @([ordered]@{ type = 'tool-result'; isError = $IsError; text = 'PRIVATE_RESULT_MUST_NOT_APPEAR' })
        }
      }
    }
  }
}

function New-TraceLoopTrace {
  param(
    [Parameter(Mandatory = $true)][string[]]$Names,
    [bool]$SuccessfulReturns = $false,
    [bool]$IncludeContext = $true
  )
  $events = [System.Collections.Generic.List[object]]::new()
  $seq = 1
  if ($IncludeContext) {
    [void]$events.Add([ordered]@{ event = [ordered]@{ seq = $seq; type = 'request/context'; data = [ordered]@{ provider = 'fixture'; model = 'fixture' } } })
    $seq++
  }
  $ordinal = 0
  foreach ($name in $Names) {
    $callId = "call-$ordinal"
    [void]$events.Add((New-TraceLoopCallEvent -Seq $seq -Name 'read_file' -CallId $callId -Arguments ([ordered]@{ path = "/workspace/$name.txt"; mode = 'metadata-only' })))
    $seq++
    if ($SuccessfulReturns) {
      [void]$events.Add((New-TraceLoopResultEvent -Seq $seq -CallId $callId -IsError $false))
      $seq++
    }
    $ordinal++
  }
  return [ordered]@{ source = 'test-fixture'; hasMore = $false; events = @($events) }
}

function New-TraceLoopFixtureObject {
  param([Parameter(Mandatory = $true)][string]$Path)
  $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
  return $raw | ConvertFrom-Json
}

try {
  . (Join-Path $toolRoot 'DSH-TraceLoop.ps1')

  $fixturePath = Join-Path $toolRoot 'fixtures\trace-loop.json'
  $fixtureRawBefore = Get-Content -LiteralPath $fixturePath -Raw -Encoding UTF8
  foreach ($forbiddenField in @('sessionId', 'agentId', 'token', 'command', 'path', 'text')) {
    Assert-TraceLoopTest ($fixtureRawBefore -notmatch ('(?i)"' + [regex]::Escape($forbiddenField) + '"\s*:')) "published loop fixture contains forbidden field: $forbiddenField"
  }
  $fixture = New-TraceLoopFixtureObject -Path $fixturePath
  $fixtureJsonBefore = $fixture | ConvertTo-Json -Depth 32

  $pass = Invoke-DshTraceLoop -InputObject (New-TraceLoopTrace -Names @('one', 'two', 'three')) -WindowSize 4 -RepeatThreshold 2
  Assert-TraceLoopTest ($pass.result -eq 'PASS') "no-loop trace result was $($pass.result)"
  Assert-TraceLoopTest (@($pass.findings).Count -eq 0) 'no-loop trace produced findings'
  Assert-TraceLoopTest ($null -ne $pass.findings) 'no-loop report collapsed findings to null'
  Assert-TraceLoopTest ($pass.safety.analysisMode -eq 'offline-postmortem') 'PASS report safety mode was not offline-postmortem'

  $aaa = Invoke-DshTraceLoop -InputObject (New-TraceLoopTrace -Names @('same', 'same', 'same')) -WindowSize 3 -RepeatThreshold 3
  $aaaPatterns = @($aaa.findings | ForEach-Object { if ($_ -is [System.Collections.IDictionary]) { [string]$_['pattern'] } else { [string]$_.pattern } })
  Assert-TraceLoopTest ($aaa.result -eq 'LOOP_DETECTED') "A-A-A result was $($aaa.result)"
  Assert-TraceLoopTest ($aaaPatterns -contains 'A-A-A') ("A-A-A pattern was not reported: " + ($aaa.findings | ConvertTo-Json -Depth 12 -Compress))

  $ababa = Invoke-DshTraceLoop -InputObject (New-TraceLoopTrace -Names @('a', 'b', 'a', 'b')) -WindowSize 4 -RepeatThreshold 2
  Assert-TraceLoopTest ($ababa.result -eq 'LOOP_DETECTED') "A-B-A-B result was $($ababa.result)"
  $ababaPatterns = @($ababa.findings | ForEach-Object { if ($_ -is [System.Collections.IDictionary]) { [string]$_['pattern'] } else { [string]$_.pattern } })
  Assert-TraceLoopTest ($ababaPatterns -contains 'A-B-A-B') 'A-B-A-B pattern was not reported'

  $windowBoundary = Invoke-DshTraceLoop -InputObject (New-TraceLoopTrace -Names @('a', 'b', 'a', 'b')) -WindowSize 3 -RepeatThreshold 2
  Assert-TraceLoopTest ($windowBoundary.result -eq 'PASS') "window boundary result was $($windowBoundary.result)"
  Assert-TraceLoopTest (@($windowBoundary.findings).Count -eq 0) 'window boundary produced a finding outside the window'

  $successful = Invoke-DshTraceLoop -InputObject (New-TraceLoopTrace -Names @('success', 'success', 'success') -SuccessfulReturns $true) -WindowSize 3 -RepeatThreshold 3
  Assert-TraceLoopTest ($successful.result -eq 'LOOP_DETECTED') "successful-return result was $($successful.result)"
  $successfulMatches = @($successful.findings | Where-Object {
    $kind = if ($_ -is [System.Collections.IDictionary]) { $_['kind'] } else { $_.kind }
    $returnPattern = if ($_ -is [System.Collections.IDictionary]) { $_['returnPattern'] } else { $_.returnPattern }
    $kind -eq 'successful-return-loop' -and $returnPattern -eq 'successful-return'
  })
  Assert-TraceLoopTest ($successfulMatches.Count -eq 1) 'successful return loop was not reported'

  $fixtureReport = Invoke-DshTraceLoop -InputObject $fixture -WindowSize 4 -RepeatThreshold 2
  Assert-TraceLoopTest ($fixtureReport.result -eq 'LOOP_DETECTED') "fixture result was $($fixtureReport.result)"
  $fixtureJsonAfter = $fixture | ConvertTo-Json -Depth 32
  $fixtureRawAfter = Get-Content -LiteralPath $fixturePath -Raw -Encoding UTF8
  Assert-TraceLoopTest ($fixtureJsonBefore -ceq $fixtureJsonAfter) 'in-memory input object was modified'
  Assert-TraceLoopTest ($fixtureRawBefore -ceq $fixtureRawAfter) 'fixture file was modified'

  $privateTrace = New-TraceLoopTrace -Names @('private', 'private', 'private')
  $privateTrace.events[1].event.data.arguments.token = 'PRIVATE_SECRET_VALUE_MUST_NOT_APPEAR'
  $privateReport = Invoke-DshTraceLoop -InputObject $privateTrace -WindowSize 3 -RepeatThreshold 3
  $privateJson = $privateReport | ConvertTo-Json -Depth 32
  Assert-TraceLoopTest ($privateJson -notmatch 'PRIVATE_SECRET_VALUE_MUST_NOT_APPEAR') 'private argument leaked in report'
  Assert-TraceLoopTest ($privateJson -notmatch 'call-0') 'call identity leaked in report'
  Assert-TraceLoopTest ($privateReport.privacy.parameterValuesReturned -eq $false) 'privacy contract did not suppress parameter values'

  $dynamicTrace = New-TraceLoopTrace -Names @('dynamic', 'dynamic')
  $dynamicTrace.events[1].event.data.arguments.path = '${dynamicPath}'
  $dynamicReport = Invoke-DshTraceLoop -InputObject $dynamicTrace -WindowSize 3 -RepeatThreshold 2
  Assert-TraceLoopTest ($dynamicReport.result -eq 'FAIL') "dynamic input result was $($dynamicReport.result)"
  Assert-TraceLoopTest ($dynamicReport.safety.failClosed -eq $true) 'dynamic input did not fail closed'

  $invalid = [ordered]@{ events = @([ordered]@{ event = [ordered]@{ seq = 1; type = 'tool/call'; data = [ordered]@{ name = 'read_file' } } }) }
  $invalidReport = Invoke-DshTraceLoop -InputObject $invalid
  Assert-TraceLoopTest ($invalidReport.result -eq 'FAIL') "invalid input result was $($invalidReport.result)"

  $tooManyEvents = [System.Collections.Generic.List[object]]::new()
  for ($index = 1; $index -le 1001; $index++) {
    [void]$tooManyEvents.Add([ordered]@{ event = [ordered]@{ seq = $index; type = 'request/context'; data = @{} } })
  }
  $overflowReport = Invoke-DshTraceLoop -InputObject ([ordered]@{ events = @($tooManyEvents) })
  Assert-TraceLoopTest ($overflowReport.result -eq 'FAIL') "overflow input result was $($overflowReport.result)"

  [ordered]@{
    result = 'PASS'
    kind = 'dsh-trace-loop-test'
    tests = [ordered]@{
      noLoop = $pass.result
      aaa = $aaa.result
      abab = $ababa.result
      windowBoundary = $windowBoundary.result
      successfulReturn = $successful.result
      privacy = $privateReport.privacy.parameterValuesReturned -eq $false
      inputUnchanged = ($fixtureJsonBefore -ceq $fixtureJsonAfter -and $fixtureRawBefore -ceq $fixtureRawAfter)
      dynamicFailClosed = $dynamicReport.result -eq 'FAIL' -and $dynamicReport.safety.failClosed
      invalidFailClosed = $invalidReport.result -eq 'FAIL'
      overflowFailClosed = $overflowReport.result -eq 'FAIL'
    }
    findings = [ordered]@{
      aaa = @($aaa.findings).Count
      abab = @($ababa.findings).Count
      successfulReturn = @($successful.findings).Count
    }
    metadataOnly = $true
    networkAccessed = $false
    loopDetected = $aaa.result -eq 'LOOP_DETECTED' -and $ababa.result -eq 'LOOP_DETECTED'
    safety = 'All checks use in-memory metadata; no tool execution, Profile write, network access, or input mutation.'
  } | ConvertTo-Json -Depth 20
  exit 0
} catch {
  [ordered]@{
    result = 'FAIL'
    kind = 'dsh-trace-loop-test'
    error = $_.Exception.Message
    stack = $_.ScriptStackTrace
  } | ConvertTo-Json -Depth 12
  exit 1
}
