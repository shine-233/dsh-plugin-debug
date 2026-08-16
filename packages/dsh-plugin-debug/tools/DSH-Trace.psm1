Set-StrictMode -Version Latest

$script:DshTraceSchemaVersion = 1
$script:DshTraceMaxEvents = 1000
$script:DshTraceMaxAssertions = 64

function Get-DshTraceProperty {
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

function Test-DshTraceProperty {
  param(
    [AllowNull()]$Object,
    [Parameter(Mandatory = $true)][string]$Name
  )
  if ($null -eq $Object) { return $false }
  if ($Object -is [System.Collections.IDictionary]) { return $Object.Contains($Name) }
  return $null -ne $Object.PSObject.Properties[$Name]
}

function Get-DshTraceInt {
  param([AllowNull()]$Value)
  if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) { return $null }
  try { return [int]$Value } catch { return $null }
}

function Get-DshTraceTimestamp {
  param([AllowNull()]$Value)
  if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) { return $null }
  $parsed = [DateTimeOffset]::MinValue
  $styles = [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal
  if ([DateTimeOffset]::TryParse([string]$Value, [Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$parsed)) {
    return $parsed
  }
  return $null
}

function Protect-DshTraceText {
  param(
    [AllowNull()][string]$Value,
    [int]$MaxLength = 600
  )
  if ($null -eq $Value) { return $null }
  $result = $Value
  $result = $result -replace '(?i)(authorization|cookie|set-cookie|api[_-]?key|access[_-]?token|refresh[_-]?token|password|secret|token)[ \t]*[:=][ \t]*("[^"]*"|''[^'']*''|[^ \t,;}]+)', '$1=<redacted>'
  $result = $result -replace '(?i)bearer[ \t]+[A-Za-z0-9._~+/=-]+', 'Bearer <redacted>'
  $result = $result -replace '(?i)[A-Z]:\\[^ \t;,)]+', '<path>'
  $result = $result -replace '(?i)https?://[^ \t"''<>]+', '<url>'
  if ($result.Length -gt $MaxLength) { return $result.Substring(0, [Math]::Max(0, $MaxLength - 3)) + '...' }
  return $result
}

function Get-DshTraceSafeCallId {
  param([AllowNull()][string]$Value)
  if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
  return Protect-DshTraceText -Value $Value -MaxLength 80
}

function Get-DshTraceArgumentKeys {
  param([AllowNull()]$Arguments)
  if ($null -eq $Arguments) { return @() }
  if ($Arguments -is [System.Collections.IDictionary]) {
    return @($Arguments.Keys | ForEach-Object { [string]$_ } | Sort-Object -Unique)
  }
  return @($Arguments.PSObject.Properties | ForEach-Object { [string]$_.Name } | Sort-Object -Unique)
}

function Get-DshTracePermission {
  param([AllowNull()]$Arguments)
  if ($null -eq $Arguments) { return $null }
  $property = Get-DshTraceProperty -Object $Arguments -Name 'sandbox_permissions'
  if ($null -eq $property -and (Test-DshTraceProperty -Object $Arguments -Name 'sandboxPermissions')) {
    $property = Get-DshTraceProperty -Object $Arguments -Name 'sandboxPermissions'
  }
  if ($null -eq $property) { return $null }
  $raw = [string]$property
  switch ($raw) {
    'read-only' { return 'read-only' }
    'workspace-write' { return 'workspace-write' }
    'danger-full-access' { return 'danger-full-access' }
    'ask' { return 'ask' }
    default {
      if ([string]::IsNullOrWhiteSpace($raw)) { return 'empty' }
      return 'unrecognized'
    }
  }
}

function Get-DshTraceRawEvents {
  param([Parameter(Mandatory = $true)]$InputObject)
  if ($InputObject -is [System.Collections.IEnumerable] -and $InputObject -isnot [string] -and
      -not (Test-DshTraceProperty -Object $InputObject -Name 'events')) {
    return @($InputObject)
  }
  $events = Get-DshTraceProperty -Object $InputObject -Name 'events'
  if ($null -eq $events) {
    $observation = Get-DshTraceProperty -Object $InputObject -Name 'toolCallObservation'
    $session = Get-DshTraceProperty -Object $observation -Name 'session'
    $events = Get-DshTraceProperty -Object $session -Name 'events'
  }
  return @($events)
}

function ConvertTo-DshTrace {
  param(
    [Parameter(Mandatory = $true)]$InputObject,
    [string]$TraceSource = ''
  )
  $rawEvents = @(Get-DshTraceRawEvents -InputObject $InputObject)
  if ($rawEvents.Count -gt $script:DshTraceMaxEvents) { throw "trace contains more than $script:DshTraceMaxEvents events" }

  $rows = [System.Collections.Generic.List[object]]::new()
  $toolCalls = [System.Collections.Generic.List[object]]::new()
  $toolResults = [System.Collections.Generic.List[object]]::new()
  $dispatchErrors = [System.Collections.Generic.List[object]]::new()
  $turnErrors = [System.Collections.Generic.List[object]]::new()
  $modelContexts = [System.Collections.Generic.List[object]]::new()
  $calls = @{}
  $results = @{}
  $counts = @{}
  $firstEventTimestamp = $null

  foreach ($entry in $rawEvents) {
    $event = Get-DshTraceProperty -Object $entry -Name 'event'
    if ($null -eq $event) { $event = $entry }
    if ($null -eq $event) { continue }
    $type = [string](Get-DshTraceProperty -Object $event -Name 'type')
    if ([string]::IsNullOrWhiteSpace($type)) { continue }
    if (-not $counts.ContainsKey($type)) { $counts[$type] = 0 }
    $counts[$type] = [int]$counts[$type] + 1
    $data = Get-DshTraceProperty -Object $event -Name 'data'
    $seq = Get-DshTraceInt -Value (Get-DshTraceProperty -Object $event -Name 'seq')
    $turn = Get-DshTraceInt -Value (Get-DshTraceProperty -Object $data -Name 'turn')
    $step = Get-DshTraceInt -Value (Get-DshTraceProperty -Object $data -Name 'step')
    $row = [ordered]@{ seq = $seq; type = $type; turn = $turn; step = $step }
    $rawTimestamp = Get-DshTraceProperty -Object $data -Name 'timestamp'
    if ($null -eq $rawTimestamp) { $rawTimestamp = Get-DshTraceProperty -Object $data -Name 'createdAt' }
    if ($null -eq $rawTimestamp) { $rawTimestamp = Get-DshTraceProperty -Object $event -Name 'timestamp' }
    $eventTimestamp = Get-DshTraceTimestamp -Value $rawTimestamp
    $timeOffsetMs = $null
    if ($null -ne $eventTimestamp) {
      if ($null -eq $firstEventTimestamp) { $firstEventTimestamp = $eventTimestamp }
      $timeOffsetMs = [long][Math]::Round(($eventTimestamp - $firstEventTimestamp).TotalMilliseconds)
      $row.timeOffsetMs = $timeOffsetMs
    }

    switch ($type) {
      'request/context' {
        $provider = Protect-DshTraceText -Value ([string](Get-DshTraceProperty -Object $data -Name 'provider')) -MaxLength 160
        $model = Protect-DshTraceText -Value ([string](Get-DshTraceProperty -Object $data -Name 'model')) -MaxLength 160
        $row.provider = $provider
        $row.model = $model
        [void]$modelContexts.Add([ordered]@{ seq = $seq; provider = $provider; model = $model })
      }
      'tool/call' {
        $rawCallId = [string](Get-DshTraceProperty -Object $data -Name 'callId')
        if (-not [string]::IsNullOrWhiteSpace($rawCallId)) { $calls[$rawCallId] = $true }
        $rawArgumentsPresent = Test-DshTraceProperty -Object $data -Name 'arguments'
        $metadataKeysPresent = Test-DshTraceProperty -Object $data -Name 'argumentKeysObserved'
        $metadataPermissionPresent = Test-DshTraceProperty -Object $data -Name 'sandboxPermissionObserved'
        $argumentExists = $rawArgumentsPresent -or $metadataKeysPresent -or $metadataPermissionPresent
        $arguments = Get-DshTraceProperty -Object $data -Name 'arguments'
        $argumentKeys = if ($rawArgumentsPresent) {
          @(Get-DshTraceArgumentKeys -Arguments $arguments)
        } elseif ($metadataKeysPresent) {
          @(Get-DshTraceProperty -Object $data -Name 'argumentKeysObserved' | ForEach-Object { Protect-DshTraceText -Value ([string]$_) -MaxLength 100 } | Sort-Object -Unique)
        } else { @() }
        $permission = if ($rawArgumentsPresent) {
          Get-DshTracePermission -Arguments $arguments
        } elseif ($metadataPermissionPresent) {
          Protect-DshTraceText -Value ([string](Get-DshTraceProperty -Object $data -Name 'sandboxPermissionObserved')) -MaxLength 80
        } else { $null }
        $name = Protect-DshTraceText -Value ([string](Get-DshTraceProperty -Object $data -Name 'name')) -MaxLength 180
        $call = [ordered]@{
          seq = $seq
          turn = $turn
          step = $step
          name = $name
          callId = Get-DshTraceSafeCallId -Value $rawCallId
          argumentsObserved = $argumentExists
          argumentKeysObserved = $argumentKeys
          sandboxPermissionObserved = $permission
        }
        if ($null -ne $timeOffsetMs) { $call.timeOffsetMs = $timeOffsetMs }
        [void]$toolCalls.Add($call)
        $row.name = $name
        $row.callId = $call.callId
        $row.argumentsObserved = $argumentExists
        $row.argumentKeysObserved = $argumentKeys
        $row.sandboxPermissionObserved = $permission
      }
      'tool/result' {
        $message = Get-DshTraceProperty -Object $data -Name 'message'
        $messageSource = Get-DshTraceProperty -Object $message -Name 'source'
        $rawCallId = [string](Get-DshTraceProperty -Object $messageSource -Name 'callId')
        if ([string]::IsNullOrWhiteSpace($rawCallId)) { $rawCallId = [string](Get-DshTraceProperty -Object $data -Name 'callId') }
        if (-not [string]::IsNullOrWhiteSpace($rawCallId)) { $results[$rawCallId] = $true }
        $content = Get-DshTraceProperty -Object $message -Name 'content'
        $blocks = @($content | Where-Object { [string](Get-DshTraceProperty -Object $_ -Name 'type') -eq 'tool-result' })
        $isError = @($blocks | Where-Object { (Get-DshTraceProperty -Object $_ -Name 'isError') -eq $true }).Count -gt 0 -or
          (Get-DshTraceProperty -Object $data -Name 'isError') -eq $true -or
          (Get-DshTraceProperty -Object $data -Name 'isErrorObserved') -eq $true
        $error = Get-DshTraceProperty -Object $data -Name 'error'
        $errorObserved = ($null -ne $error) -or ((Get-DshTraceProperty -Object $data -Name 'errorObjectObserved') -eq $true)
        $errorCode = if ($null -ne $error) {
          Get-DshTraceProperty -Object $error -Name 'code'
        } else {
          Get-DshTraceProperty -Object $data -Name 'errorCodeObserved'
        }
        $result = [ordered]@{
          seq = $seq
          turn = $turn
          step = $step
          callId = Get-DshTraceSafeCallId -Value $rawCallId
          isError = $isError
          errorObjectObserved = $errorObserved
          errorCodeObserved = Protect-DshTraceText -Value ([string]$errorCode) -MaxLength 100
        }
        if ($null -ne $timeOffsetMs) { $result.timeOffsetMs = $timeOffsetMs }
        [void]$toolResults.Add($result)
        $row.callId = $result.callId
        $row.isError = $isError
        $row.errorObjectObserved = $result.errorObjectObserved
        $row.errorCodeObserved = $result.errorCodeObserved
      }
      'tool/code-dispatch' {
        if ((Get-DshTraceProperty -Object $data -Name 'isError') -eq $true) {
          $dispatch = [ordered]@{
            seq = $seq
            name = Protect-DshTraceText -Value ([string](Get-DshTraceProperty -Object $data -Name 'name')) -MaxLength 180
            error = $true
          }
          [void]$dispatchErrors.Add($dispatch)
          $row.dispatchError = $true
        }
      }
      'turn/end' {
        $reason = Get-DshTraceProperty -Object (Get-DshTraceProperty -Object $data -Name 'reason') -Name 'kind'
        $reasonKind = Protect-DshTraceText -Value ([string]$reason) -MaxLength 100
        $row.reasonKind = $reasonKind
        if ($reasonKind -ceq 'error') {
          [void]$turnErrors.Add([ordered]@{ seq = $seq; turn = $turn; reason = 'error' })
        }
      }
    }
    [void]$rows.Add($row)
  }

  $pending = [System.Collections.Generic.List[object]]::new()
  foreach ($rawCallId in @($calls.Keys)) {
    if (-not $results.ContainsKey($rawCallId)) {
      [void]$pending.Add([ordered]@{ callId = Get-DshTraceSafeCallId -Value ([string]$rawCallId) })
    }
  }
  $sourceValue = Get-DshTraceProperty -Object $InputObject -Name 'source'
  if ([string]::IsNullOrWhiteSpace($TraceSource)) { $TraceSource = if ([string]::IsNullOrWhiteSpace([string]$sourceValue)) { 'session.history' } else { [string]$sourceValue } }
  $sessionId = Get-DshTraceProperty -Object $InputObject -Name 'sessionId'
  if ($null -eq $sessionId) {
    $sessionId = Get-DshTraceProperty -Object (Get-DshTraceProperty -Object (Get-DshTraceProperty -Object $InputObject -Name 'toolCallObservation') -Name 'session') -Name 'sessionId'
  }
  $hasMore = Get-DshTraceProperty -Object $InputObject -Name 'hasMore'
  if ($null -eq $hasMore) { $hasMore = Get-DshTraceProperty -Object (Get-DshTraceProperty -Object $InputObject -Name 'toolCallObservation') -Name 'session' | ForEach-Object { Get-DshTraceProperty -Object $_ -Name 'hasMore' } }

  return [ordered]@{
    schemaVersion = $script:DshTraceSchemaVersion
    source = Protect-DshTraceText -Value $TraceSource -MaxLength 120
    sessionId = Get-DshTraceSafeCallId -Value ([string]$sessionId)
    hasMore = $hasMore -eq $true
    eventCount = $rows.Count
    eventCounts = @($counts.GetEnumerator() | Sort-Object Name | ForEach-Object { [ordered]@{ type = [string]$_.Key; count = [int]$_.Value } })
    modelContexts = @($modelContexts)
    toolCalls = @($toolCalls)
    toolResults = @($toolResults)
    codeDispatchErrors = @($dispatchErrors)
    turnErrors = @($turnErrors)
    pendingToolCalls = @($pending)
    toolCallStats = [ordered]@{
      callCount = $toolCalls.Count
      resultCount = $toolResults.Count
      errorResultCount = @($toolResults | Where-Object { $_.isError }).Count
      dispatchErrorCount = $dispatchErrors.Count
      turnErrorCount = $turnErrors.Count
      pendingCount = $pending.Count
      completionRatio = if ($toolCalls.Count -eq 0) { $null } else { [Math]::Round($toolResults.Count / $toolCalls.Count, 3) }
    }
    events = @($rows)
    privacy = 'Metadata only: event type, tool name, argument key names, bounded permission enum, model route, and error booleans. Arguments, command text, result bodies, credentials, cookies, authorization headers, and full cwd are omitted.'
  }
}

function Test-DshTraceContract {
  param([Parameter(Mandatory = $true)]$Trace)
  $errors = [System.Collections.Generic.List[string]]::new()
  $warnings = [System.Collections.Generic.List[string]]::new()
  if ([int](Get-DshTraceProperty -Object $Trace -Name 'schemaVersion') -ne $script:DshTraceSchemaVersion) { [void]$errors.Add('unsupported trace schemaVersion') }
  $events = @(Get-DshTraceProperty -Object $Trace -Name 'events')
  if ($events.Count -gt $script:DshTraceMaxEvents) { [void]$errors.Add('trace events exceed the bounded maximum') }
  $forbidden = @('arguments', 'resultBody', 'content', 'message', 'raw', 'cwd', 'command', 'script')
  foreach ($event in $events) {
    if ([string]::IsNullOrWhiteSpace([string](Get-DshTraceProperty -Object $event -Name 'type'))) { [void]$errors.Add('an event is missing type') }
    foreach ($property in @($event.PSObject.Properties.Name)) {
      if ($property -in $forbidden) { [void]$errors.Add("event contains forbidden raw property '$property'") }
    }
  }
  $stats = Get-DshTraceProperty -Object $Trace -Name 'toolCallStats'
  foreach ($name in @('callCount', 'resultCount', 'errorResultCount', 'dispatchErrorCount', 'turnErrorCount', 'pendingCount')) {
    if (-not (Test-DshTraceProperty -Object $stats -Name $name)) { [void]$errors.Add("toolCallStats.$name is missing") }
  }
  if (@(Get-DshTraceProperty -Object $Trace -Name 'toolCalls').Count -ne [int](Get-DshTraceProperty -Object $stats -Name 'callCount')) { [void]$errors.Add('toolCallStats.callCount does not match toolCalls') }
  if (@(Get-DshTraceProperty -Object $Trace -Name 'toolResults').Count -ne [int](Get-DshTraceProperty -Object $stats -Name 'resultCount')) { [void]$errors.Add('toolCallStats.resultCount does not match toolResults') }
  if ($events.Count -eq 0) { [void]$warnings.Add('trace contains no events') }
  return [ordered]@{ valid = $errors.Count -eq 0; errors = @($errors); warnings = @($warnings) }
}

function Get-DshTracePathValues {
  param(
    [Parameter(Mandatory = $true)]$Object,
    [Parameter(Mandatory = $true)][string]$Path
  )
  $current = [System.Collections.Generic.List[object]]::new()
  [void]$current.Add($Object)
  foreach ($segment in @($Path -split '\.')) {
    if ([string]::IsNullOrWhiteSpace($segment)) { continue }
    $match = [regex]::Match($segment, '^(?<name>[^\[]+)(?:\[(?<index>\*|\d+)\])?$')
    if (-not $match.Success) { return @() }
    $name = $match.Groups['name'].Value
    $index = if ($match.Groups['index'].Success) { $match.Groups['index'].Value } else { $null }
    $next = [System.Collections.Generic.List[object]]::new()
    foreach ($item in @($current)) {
      $value = Get-DshTraceProperty -Object $item -Name $name
      if (-not $match.Groups['index'].Success) {
        if ($null -ne $value) { [void]$next.Add($value) }
        continue
      }
      $items = @($value)
      if ($index -eq '*') {
        foreach ($child in $items) { [void]$next.Add($child) }
      } elseif ($index -match '^\d+$' -and [int]$index -lt $items.Count) {
        [void]$next.Add($items[[int]$index])
      }
    }
    $current = $next
  }
  return @($current)
}

function Test-DshTraceEqual {
  param([AllowNull()]$Observed, [AllowNull()]$Expected)
  if ($null -eq $Observed -and $null -eq $Expected) { return $true }
  if ($null -eq $Observed -or $null -eq $Expected) { return $false }
  if ($Observed -is [bool] -or $Expected -is [bool]) { return ([bool]$Observed -eq [bool]$Expected) }
  return ([string]$Observed -ceq [string]$Expected)
}

function Test-DshTraceCase {
  param([Parameter(Mandatory = $true)]$Case)
  $errors = [System.Collections.Generic.List[string]]::new()
  if ([int](Get-DshTraceProperty -Object $Case -Name 'schemaVersion') -ne 1) { [void]$errors.Add('unsupported case schemaVersion') }
  $assertions = @(Get-DshTraceProperty -Object $Case -Name 'assertions')
  if ($assertions.Count -gt $script:DshTraceMaxAssertions) { [void]$errors.Add('case contains too many assertions') }
  $forbidden = @('command', 'commands', 'script', 'shell', 'args', 'arguments', 'url', 'cwd', 'expression', 'eval', 'code')
  foreach ($assertion in $assertions) {
    foreach ($property in @($assertion.PSObject.Properties.Name)) {
      if ($property -in $forbidden) { [void]$errors.Add("assertion contains forbidden property '$property'") }
    }
    $kind = [string](Get-DshTraceProperty -Object $assertion -Name 'kind')
    if ($kind -notin @('equals', 'contains', 'atLeast', 'eventSequence')) { [void]$errors.Add("unsupported assertion kind: $kind") }
  }
  return [ordered]@{ valid = $errors.Count -eq 0; errors = @($errors) }
}

function Invoke-DshTraceEvaluation {
  param(
    [Parameter(Mandatory = $true)]$Trace,
    [Parameter(Mandatory = $true)]$Case
  )
  $contract = Test-DshTraceContract -Trace $Trace
  $caseCheck = Test-DshTraceCase -Case $Case
  if (-not $contract.valid -or -not $caseCheck.valid) {
    return [ordered]@{
      status = 'FAIL'
      contract = $contract
      case = $caseCheck
      assertions = @()
      privacy = 'No raw trace or assertion values are emitted by the evaluator.'
    }
  }
  $results = [System.Collections.Generic.List[object]]::new()
  $index = 0
  foreach ($assertion in @(Get-DshTraceProperty -Object $Case -Name 'assertions')) {
    $index++
    $kind = [string](Get-DshTraceProperty -Object $assertion -Name 'kind')
    $path = [string](Get-DshTraceProperty -Object $assertion -Name 'path')
    $expected = if (Test-DshTraceProperty -Object $assertion -Name 'expected') { Get-DshTraceProperty -Object $assertion -Name 'expected' } else { Get-DshTraceProperty -Object $assertion -Name 'value' }
    $pass = $false
    $observed = @()
    $message = ''
    if ($kind -eq 'eventSequence') {
      $expectedTypes = @($expected)
      $eventTypes = @((Get-DshTraceProperty -Object $Trace -Name 'events') | ForEach-Object { [string](Get-DshTraceProperty -Object $_ -Name 'type') })
      $cursor = 0
      foreach ($eventType in $eventTypes) {
        if ($cursor -lt $expectedTypes.Count -and [string]$eventType -ceq [string]$expectedTypes[$cursor]) { $cursor++ }
      }
      $pass = $cursor -eq $expectedTypes.Count
      $observed = @($eventTypes | Select-Object -First 20)
      $message = if ($pass) { 'event sequence observed in order' } else { 'expected event sequence was not observed in order' }
    } else {
      $values = @(Get-DshTracePathValues -Object $Trace -Path $path)
      $observed = @($values | Select-Object -First 10 | ForEach-Object { Protect-DshTraceText -Value ([string]$_) -MaxLength 160 })
      switch ($kind) {
        'equals' { $pass = @($values | Where-Object { Test-DshTraceEqual -Observed $_ -Expected $expected }).Count -gt 0; $message = 'at least one value equals expected' }
        'contains' { $pass = @($values | Where-Object { ([string]$_) -like "*$([string]$expected)*" }).Count -gt 0; $message = 'at least one value contains expected text' }
        'atLeast' {
          $number = 0
          if ($values.Count -gt 0) { try { $number = [double]$values[0] } catch { $number = 0 } }
          try { $pass = $number -ge [double]$expected } catch { $pass = $false }
          $message = 'numeric value meets minimum'
        }
      }
    }
    [void]$results.Add([ordered]@{ index = $index; kind = $kind; path = Protect-DshTraceText -Value $path -MaxLength 160; expected = Protect-DshTraceText -Value ([string]$expected) -MaxLength 160; observed = @($observed); pass = $pass; message = $message })
  }
  $failed = @($results | Where-Object { $_.pass -ne $true })
  return [ordered]@{
    status = if ($failed.Count -eq 0) { 'PASS' } else { 'FAIL' }
    contract = $contract
    case = [ordered]@{ name = Protect-DshTraceText -Value ([string](Get-DshTraceProperty -Object $Case -Name 'name')) -MaxLength 160; assertionCount = $results.Count }
    assertions = @($results)
    failedCount = $failed.Count
    privacy = 'Metadata-only evaluation; the evaluator never returns Tool arguments, command text, Tool result bodies, credentials, cookies, authorization headers, or full cwd.'
  }
}

function Compare-DshTraceBaseline {
  param(
    [Parameter(Mandatory = $true)]$Current,
    [Parameter(Mandatory = $true)]$Baseline,
    [switch]$Strict
  )
  $currentContract = Test-DshTraceContract -Trace $Current
  $baselineContract = Test-DshTraceContract -Trace $Baseline
  $errors = [System.Collections.Generic.List[string]]::new()
  $warnings = [System.Collections.Generic.List[string]]::new()
  $changes = [System.Collections.Generic.List[object]]::new()
  if (-not $currentContract.valid) { [void]$errors.Add('current trace contract is invalid') }
  if (-not $baselineContract.valid) { [void]$errors.Add('baseline trace contract is invalid') }

  $currentStats = Get-DshTraceProperty -Object $Current -Name 'toolCallStats'
  $baselineStats = Get-DshTraceProperty -Object $Baseline -Name 'toolCallStats'
  foreach ($name in @('callCount', 'resultCount', 'errorResultCount', 'dispatchErrorCount', 'turnErrorCount', 'pendingCount')) {
    $currentValue = [int](Get-DshTraceProperty -Object $currentStats -Name $name)
    $baselineValue = [int](Get-DshTraceProperty -Object $baselineStats -Name $name)
    $delta = $currentValue - $baselineValue
    if ($delta -ne 0) {
      [void]$changes.Add([ordered]@{ metric = $name; baseline = $baselineValue; current = $currentValue; delta = $delta })
    }
    if ($name -in @('errorResultCount', 'dispatchErrorCount', 'turnErrorCount', 'pendingCount') -and $delta -gt 0) {
      [void]$errors.Add("$name increased by $delta")
    }
  }

  $baselineContexts = @(Get-DshTraceProperty -Object $Baseline -Name 'modelContexts')
  $currentContexts = @(Get-DshTraceProperty -Object $Current -Name 'modelContexts')
  $baselineRoute = if ($baselineContexts.Count -gt 0) { "$(Get-DshTraceProperty -Object $baselineContexts[0] -Name 'provider')/$(Get-DshTraceProperty -Object $baselineContexts[0] -Name 'model')" } else { '' }
  $currentRoute = if ($currentContexts.Count -gt 0) { "$(Get-DshTraceProperty -Object $currentContexts[0] -Name 'provider')/$(Get-DshTraceProperty -Object $currentContexts[0] -Name 'model')" } else { '' }
  if ($baselineRoute -cne $currentRoute) {
    [void]$warnings.Add('model route changed')
    [void]$changes.Add([ordered]@{ metric = 'modelRoute'; baseline = Protect-DshTraceText -Value $baselineRoute -MaxLength 180; current = Protect-DshTraceText -Value $currentRoute -MaxLength 180 })
  }

  $baselineTools = @($baseline | ForEach-Object { @(Get-DshTraceProperty -Object $_ -Name 'toolCalls') } | ForEach-Object { [string](Get-DshTraceProperty -Object $_ -Name 'name') } | Sort-Object -Unique)
  $currentTools = @($Current | ForEach-Object { @(Get-DshTraceProperty -Object $_ -Name 'toolCalls') } | ForEach-Object { [string](Get-DshTraceProperty -Object $_ -Name 'name') } | Sort-Object -Unique)
  if ((@($baselineTools) -join '|') -cne (@($currentTools) -join '|')) {
    [void]$warnings.Add('tool name set changed')
    [void]$changes.Add([ordered]@{ metric = 'toolNames'; baseline = @($baselineTools | ForEach-Object { Protect-DshTraceText -Value $_ -MaxLength 120 }); current = @($currentTools | ForEach-Object { Protect-DshTraceText -Value $_ -MaxLength 120 }) })
  }

  $baselinePermissions = @($baseline | ForEach-Object { @(Get-DshTraceProperty -Object $_ -Name 'toolCalls') } | ForEach-Object { [string](Get-DshTraceProperty -Object $_ -Name 'sandboxPermissionObserved') } | Where-Object { $_ } | Sort-Object -Unique)
  $currentPermissions = @($Current | ForEach-Object { @(Get-DshTraceProperty -Object $_ -Name 'toolCalls') } | ForEach-Object { [string](Get-DshTraceProperty -Object $_ -Name 'sandboxPermissionObserved') } | Where-Object { $_ } | Sort-Object -Unique)
  if ((@($baselinePermissions) -join '|') -cne (@($currentPermissions) -join '|')) {
    [void]$warnings.Add('sandbox permission enum set changed')
    [void]$changes.Add([ordered]@{ metric = 'sandboxPermissions'; baseline = @($baselinePermissions); current = @($currentPermissions) })
  }

  $status = if ($errors.Count -gt 0) { 'FAIL' } elseif ($warnings.Count -gt 0 -and $Strict) { 'FAIL' } elseif ($warnings.Count -gt 0) { 'WARN' } else { 'PASS' }
  return [ordered]@{
    status = $status
    strict = [bool]$Strict
    errors = @($errors)
    warnings = @($warnings)
    changes = @($changes)
    current = [ordered]@{ sessionId = Get-DshTraceProperty -Object $Current -Name 'sessionId'; eventCount = Get-DshTraceProperty -Object $Current -Name 'eventCount' }
    baseline = [ordered]@{ sessionId = Get-DshTraceProperty -Object $Baseline -Name 'sessionId'; eventCount = Get-DshTraceProperty -Object $Baseline -Name 'eventCount' }
    privacy = 'Metadata-only baseline gate; raw arguments, command text, result bodies, credentials, cookies, authorization headers, and full cwd are never returned.'
  }
}

function Get-DshTraceProfile {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)]$Trace
  )

  $contract = Test-DshTraceContract -Trace $Trace
  if (-not $contract.valid) {
    return [ordered]@{
      schemaVersion = 1
      status = 'INVALID'
      contract = $contract
      profile = $null
      privacy = 'Metadata-only profile; invalid input is never echoed.'
    }
  }

  $events = @(Get-DshTraceProperty -Object $Trace -Name 'events')
  $toolCalls = @(Get-DshTraceProperty -Object $Trace -Name 'toolCalls')
  $toolResults = @(Get-DshTraceProperty -Object $Trace -Name 'toolResults')
  $callResults = @{}
  foreach ($result in $toolResults) {
    $resultCallId = [string](Get-DshTraceProperty -Object $result -Name 'callId')
    if (-not [string]::IsNullOrWhiteSpace($resultCallId)) { $callResults[$resultCallId] = $result }
  }

  $offsets = @(foreach ($event in $events) {
      $offset = Get-DshTraceProperty -Object $event -Name 'timeOffsetMs'
      if ($null -ne $offset) { [long]$offset }
    })
  $negativeOffsetCount = @($offsets | Where-Object { $_ -lt 0 }).Count
  $durationMs = $null
  if ($offsets.Count -gt 0) {
    $durationMs = [long]([Math]::Max(0, ([long]($offsets | Measure-Object -Maximum).Maximum - [long]($offsets | Measure-Object -Minimum).Minimum)))
  }

  $turnNumbers = @($events | ForEach-Object { Get-DshTraceInt -Value (Get-DshTraceProperty -Object $_ -Name 'turn') } | Where-Object { $null -ne $_ } | Sort-Object -Unique)
  $turnErrors = @(Get-DshTraceProperty -Object $Trace -Name 'turnErrors')
  $turnRows = [System.Collections.Generic.List[object]]::new()
  foreach ($turnNumber in $turnNumbers) {
    $turnEvents = @($events | Where-Object { (Get-DshTraceProperty -Object $_ -Name 'turn') -eq $turnNumber })
    $turnOffsets = @($turnEvents | ForEach-Object { Get-DshTraceProperty -Object $_ -Name 'timeOffsetMs' } | Where-Object { $null -ne $_ })
    $turnDuration = $null
    if ($turnOffsets.Count -gt 0) {
      $turnDuration = [long]([Math]::Max(0, ([long]($turnOffsets | Measure-Object -Maximum).Maximum - [long]($turnOffsets | Measure-Object -Minimum).Minimum)))
    }
    $turnCallCount = @($turnEvents | Where-Object { (Get-DshTraceProperty -Object $_ -Name 'type') -eq 'tool/call' }).Count
    $turnErrorCount = @($turnEvents | Where-Object {
        $eventType = [string](Get-DshTraceProperty -Object $_ -Name 'type')
        ($eventType -eq 'tool/result' -and (Get-DshTraceProperty -Object $_ -Name 'isError') -eq $true) -or
        ($eventType -eq 'turn/end' -and (Get-DshTraceProperty -Object $_ -Name 'reasonKind') -eq 'error')
      }).Count
    [void]$turnRows.Add([ordered]@{
        turn = [int]$turnNumber
        eventCount = $turnEvents.Count
        toolCallCount = $turnCallCount
        errorCount = $turnErrorCount
        durationMs = $turnDuration
      })
  }

  $toolRows = [System.Collections.Generic.List[object]]::new()
  $toolGroups = @($toolCalls | Group-Object -Property { [string](Get-DshTraceProperty -Object $_ -Name 'name') } | Sort-Object Name)
  foreach ($group in $toolGroups) {
    $name = Protect-DshTraceText -Value ([string]$group.Name) -MaxLength 180
    $groupCalls = @($group.Group)
    $groupResults = @($groupCalls | ForEach-Object {
        $callId = [string](Get-DshTraceProperty -Object $_ -Name 'callId')
        if (-not [string]::IsNullOrWhiteSpace($callId) -and $callResults.ContainsKey($callId)) { $callResults[$callId] }
      })
    $latencies = @(foreach ($call in $groupCalls) {
        $callId = [string](Get-DshTraceProperty -Object $call -Name 'callId')
        if ([string]::IsNullOrWhiteSpace($callId) -or -not $callResults.ContainsKey($callId)) { continue }
        $callOffset = Get-DshTraceProperty -Object $call -Name 'timeOffsetMs'
        $resultOffset = Get-DshTraceProperty -Object $callResults[$callId] -Name 'timeOffsetMs'
        if ($null -ne $callOffset -and $null -ne $resultOffset -and [long]$resultOffset -ge [long]$callOffset) {
          [long]$resultOffset - [long]$callOffset
        }
      })
    $errorCount = @($groupResults | Where-Object { (Get-DshTraceProperty -Object $_ -Name 'isError') -eq $true }).Count
    $permissionValues = @($groupCalls | ForEach-Object { [string](Get-DshTraceProperty -Object $_ -Name 'sandboxPermissionObserved') } | Where-Object { $_ } | Sort-Object -Unique)
    [void]$toolRows.Add([ordered]@{
        name = $name
        callCount = $groupCalls.Count
        resultCount = $groupResults.Count
        errorCount = $errorCount
        pendingCount = $groupCalls.Count - $groupResults.Count
        completionRatio = if ($groupCalls.Count -eq 0) { $null } else { [Math]::Round($groupResults.Count / $groupCalls.Count, 3) }
        latencyObservedCount = $latencies.Count
        averageLatencyMs = if ($latencies.Count -eq 0) { $null } else { [Math]::Round((($latencies | Measure-Object -Average).Average), 1) }
        maxLatencyMs = if ($latencies.Count -eq 0) { $null } else { [long](($latencies | Measure-Object -Maximum).Maximum) }
        sandboxPermissions = @($permissionValues)
      })
  }

  $retryGroups = [System.Collections.Generic.List[object]]::new()
  $lastCallByTool = @{}
  foreach ($call in $toolCalls) {
    $toolName = [string](Get-DshTraceProperty -Object $call -Name 'name')
    if ([string]::IsNullOrWhiteSpace($toolName)) { continue }
    $callId = [string](Get-DshTraceProperty -Object $call -Name 'callId')
    $result = if (-not [string]::IsNullOrWhiteSpace($callId) -and $callResults.ContainsKey($callId)) { $callResults[$callId] } else { $null }
    $isError = $null -ne $result -and (Get-DshTraceProperty -Object $result -Name 'isError') -eq $true
    if (-not $lastCallByTool.ContainsKey($toolName)) {
      $lastCallByTool[$toolName] = [ordered]@{ attempts = 1; failed = $isError }
      continue
    }
    $previous = $lastCallByTool[$toolName]
    if ($previous.failed -eq $true) {
      $previous.attempts = [int]$previous.attempts + 1
    } else {
      $previous.attempts = 1
    }
    $previous.failed = $isError
    if ([int]$previous.attempts -gt 1) {
      $existing = @($retryGroups | Where-Object { $_.name -ceq (Protect-DshTraceText -Value $toolName -MaxLength 180) })
      if ($existing.Count -eq 0) {
        [void]$retryGroups.Add([ordered]@{ name = Protect-DshTraceText -Value $toolName -MaxLength 180; attemptCount = [int]$previous.attempts; retryCount = [int]$previous.attempts - 1 })
      } else {
        $existing[0].attemptCount = [Math]::Max([int]$existing[0].attemptCount, [int]$previous.attempts)
        $existing[0].retryCount = [int]$existing[0].attemptCount - 1
      }
    }
  }
  $retryAttemptCount = [int](($retryGroups | ForEach-Object { [int]$_.retryCount } | Measure-Object -Sum).Sum)
  if ($retryGroups.Count -eq 0) { $retryAttemptCount = 0 }
  $errorResultCount = @($toolResults | Where-Object { (Get-DshTraceProperty -Object $_ -Name 'isError') -eq $true }).Count
  $dispatchErrorCount = [int](Get-DshTraceProperty -Object (Get-DshTraceProperty -Object $Trace -Name 'toolCallStats') -Name 'dispatchErrorCount')
  $pendingCount = [int](Get-DshTraceProperty -Object (Get-DshTraceProperty -Object $Trace -Name 'toolCallStats') -Name 'pendingCount')
  $totalErrors = $errorResultCount + $dispatchErrorCount + $turnErrors.Count

  $profile = [ordered]@{
    coverage = [ordered]@{
      eventCount = $events.Count
      timestampEventCount = $offsets.Count
      timestampCoverage = if ($events.Count -eq 0) { $null } else { [Math]::Round($offsets.Count / $events.Count, 3) }
      pageComplete = (Get-DshTraceProperty -Object $Trace -Name 'hasMore') -ne $true
    }
    wallTime = [ordered]@{
      durationMs = $durationMs
      negativeOffsetCount = $negativeOffsetCount
      timestampObserved = $offsets.Count -gt 0
      basis = 'relative event offsets only'
    }
    turns = [ordered]@{
      turnCount = $turnRows.Count
      errorTurnCount = $turnErrors.Count
      maxEventsPerTurn = if ($turnRows.Count -eq 0) { 0 } else { [int](($turnRows | ForEach-Object { [int]$_.eventCount } | Measure-Object -Maximum).Maximum) }
      rows = @($turnRows)
    }
    tools = [ordered]@{
      uniqueToolCount = $toolRows.Count
      callCount = $toolCalls.Count
      resultCount = $toolResults.Count
      errorResultCount = $errorResultCount
      pendingCount = $pendingCount
      rows = @($toolRows)
    }
    retries = [ordered]@{
      retryGroupCount = $retryGroups.Count
      retryAttemptCount = $retryAttemptCount
      maxAttempts = if ($retryGroups.Count -eq 0) { 0 } else { [int](($retryGroups | ForEach-Object { [int]$_.attemptCount } | Measure-Object -Maximum).Maximum) }
      rows = @($retryGroups)
      basis = 'same metadata-level tool name following an observed error result'
    }
    errors = [ordered]@{
      totalErrorCount = $totalErrors
      toolResultErrorCount = $errorResultCount
      dispatchErrorCount = $dispatchErrorCount
      turnErrorCount = $turnErrors.Count
      errorRate = if ($events.Count -eq 0) { $null } else { [Math]::Round($totalErrors / $events.Count, 3) }
    }
  }
  return [ordered]@{
    schemaVersion = 1
    status = 'PASS'
    contract = $contract
    profile = $profile
    privacy = 'Metadata-only runtime profile: relative durations, bounded counts, tool names, permission enums, and error booleans/counts. Absolute timestamps, Tool arguments, command text, result bodies, credentials, cookies, authorization headers, call IDs, and full cwd are omitted.'
  }
}

function Test-DshTraceProfileContract {
  param([Parameter(Mandatory = $true)]$Report)
  $errors = [System.Collections.Generic.List[string]]::new()
  if ([int](Get-DshTraceProperty -Object $Report -Name 'schemaVersion') -ne 1) { [void]$errors.Add('unsupported profile schemaVersion') }
  if ([string](Get-DshTraceProperty -Object $Report -Name 'status') -notin @('PASS', 'INVALID')) { [void]$errors.Add('unsupported profile status') }
  $profile = Get-DshTraceProperty -Object $Report -Name 'profile'
  if ($null -ne $profile) {
    foreach ($section in @('coverage', 'wallTime', 'turns', 'tools', 'retries', 'errors')) {
      if (-not (Test-DshTraceProperty -Object $profile -Name $section)) { [void]$errors.Add("profile.$section is missing") }
    }
    $serialized = $Report | ConvertTo-Json -Depth 20 -Compress
    foreach ($forbidden in @('PRIVATE_COMMAND', 'PRIVATE_ARGUMENT', 'PRIVATE_RESULT', 'PRIVATE_SECRET')) {
      if ($serialized -match [regex]::Escape($forbidden)) { [void]$errors.Add("profile contains forbidden marker '$forbidden'") }
    }
  }
  return [ordered]@{ valid = $errors.Count -eq 0; errors = @($errors) }
}

Export-ModuleMember -Function @(
  'Get-DshTraceProperty',
  'Protect-DshTraceText',
  'ConvertTo-DshTrace',
  'Test-DshTraceContract',
  'Test-DshTraceCase',
  'Get-DshTracePathValues',
  'Invoke-DshTraceEvaluation',
  'Compare-DshTraceBaseline',
  'Get-DshTraceProfile',
  'Test-DshTraceProfileContract'
)
