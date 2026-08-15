Set-StrictMode -Version Latest

$script:AutopsySchemaVersion = 1
$script:DefaultRetryThreshold = 3
$script:DefaultPendingChainThreshold = 2
$script:DefaultErrorRetryThreshold = 2
$script:DefaultTurnErrorThreshold = 3
$script:DefaultLongSequenceGap = 10
$script:DefaultLongIntervalSeconds = 30

Import-Module (Join-Path $PSScriptRoot 'DSH-Trace.psm1') -Force

function Get-DshTraceAutopsyProperty {
  param(
    [AllowNull()]$Object,
    [Parameter(Mandatory = $true)][string]$Name
  )
  if ($null -eq $Object) { return $null }
  if ($Object -is [System.Collections.IDictionary] -and $Object.Contains($Name)) {
    return $Object[$Name]
  }
  $property = $Object.PSObject.Properties[$Name]
  if ($null -eq $property) { return $null }
  return $property.Value
}

function Test-DshTraceAutopsyProperty {
  param(
    [AllowNull()]$Object,
    [Parameter(Mandatory = $true)][string]$Name
  )
  if ($null -eq $Object) { return $false }
  if ($Object -is [System.Collections.IDictionary]) { return $Object.Contains($Name) }
  return $null -ne $Object.PSObject.Properties[$Name]
}

function Get-DshTraceAutopsyInt {
  param([AllowNull()]$Value)
  if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) { return $null }
  try { return [int64]$Value } catch { return $null }
}

function Get-DshTraceAutopsySafeText {
  param(
    [AllowNull()][string]$Value,
    [int]$MaxLength = 180
  )
  if ($null -eq $Value) { return $null }
  return Protect-DshTraceText -Value $Value -MaxLength $MaxLength
}

function Get-DshTraceAutopsySafeCallId {
  param([AllowNull()][string]$Value)
  if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
  return Get-DshTraceAutopsySafeText -Value $Value -MaxLength 80
}

function Get-DshTraceAutopsyEvidence {
  param(
    [AllowNull()]$Seq,
    [AllowNull()][string]$CallId
  )
  return [ordered]@{
    seq = if ($null -eq $Seq) { $null } else { [int64]$Seq }
    callId = Get-DshTraceAutopsySafeCallId -Value $CallId
  }
}

function Get-DshTraceAutopsyEvidenceKey {
  param([Parameter(Mandatory = $true)]$Evidence)
  return "$(Get-DshTraceAutopsyProperty -Object $Evidence -Name 'seq')|$(Get-DshTraceAutopsyProperty -Object $Evidence -Name 'callId')"
}

function Add-DshTraceAutopsyEvidence {
  param(
    [Parameter(Mandatory = $true)]$List,
    [AllowNull()]$Seq,
    [AllowNull()][string]$CallId
  )
  $evidence = Get-DshTraceAutopsyEvidence -Seq $Seq -CallId $CallId
  $key = Get-DshTraceAutopsyEvidenceKey -Evidence $evidence
  foreach ($existing in @($List)) {
    if ((Get-DshTraceAutopsyEvidenceKey -Evidence $existing) -ceq $key) { return }
  }
  [void]$List.Add($evidence)
}

function Get-DshTraceAutopsyTimestamp {
  param([AllowNull()]$Event)
  foreach ($name in @('timestampMs', 'timeMs')) {
    $numeric = Get-DshTraceAutopsyProperty -Object $Event -Name $name
    if ($null -eq $numeric -or [string]::IsNullOrWhiteSpace([string]$numeric)) { continue }
    $milliseconds = 0.0
    if ([double]::TryParse([string]$numeric, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$milliseconds)) {
      if ($milliseconds -gt 1000000000 -and $milliseconds -lt 100000000000) { $milliseconds = $milliseconds * 1000 }
      try { return [DateTimeOffset]::FromUnixTimeMilliseconds([int64]$milliseconds).ToUniversalTime() } catch { }
    }
  }
  foreach ($name in @('timestamp', 'at', 'time', 'createdAt', 'occurredAt', 'startedAt', 'endedAt')) {
    $value = Get-DshTraceAutopsyProperty -Object $Event -Name $name
    if ($null -eq $value -or [string]::IsNullOrWhiteSpace([string]$value)) { continue }
    try { return [DateTimeOffset]::Parse([string]$value).ToUniversalTime() } catch { }
  }
  return $null
}

function Test-DshTraceAutopsyRecoveryType {
  param([AllowNull()][string]$Type)
  if ([string]::IsNullOrWhiteSpace($Type)) { return $false }
  return $Type -match '(?i)(checkpoint|fork|rewind|restore)'
}

function Test-DshTraceAutopsyStrategyType {
  param([AllowNull()][string]$Type)
  if ([string]::IsNullOrWhiteSpace($Type)) { return $false }
  if ($Type -ceq 'request/context') { return $true }
  return $Type -match '(?i)(strategy|plan|route|model[-/]?switch|checkpoint|fork|rewind|restore)'
}

function Test-DshTraceAutopsyFailureRecord {
  param([Parameter(Mandatory = $true)]$Event)
  $type = [string](Get-DshTraceAutopsyProperty -Object $Event -Name 'type')
  if ($type -ceq 'tool/result') {
    return (Get-DshTraceAutopsyProperty -Object $Event -Name 'isError') -eq $true
  }
  if ($type -ceq 'tool/code-dispatch') {
    return (Get-DshTraceAutopsyProperty -Object $Event -Name 'dispatchError') -eq $true
  }
  if ($type -ceq 'turn/end') {
    $reason = [string](Get-DshTraceAutopsyProperty -Object $Event -Name 'reasonKind')
    return $reason -match '(?i)^(error|timeout|timed-out|deadline)$'
  }
  return $false
}

function Test-DshTraceAutopsyTimeoutEvent {
  param([Parameter(Mandatory = $true)]$Event)
  $type = [string](Get-DshTraceAutopsyProperty -Object $Event -Name 'type')
  if ($type -match '(?i)(timeout|timed-out|deadline)') { return $true }
  $reason = [string](Get-DshTraceAutopsyProperty -Object $Event -Name 'reasonKind')
  if ($reason -match '(?i)(timeout|timed-out|deadline)') { return $true }
  $code = [string](Get-DshTraceAutopsyProperty -Object $Event -Name 'errorCodeObserved')
  return $code -match '(?i)(timeout|timed[-_ ]?out|deadline)'
}

function Test-DshTraceAutopsyHighRiskCall {
  param([Parameter(Mandatory = $true)]$Call)
  $permission = [string](Get-DshTraceAutopsyProperty -Object $Call -Name 'sandboxPermissionObserved')
  if ($permission -in @('danger-full-access', 'workspace-write')) { return $true }
  $name = [string](Get-DshTraceAutopsyProperty -Object $Call -Name 'name')
  return $name -match '(?i)^(bash|pwsh|powershell|shell|terminal|run[_-]?code|execute|write|delete|remove|git)([/_.:-]|$)'
}

function Get-DshTraceAutopsySignature {
  param([Parameter(Mandatory = $true)]$Call)
  $name = [string](Get-DshTraceAutopsyProperty -Object $Call -Name 'name')
  $permission = [string](Get-DshTraceAutopsyProperty -Object $Call -Name 'sandboxPermissionObserved')
  $keys = @(
    Get-DshTraceAutopsyProperty -Object $Call -Name 'argumentKeysObserved' |
      ForEach-Object { [string]$_ } |
      Sort-Object -Unique
  )
  return (($name, $permission, ($keys -join ',')) -join '|').ToLowerInvariant()
}

function Get-DshTraceAutopsyNormalizedTrace {
  param([Parameter(Mandatory = $true)]$InputObject)
  $events = @(Get-DshTraceAutopsyProperty -Object $InputObject -Name 'events')
  $normalized = $false
  if ([int](Get-DshTraceAutopsyProperty -Object $InputObject -Name 'schemaVersion') -eq 1 -and $events.Count -gt 0) {
    $first = $events[0]
    $normalized = (Test-DshTraceAutopsyProperty -Object $first -Name 'type') -and
      -not (Test-DshTraceAutopsyProperty -Object $first -Name 'event') -and
      -not (Test-DshTraceAutopsyProperty -Object $first -Name 'data')
  }
  if ($normalized) { return $InputObject }
  return ConvertTo-DshTrace -InputObject $InputObject -TraceSource 'trace-autopsy'
}

function Add-DshTraceAutopsyRegistryEntries {
  param(
    [AllowNull()]$Source,
    [Parameter(Mandatory = $true)][AllowEmptyCollection()][System.Collections.Generic.List[string]]$Names
  )
  foreach ($entry in @($Source)) {
    if ($null -eq $entry) { continue }
    if ($entry -is [string]) {
      if (-not [string]::IsNullOrWhiteSpace($entry)) { [void]$Names.Add((Get-DshTraceAutopsySafeText -Value $entry -MaxLength 180)) }
      continue
    }
    foreach ($propertyName in @('name', 'toolName', 'id')) {
      $value = [string](Get-DshTraceAutopsyProperty -Object $entry -Name $propertyName)
      if (-not [string]::IsNullOrWhiteSpace($value)) {
        [void]$Names.Add((Get-DshTraceAutopsySafeText -Value $value -MaxLength 180))
        break
      }
    }
  }
}

function Get-DshTraceAutopsyRegistryNames {
  param(
    [AllowNull()]$ToolRegistry,
    [AllowNull()]$InputObject,
    [AllowNull()]$Trace
  )
  $source = @($ToolRegistry)
  if ($source.Count -eq 0) {
    foreach ($name in @('toolRegistry', 'toolInventory', 'registry', 'availableTools', 'toolNames')) {
      $candidate = Get-DshTraceAutopsyProperty -Object $InputObject -Name $name
      if ($null -eq $candidate) { $candidate = Get-DshTraceAutopsyProperty -Object $Trace -Name $name }
      if ($null -ne $candidate) { $source = @($candidate); break }
    }
  }
  $names = [System.Collections.Generic.List[string]]::new()
  Add-DshTraceAutopsyRegistryEntries -Source $source -Names $names
  foreach ($rawEntry in @(Get-DshTraceAutopsyProperty -Object $InputObject -Name 'events')) {
    $rawEvent = Get-DshTraceAutopsyProperty -Object $rawEntry -Name 'event'
    if ($null -eq $rawEvent) { $rawEvent = $rawEntry }
    $type = [string](Get-DshTraceAutopsyProperty -Object $rawEvent -Name 'type')
    if ($type -notin @('tool/list', 'tool/available', 'tools/list', 'tool/inventory')) { continue }
    $data = Get-DshTraceAutopsyProperty -Object $rawEvent -Name 'data'
    if ($null -eq $data) { $data = $rawEvent }
    $candidate = Get-DshTraceAutopsyProperty -Object $data -Name 'tools'
    if ($null -eq $candidate) { $candidate = Get-DshTraceAutopsyProperty -Object $data -Name 'availableTools' }
    if ($null -ne $candidate) { Add-DshTraceAutopsyRegistryEntries -Source $candidate -Names $names }
  }
  return @($names | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
}

function Get-DshTraceAutopsyEventRecords {
  param(
    [Parameter(Mandatory = $true)]$Trace,
    [AllowNull()]$RawInputObject
  )
  $records = [System.Collections.Generic.List[object]]::new()
  $rawBySeq = @{}
  if ($null -ne $RawInputObject) {
    foreach ($rawEntry in @(Get-DshTraceAutopsyProperty -Object $RawInputObject -Name 'events')) {
      $rawEvent = Get-DshTraceAutopsyProperty -Object $rawEntry -Name 'event'
      if ($null -eq $rawEvent) { $rawEvent = $rawEntry }
      $rawSeq = Get-DshTraceAutopsyInt -Value (Get-DshTraceAutopsyProperty -Object $rawEvent -Name 'seq')
      if ($null -eq $rawSeq) { continue }
      $rawData = Get-DshTraceAutopsyProperty -Object $rawEvent -Name 'data'
      $rawTimestamp = Get-DshTraceAutopsyTimestamp -Event $rawEvent
      if ($null -eq $rawTimestamp) { $rawTimestamp = Get-DshTraceAutopsyTimestamp -Event $rawData }
      if ($null -ne $rawTimestamp) { $rawBySeq[[string]$rawSeq] = $rawTimestamp }
    }
  }
  $index = 0
  foreach ($event in @(Get-DshTraceAutopsyProperty -Object $Trace -Name 'events')) {
    $type = [string](Get-DshTraceAutopsyProperty -Object $event -Name 'type')
    if ([string]::IsNullOrWhiteSpace($type)) { $index++; continue }
    $seq = Get-DshTraceAutopsyInt -Value (Get-DshTraceAutopsyProperty -Object $event -Name 'seq')
    $timestamp = Get-DshTraceAutopsyTimestamp -Event $event
    if ($null -eq $timestamp) { $timestamp = Get-DshTraceAutopsyTimestamp -Event (Get-DshTraceAutopsyProperty -Object $event -Name 'data') }
    if ($null -eq $timestamp -and $rawBySeq.ContainsKey([string]$seq)) { $timestamp = $rawBySeq[[string]$seq] }
    [void]$records.Add([PSCustomObject]@{
      eventIndex = $index
      seq = $seq
      type = $type
      turn = Get-DshTraceAutopsyInt -Value (Get-DshTraceAutopsyProperty -Object $event -Name 'turn')
      step = Get-DshTraceAutopsyInt -Value (Get-DshTraceAutopsyProperty -Object $event -Name 'step')
      callId = Get-DshTraceAutopsySafeCallId -Value ([string](Get-DshTraceAutopsyProperty -Object $event -Name 'callId'))
      reasonKind = Get-DshTraceAutopsySafeText -Value ([string](Get-DshTraceAutopsyProperty -Object $event -Name 'reasonKind')) -MaxLength 100
      provider = Get-DshTraceAutopsySafeText -Value ([string](Get-DshTraceAutopsyProperty -Object $event -Name 'provider')) -MaxLength 160
      model = Get-DshTraceAutopsySafeText -Value ([string](Get-DshTraceAutopsyProperty -Object $event -Name 'model')) -MaxLength 160
      isError = (Get-DshTraceAutopsyProperty -Object $event -Name 'isError') -eq $true
      dispatchError = (Get-DshTraceAutopsyProperty -Object $event -Name 'dispatchError') -eq $true
      errorCodeObserved = Get-DshTraceAutopsySafeText -Value ([string](Get-DshTraceAutopsyProperty -Object $event -Name 'errorCodeObserved')) -MaxLength 100
      timestamp = $timestamp
    })
    $index++
  }
  return @($records)
}

function Get-DshTraceAutopsyCallRecords {
  param(
    [Parameter(Mandatory = $true)]$Trace,
    [Parameter(Mandatory = $true)][object[]]$Events
  )
  $calls = [System.Collections.Generic.List[object]]::new()
  $traceCalls = @(Get-DshTraceAutopsyProperty -Object $Trace -Name 'toolCalls')
  for ($callIndex = 0; $callIndex -lt $traceCalls.Count; $callIndex++) {
    $call = $traceCalls[$callIndex]
    $seq = Get-DshTraceAutopsyInt -Value (Get-DshTraceAutopsyProperty -Object $call -Name 'seq')
    $callId = Get-DshTraceAutopsySafeCallId -Value ([string](Get-DshTraceAutopsyProperty -Object $call -Name 'callId'))
    $eventIndex = $null
    foreach ($event in @($Events)) {
      if ([string]$event.type -cne 'tool/call') { continue }
      if ($null -ne $seq -and $null -ne $event.seq -and [int64]$event.seq -eq [int64]$seq) {
        if ($null -eq $callId -or [string]$event.callId -ceq $callId) { $eventIndex = [int]$event.eventIndex; break }
      }
    }
    if ($null -eq $eventIndex -and $callIndex -lt $Events.Count) {
      $callEvents = @($Events | Where-Object { $_.type -ceq 'tool/call' })
      if ($callIndex -lt $callEvents.Count) { $eventIndex = [int]$callEvents[$callIndex].eventIndex }
    }
    [void]$calls.Add([PSCustomObject]@{
      callIndex = $callIndex
      eventIndex = if ($null -eq $eventIndex) { $callIndex } else { $eventIndex }
      seq = $seq
      turn = Get-DshTraceAutopsyInt -Value (Get-DshTraceAutopsyProperty -Object $call -Name 'turn')
      step = Get-DshTraceAutopsyInt -Value (Get-DshTraceAutopsyProperty -Object $call -Name 'step')
      name = Get-DshTraceAutopsySafeText -Value ([string](Get-DshTraceAutopsyProperty -Object $call -Name 'name')) -MaxLength 180
      callId = $callId
      permission = Get-DshTraceAutopsySafeText -Value ([string](Get-DshTraceAutopsyProperty -Object $call -Name 'sandboxPermissionObserved')) -MaxLength 80
      signature = Get-DshTraceAutopsySignature -Call $call
    })
  }
  return @($calls)
}

function Get-DshTraceAutopsyResultForCall {
  param(
    [Parameter(Mandatory = $true)]$Call,
    [Parameter(Mandatory = $true)][object[]]$Results
  )
  if ([string]::IsNullOrWhiteSpace([string]$Call.callId)) { return $null }
  $matches = @($Results | Where-Object { [string]$_.callId -ceq [string]$Call.callId })
  if ($matches.Count -eq 0) { return $null }
  $after = @($matches | Where-Object { $null -eq $_.seq -or $null -eq $Call.seq -or [int64]$_.seq -ge [int64]$Call.seq })
  if ($after.Count -gt 0) { return $after[0] }
  return $matches[0]
}

function New-DshTraceAutopsyFinding {
  param(
    [Parameter(Mandatory = $true)][string]$Kind,
    [Parameter(Mandatory = $true)][ValidateSet('info', 'warning', 'high')][string]$Severity,
    [Parameter(Mandatory = $true)][string]$Message,
    [Parameter(Mandatory = $true)]$Evidence,
    [hashtable]$Metadata = @{}
  )
  $finding = [ordered]@{
    kind = $Kind
    severity = $Severity
    message = $Message
    evidence = @($Evidence)
  }
  foreach ($key in $Metadata.Keys) { $finding[$key] = $Metadata[$key] }
  return $finding
}

function Invoke-DshTraceAutopsy {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)]$InputObject,
    [Alias('AvailableTools', 'AvailableToolNames')][AllowNull()][object[]]$ToolRegistry = @(),
    [ValidateRange(2, 100)][int]$RetryThreshold = $script:DefaultRetryThreshold,
    [ValidateRange(1, 100)][int]$PendingChainThreshold = $script:DefaultPendingChainThreshold,
    [ValidateRange(1, 100)][int]$ErrorRetryThreshold = $script:DefaultErrorRetryThreshold,
    [ValidateRange(2, 100)][int]$TurnErrorThreshold = $script:DefaultTurnErrorThreshold,
    [ValidateRange(2, 100000)][int]$LongSequenceGap = $script:DefaultLongSequenceGap,
    [ValidateRange(1, 86400)][int]$LongIntervalSeconds = $script:DefaultLongIntervalSeconds
  )

  $trace = $null
  try { $trace = Get-DshTraceAutopsyNormalizedTrace -InputObject $InputObject }
  catch {
    return [ordered]@{
      schemaVersion = $script:AutopsySchemaVersion
      kind = 'dsh-trace-autopsy'
      status = 'INVALID'
      errors = @('trace could not be normalized')
      privacy = 'Metadata-only: no raw trace payload is returned.'
    }
  }

  $contract = Test-DshTraceContract -Trace $trace
  if (-not $contract.valid) {
    return [ordered]@{
      schemaVersion = $script:AutopsySchemaVersion
      kind = 'dsh-trace-autopsy'
      status = 'INVALID'
      input = [ordered]@{
        traceSchemaVersion = Get-DshTraceAutopsyProperty -Object $trace -Name 'schemaVersion'
        eventCount = Get-DshTraceAutopsyProperty -Object $trace -Name 'eventCount'
        hasMore = (Get-DshTraceAutopsyProperty -Object $trace -Name 'hasMore') -eq $true
      }
      contract = $contract
      findings = @()
      privacy = 'Metadata-only: no raw trace payload is returned.'
    }
  }

  $events = @(Get-DshTraceAutopsyEventRecords -Trace $trace -RawInputObject $InputObject)
  $calls = @(Get-DshTraceAutopsyCallRecords -Trace $trace -Events $events)
  $results = @(
    Get-DshTraceAutopsyProperty -Object $trace -Name 'toolResults' |
      ForEach-Object {
        [PSCustomObject]@{
          seq = Get-DshTraceAutopsyInt -Value (Get-DshTraceAutopsyProperty -Object $_ -Name 'seq')
          callId = Get-DshTraceAutopsySafeCallId -Value ([string](Get-DshTraceAutopsyProperty -Object $_ -Name 'callId'))
          isError = (Get-DshTraceAutopsyProperty -Object $_ -Name 'isError') -eq $true
          errorCodeObserved = Get-DshTraceAutopsySafeText -Value ([string](Get-DshTraceAutopsyProperty -Object $_ -Name 'errorCodeObserved')) -MaxLength 100
        }
      }
  )
  $registryNames = @(Get-DshTraceAutopsyRegistryNames -ToolRegistry $ToolRegistry -InputObject $InputObject -Trace $trace)
  $registryAvailable = $registryNames.Count -gt 0
  $findings = [System.Collections.Generic.List[object]]::new()
  $analysis = [ordered]@{}

  # A strategy boundary breaks a retry run. The actual arguments never enter
  # the signature; only the already-normalized tool metadata is considered.
  $strategyIndexes = @($events | Where-Object { Test-DshTraceAutopsyStrategyType -Type $_.type } | ForEach-Object { [int]$_.eventIndex })
  $retryFindings = [System.Collections.Generic.List[object]]::new()
  $errorRetryFindings = [System.Collections.Generic.List[object]]::new()
  $run = [System.Collections.Generic.List[object]]::new()
  $lastCall = $null
  foreach ($call in @($calls)) {
    $hasStrategy = $false
    if ($null -ne $lastCall) {
      $hasStrategy = @($strategyIndexes | Where-Object { $_ -gt [int]$lastCall.eventIndex -and $_ -le [int]$call.eventIndex }).Count -gt 0
    }
    if ($null -eq $lastCall -or $hasStrategy -or [string]$call.signature -cne [string]$lastCall.signature) {
      $run = [System.Collections.Generic.List[object]]::new()
    }
    [void]$run.Add($call)
    $runErrors = @($run | Where-Object { $result = Get-DshTraceAutopsyResultForCall -Call $_ -Results $results; $null -ne $result -and $result.isError })
    if ($run.Count -ge $RetryThreshold -and $runErrors.Count -gt 0) {
      $evidence = [System.Collections.Generic.List[object]]::new()
      foreach ($item in @($run)) { Add-DshTraceAutopsyEvidence -List $evidence -Seq $item.seq -CallId $item.callId }
      [void]$retryFindings.Add((New-DshTraceAutopsyFinding -Kind 'retry-storm' -Severity 'high' -Message 'The same metadata-level Tool Call signature repeated after an error without a strategy boundary.' -Evidence @($evidence) -Metadata @{ toolName = $call.name; attemptCount = $run.Count; errorCount = $runErrors.Count; strategyChanged = $false }))
      $run = [System.Collections.Generic.List[object]]::new()
    }
    $lastCall = $call
  }
  # Keep error-retry analysis independent from the retry-storm window. A
  # single run can legitimately satisfy both rules and must retain both facts.
  for ($baseIndex = 0; $baseIndex -lt $calls.Count; $baseIndex++) {
    $baseCall = $calls[$baseIndex]
    $baseResult = Get-DshTraceAutopsyResultForCall -Call $baseCall -Results $results
    if ($null -eq $baseResult -or -not $baseResult.isError) { continue }
    $retries = [System.Collections.Generic.List[object]]::new()
    for ($retryIndex = $baseIndex + 1; $retryIndex -lt $calls.Count; $retryIndex++) {
      $retryCall = $calls[$retryIndex]
      if ([string]$retryCall.signature -cne [string]$baseCall.signature) { break }
      if (@($strategyIndexes | Where-Object { $_ -gt [int]$baseCall.eventIndex -and $_ -le [int]$retryCall.eventIndex }).Count -gt 0) { break }
      [void]$retries.Add($retryCall)
    }
    if ($retries.Count -lt $ErrorRetryThreshold) { continue }
    $evidence = [System.Collections.Generic.List[object]]::new()
    Add-DshTraceAutopsyEvidence -List $evidence -Seq $baseCall.seq -CallId $baseCall.callId
    foreach ($retryCall in @($retries)) { Add-DshTraceAutopsyEvidence -List $evidence -Seq $retryCall.seq -CallId $retryCall.callId }
    [void]$errorRetryFindings.Add((New-DshTraceAutopsyFinding -Kind 'error-retry-without-strategy' -Severity 'high' -Message 'An isError Tool Result was followed by repeated same-signature retries without an observed strategy change.' -Evidence @($evidence) -Metadata @{ toolName = $baseCall.name; retryCount = $retries.Count; strategyChanged = $false }))
    break
  }
  foreach ($finding in @($retryFindings)) { [void]$findings.Add($finding) }
  foreach ($finding in @($errorRetryFindings)) { [void]$findings.Add($finding) }
  $analysis.retryStorms = @($retryFindings)
  $analysis.errorRetriesWithoutStrategy = @($errorRetryFindings)

  $pendingIds = @(
    Get-DshTraceAutopsyProperty -Object $trace -Name 'pendingToolCalls' |
      ForEach-Object { [string](Get-DshTraceAutopsyProperty -Object $_ -Name 'callId') } |
      Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
  )
  $pendingCalls = @($calls | Where-Object { $_.callId -in $pendingIds } | Sort-Object callIndex)
  $pendingEvidence = [System.Collections.Generic.List[object]]::new()
  foreach ($call in @($pendingCalls)) { Add-DshTraceAutopsyEvidence -List $pendingEvidence -Seq $call.seq -CallId $call.callId }
  if ($pendingEvidence.Count -eq 0) {
    foreach ($pendingId in @($pendingIds)) { Add-DshTraceAutopsyEvidence -List $pendingEvidence -Seq $null -CallId $pendingId }
  }
  $pendingFindings = [System.Collections.Generic.List[object]]::new()
  if ($pendingEvidence.Count -ge $PendingChainThreshold) {
    $severity = if ((Get-DshTraceAutopsyProperty -Object $trace -Name 'hasMore') -eq $true) { 'warning' } else { 'high' }
    [void]$pendingFindings.Add((New-DshTraceAutopsyFinding -Kind 'pending-no-result-chain' -Severity $severity -Message 'Multiple Tool Calls have no observed matching Tool Result in this trace page.' -Evidence @($pendingEvidence) -Metadata @{ pendingCount = $pendingEvidence.Count; pageIncomplete = (Get-DshTraceAutopsyProperty -Object $trace -Name 'hasMore') -eq $true }))
  }
  foreach ($finding in @($pendingFindings)) { [void]$findings.Add($finding) }
  $analysis.pendingNoResultChains = @($pendingFindings)

  $registryFindings = [System.Collections.Generic.List[object]]::new()
  if ($registryAvailable) {
    $registrySet = @{}
    foreach ($name in @($registryNames)) { $registrySet[[string]$name.ToLowerInvariant()] = $true }
    foreach ($callGroup in @($calls | Group-Object name)) {
      $toolName = [string]$callGroup.Name
      if ([string]::IsNullOrWhiteSpace($toolName) -or $registrySet.ContainsKey($toolName.ToLowerInvariant())) { continue }
      $evidence = [System.Collections.Generic.List[object]]::new()
      foreach ($call in @($callGroup.Group)) { Add-DshTraceAutopsyEvidence -List $evidence -Seq $call.seq -CallId $call.callId }
      [void]$registryFindings.Add((New-DshTraceAutopsyFinding -Kind 'tool-registry-mismatch' -Severity 'high' -Message 'A Tool Call name was not present in the supplied metadata-only Tool Registry.' -Evidence @($evidence) -Metadata @{ toolName = $toolName; registryEntryObserved = $false }))
    }
    foreach ($finding in @($registryFindings)) { [void]$findings.Add($finding) }
  }
  $analysis.toolRegistryMismatches = @($registryFindings)

  $turnFindings = [System.Collections.Generic.List[object]]::new()
  $turnRun = [System.Collections.Generic.List[object]]::new()
  foreach ($event in @($events)) {
    if ([string]$event.type -ceq 'turn/end') {
      $isTurnError = [string]$event.reasonKind -match '(?i)^(error|timeout|timed-out|deadline)$'
      if ($isTurnError) {
        [void]$turnRun.Add($event)
      } else {
        $turnRun = [System.Collections.Generic.List[object]]::new()
      }
      if ($turnRun.Count -ge $TurnErrorThreshold) {
        $evidence = [System.Collections.Generic.List[object]]::new()
        foreach ($item in @($turnRun)) { Add-DshTraceAutopsyEvidence -List $evidence -Seq $item.seq -CallId $item.callId }
        [void]$turnFindings.Add((New-DshTraceAutopsyFinding -Kind 'consecutive-turn-errors' -Severity 'high' -Message 'Consecutive turn endings reported error or timeout without an observed successful turn boundary.' -Evidence @($evidence) -Metadata @{ turnErrorCount = $turnRun.Count }))
        $turnRun = [System.Collections.Generic.List[object]]::new()
      }
    }
  }
  foreach ($finding in @($turnFindings)) { [void]$findings.Add($finding) }
  $analysis.consecutiveTurnErrors = @($turnFindings)

  $routeFindings = [System.Collections.Generic.List[object]]::new()
  $previousRoute = $null
  foreach ($context in @(Get-DshTraceAutopsyProperty -Object $trace -Name 'modelContexts')) {
    $provider = Get-DshTraceAutopsySafeText -Value ([string](Get-DshTraceAutopsyProperty -Object $context -Name 'provider')) -MaxLength 160
    $model = Get-DshTraceAutopsySafeText -Value ([string](Get-DshTraceAutopsyProperty -Object $context -Name 'model')) -MaxLength 160
    $route = "$provider/$model"
    if ($null -ne $previousRoute -and [string]$route -cne [string]$previousRoute.route) {
      $evidence = [System.Collections.Generic.List[object]]::new()
      Add-DshTraceAutopsyEvidence -List $evidence -Seq $previousRoute.seq -CallId $null
      Add-DshTraceAutopsyEvidence -List $evidence -Seq (Get-DshTraceAutopsyInt -Value (Get-DshTraceAutopsyProperty -Object $context -Name 'seq')) -CallId $null
      [void]$routeFindings.Add((New-DshTraceAutopsyFinding -Kind 'model-provider-switch' -Severity 'warning' -Message 'The observed model/provider route changed within the trace.' -Evidence @($evidence) -Metadata @{ fromRoute = $previousRoute.route; toRoute = $route }))
    }
    $previousRoute = [PSCustomObject]@{ route = $route; seq = Get-DshTraceAutopsyInt -Value (Get-DshTraceAutopsyProperty -Object $context -Name 'seq') }
  }
  foreach ($finding in @($routeFindings)) { [void]$findings.Add($finding) }
  $analysis.modelProviderSwitches = @($routeFindings)

  $timingFindings = [System.Collections.Generic.List[object]]::new()
  $previousEvent = $null
  $timestampObserved = $false
  foreach ($event in @($events)) {
    if (Test-DshTraceAutopsyTimeoutEvent -Event $event) {
      $evidence = [System.Collections.Generic.List[object]]::new()
      Add-DshTraceAutopsyEvidence -List $evidence -Seq $event.seq -CallId $event.callId
      [void]$timingFindings.Add((New-DshTraceAutopsyFinding -Kind 'timeout-event' -Severity 'high' -Message 'A timeout, deadline, or timed-out metadata marker was observed.' -Evidence @($evidence) -Metadata @{ timeoutMarker = $true }))
    }
    if ($null -ne $previousEvent -and $null -ne $previousEvent.timestamp -and $null -ne $event.timestamp) {
      $timestampObserved = $true
      $duration = ($event.timestamp - $previousEvent.timestamp).TotalSeconds
      if ($duration -ge $LongIntervalSeconds) {
        $evidence = [System.Collections.Generic.List[object]]::new()
        Add-DshTraceAutopsyEvidence -List $evidence -Seq $previousEvent.seq -CallId $previousEvent.callId
        Add-DshTraceAutopsyEvidence -List $evidence -Seq $event.seq -CallId $event.callId
        [void]$timingFindings.Add((New-DshTraceAutopsyFinding -Kind 'long-interval' -Severity 'warning' -Message 'The metadata timestamps contain an interval above the configured bound.' -Evidence @($evidence) -Metadata @{ durationSeconds = [Math]::Round($duration, 3); thresholdSeconds = $LongIntervalSeconds; basis = 'timestamp' }))
      }
    } elseif ($null -ne $previousEvent -and $null -ne $previousEvent.seq -and $null -ne $event.seq) {
      $gap = [int64]$event.seq - [int64]$previousEvent.seq
      if ($gap -ge $LongSequenceGap) {
        $evidence = [System.Collections.Generic.List[object]]::new()
        Add-DshTraceAutopsyEvidence -List $evidence -Seq $previousEvent.seq -CallId $previousEvent.callId
        Add-DshTraceAutopsyEvidence -List $evidence -Seq $event.seq -CallId $event.callId
        [void]$timingFindings.Add((New-DshTraceAutopsyFinding -Kind 'long-sequence-gap' -Severity 'warning' -Message 'The trace has a large sequence gap; without timestamps this is not proof of wall-clock latency.' -Evidence @($evidence) -Metadata @{ sequenceGap = $gap; threshold = $LongSequenceGap; basis = 'sequence' }))
      }
    }
    $previousEvent = $event
  }
  foreach ($finding in @($timingFindings)) { [void]$findings.Add($finding) }
  $analysis.timingAnomalies = @($timingFindings)

  $callByEventIndex = @{}
  foreach ($call in @($calls)) { $callByEventIndex[[int]$call.eventIndex] = $call }
  $unrecoveredFailure = $null
  $unrecoveredHighRisk = [System.Collections.Generic.List[object]]::new()
  $highRiskFindings = [System.Collections.Generic.List[object]]::new()
  foreach ($event in @($events)) {
    if (Test-DshTraceAutopsyFailureRecord -Event $event) {
      if ($null -eq $unrecoveredFailure) {
        $unrecoveredFailure = Get-DshTraceAutopsyEvidence -Seq $event.seq -CallId $event.callId
      }
    }
    if (Test-DshTraceAutopsyRecoveryType -Type $event.type) {
      if ($unrecoveredHighRisk.Count -gt 0) {
        $unrecoveredFailure = $null
        $unrecoveredHighRisk = [System.Collections.Generic.List[object]]::new()
      } else {
        $unrecoveredFailure = $null
      }
    }
    if ($callByEventIndex.ContainsKey([int]$event.eventIndex)) {
      $call = $callByEventIndex[[int]$event.eventIndex]
      if ($null -ne $unrecoveredFailure -and (Test-DshTraceAutopsyHighRiskCall -Call $call)) {
        [void]$unrecoveredHighRisk.Add($call)
      }
    }
  }
  if ($null -ne $unrecoveredFailure -and $unrecoveredHighRisk.Count -gt 0) {
    $evidence = [System.Collections.Generic.List[object]]::new()
    Add-DshTraceAutopsyEvidence -List $evidence -Seq $unrecoveredFailure.seq -CallId $unrecoveredFailure.callId
    foreach ($call in @($unrecoveredHighRisk)) { Add-DshTraceAutopsyEvidence -List $evidence -Seq $call.seq -CallId $call.callId }
    [void]$highRiskFindings.Add((New-DshTraceAutopsyFinding -Kind 'high-risk-after-failure-without-checkpoint-or-fork' -Severity 'high' -Message 'A high-risk Tool Call continued after a failure before any checkpoint or fork marker was observed.' -Evidence @($evidence) -Metadata @{ highRiskCallCount = $unrecoveredHighRisk.Count; recoveryMarkerObserved = $false }))
  }
  foreach ($finding in @($highRiskFindings)) { [void]$findings.Add($finding) }
  $analysis.highRiskAfterFailure = @($highRiskFindings)

  $inconclusiveChecks = [System.Collections.Generic.List[string]]::new()
  if (-not $registryAvailable) { [void]$inconclusiveChecks.Add('tool-registry-not-provided; mismatch analysis was not requested') }
  if (-not $timestampObserved) { [void]$inconclusiveChecks.Add('wall-clock-timestamps-not-observed; sequence gaps are only a proxy for long intervals') }
  $summary = [ordered]@{
    eventCount = @($events).Count
    toolCallCount = @($calls).Count
    toolResultCount = @($results).Count
    pendingCount = @($pendingEvidence).Count
    findingCount = $findings.Count
    highSeverityCount = @($findings | Where-Object { $_.severity -ceq 'high' }).Count
    inconclusiveCheckCount = $inconclusiveChecks.Count
  }
  $status = if ($findings.Count -gt 0) { 'FINDINGS' } elseif ($inconclusiveChecks.Count -gt 0) { 'INCONCLUSIVE' } else { 'CLEAN' }
  return [ordered]@{
    schemaVersion = $script:AutopsySchemaVersion
    kind = 'dsh-trace-autopsy'
    status = $status
    input = [ordered]@{
      traceSchemaVersion = Get-DshTraceAutopsyProperty -Object $trace -Name 'schemaVersion'
      source = Get-DshTraceAutopsySafeText -Value ([string](Get-DshTraceAutopsyProperty -Object $trace -Name 'source')) -MaxLength 120
      eventCount = Get-DshTraceAutopsyProperty -Object $trace -Name 'eventCount'
      hasMore = (Get-DshTraceAutopsyProperty -Object $trace -Name 'hasMore') -eq $true
      coverage = if ((Get-DshTraceAutopsyProperty -Object $trace -Name 'hasMore') -eq $true) { 'bounded-page' } else { 'complete-page' }
    }
    summary = $summary
    checks = [ordered]@{
      toolRegistry = if ($registryAvailable) { 'observed' } else { 'not-provided' }
      timestamps = if ($timestampObserved) { 'observed' } else { 'not-observed' }
      highRiskPermissions = @('workspace-write', 'danger-full-access')
    }
    findings = @($findings)
    analysis = $analysis
    inconclusiveChecks = @($inconclusiveChecks)
    privacy = 'Metadata-only: evidence contains only seq and callId. Tool names, model/provider labels, permission enums, counts, booleans, and bounded error codes may be reported. Command text, argument values, result bodies, credentials, cookies, authorization headers, and cwd are never returned.'
  }
}

function Test-DshTraceAutopsyOutput {
  param([Parameter(Mandatory = $true)]$Report)
  $errors = [System.Collections.Generic.List[string]]::new()
  if ([int](Get-DshTraceAutopsyProperty -Object $Report -Name 'schemaVersion') -ne $script:AutopsySchemaVersion) { [void]$errors.Add('unsupported autopsy schemaVersion') }
  foreach ($finding in @(Get-DshTraceAutopsyProperty -Object $Report -Name 'findings')) {
    foreach ($evidence in @(Get-DshTraceAutopsyProperty -Object $finding -Name 'evidence')) {
      $names = if ($evidence -is [System.Collections.IDictionary]) { @($evidence.Keys | ForEach-Object { [string]$_ } | Sort-Object) } else { @($evidence.PSObject.Properties.Name | Sort-Object) }
      if ((@($names) -join ',') -cne 'callId,seq') { [void]$errors.Add('finding evidence must contain only seq and callId') }
    }
  }
  return [ordered]@{ valid = $errors.Count -eq 0; errors = @($errors) }
}

Export-ModuleMember -Function @(
  'Invoke-DshTraceAutopsy',
  'Test-DshTraceAutopsyOutput'
)
