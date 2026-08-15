[CmdletBinding()]
param(
  [string]$InputPath = '',
  [int]$WindowSize = 12,
  [int]$RepeatThreshold = 2
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:DshTraceLoopSchemaVersion = 1
$script:DshTraceLoopMaxInputBytes = 4194304
$script:DshTraceLoopMaxEvents = 1000
$script:DshTraceLoopMaxCalls = 512
$script:DshTraceLoopMaxWindowSize = 64
$script:DshTraceLoopMaxRepeatThreshold = 16

function Get-DshTraceLoopProperty {
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

function Test-DshTraceLoopProperty {
  param(
    [AllowNull()]$Object,
    [Parameter(Mandatory = $true)][string]$Name
  )
  if ($null -eq $Object) { return $false }
  if ($Object -is [System.Collections.IDictionary]) { return $Object.Contains($Name) }
  return $null -ne $Object.PSObject.Properties[$Name]
}

function Test-DshTraceLoopMap {
  param([AllowNull()]$Value)
  if ($null -eq $Value -or $Value -is [string] -or $Value -is [System.Array]) { return $false }
  if ($Value -is [System.Collections.IDictionary]) { return $true }
  return $null -ne $Value.PSObject.Properties
}

function Get-DshTraceLoopMapKeys {
  param([Parameter(Mandatory = $true)]$Value)
  if ($Value -is [System.Collections.IDictionary]) {
    return @($Value.Keys | ForEach-Object { [string]$_ } | Sort-Object -Unique)
  }
  return @($Value.PSObject.Properties.Name | ForEach-Object { [string]$_ } | Sort-Object -Unique)
}

function Get-DshTraceLoopInteger {
  param([AllowNull()]$Value)
  if ($null -eq $Value -or $Value -is [bool]) { return $null }
  $raw = [string]$Value
  if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
  $parsed = [long]0
  if ([long]::TryParse($raw, [Globalization.NumberStyles]::Integer, [Globalization.CultureInfo]::InvariantCulture, [ref]$parsed)) {
    return $parsed
  }
  return $null
}

function Test-DshTraceLoopSensitiveKey {
  param([Parameter(Mandatory = $true)][string]$Key)
  return $Key -match '(?i)^(authorization|cookie|set[-_]?cookie|api[-_]?key|access[-_]?token|refresh[-_]?token|id[-_]?token|token|password|secret|credential|credentials|nonce|request[-_]?id|trace[-_]?id|call[-_]?id|message[-_]?id|session[-_]?id|timestamp|created[-_]?at|updated[-_]?at)$'
}

function Test-DshTraceLoopDynamicMarker {
  param([AllowNull()]$Value)
  if ($null -eq $Value) { return $false }
  if ($Value -is [bool]) { return $false }
  if ($Value -is [string]) {
    $text = $Value.Trim()
    if ($text -match '(?i)^(<dynamic>|\[dynamic\]|__dynamic__|<computed>|\$\{[^}]+\}|\{\{[^}]+\}\})$') { return $true }
    if ($text -match '(?i)^dynamic(?:[:._-]|$)') { return $true }
    return $false
  }
  if (Test-DshTraceLoopMap -Value $Value) {
    foreach ($key in @(Get-DshTraceLoopMapKeys -Value $Value)) {
      $child = Get-DshTraceLoopProperty -Object $Value -Name $key
      if ($key -match '(?i)^(dynamic|dynamicArguments|argumentsDynamic|dynamicParameters|isDynamic)$' -and ([string]$child -ieq 'true')) { return $true }
      if (Test-DshTraceLoopDynamicMarker -Value $child) { return $true }
    }
  } elseif ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) {
    foreach ($item in @($Value)) {
      if (Test-DshTraceLoopDynamicMarker -Value $item) { return $true }
    }
    return $false
  }
  return $false
}

function ConvertTo-DshTraceLoopStableValue {
  param(
    [AllowNull()]$Value,
    [string]$Key = '',
    [int]$Depth = 0,
    [Parameter(Mandatory = $true)][ref]$RedactionCount
  )
  if ($Depth -gt 8) { throw 'parameter structure exceeds the bounded depth' }
  if (Test-DshTraceLoopDynamicMarker -Value $Value) { throw 'dynamic parameter value requires manual review' }
  if ($null -eq $Value) { return $null }

  if ($Value -is [string]) {
    if (Test-DshTraceLoopSensitiveKey -Key $Key) {
      $RedactionCount.Value = [int]$RedactionCount.Value + 1
      return '<redacted>'
    }
    $text = [string]$Value
    if ($text -match '(?i)bearer\s+[A-Za-z0-9._~+/=-]+|(?:api[_-]?key|access[_-]?token|refresh[_-]?token|password|secret)\s*[:=]') {
      $RedactionCount.Value = [int]$RedactionCount.Value + 1
      return '<redacted>'
    }
    return $text
  }

  if ($Value -is [bool]) { return [bool]$Value }
  if ($Value -is [byte] -or $Value -is [int16] -or $Value -is [int32] -or $Value -is [int64] -or
      $Value -is [uint16] -or $Value -is [uint32] -or $Value -is [uint64] -or
      $Value -is [decimal] -or $Value -is [double] -or $Value -is [single]) {
    return $Value
  }

  if (Test-DshTraceLoopMap -Value $Value) {
    $keys = @(Get-DshTraceLoopMapKeys -Value $Value)
    if ($keys.Count -gt 128) { throw 'parameter object exceeds the bounded property count' }
    $result = [ordered]@{}
    foreach ($childKey in $keys) {
      if ([string]::IsNullOrWhiteSpace($childKey) -or $childKey.Length -gt 160 -or $childKey -match '\p{C}') {
        throw 'parameter object contains an invalid key'
      }
      $child = Get-DshTraceLoopProperty -Object $Value -Name $childKey
      if ($childKey -match '(?i)^(dynamic|dynamicArguments|argumentsDynamic|dynamicParameters|isDynamic)$' -and ([string]$child -ieq 'true')) {
        throw 'dynamic parameter declaration requires manual review'
      }
      if (Test-DshTraceLoopSensitiveKey -Key $childKey) {
        $RedactionCount.Value = [int]$RedactionCount.Value + 1
        $result[$childKey] = '<redacted>'
      } else {
        $result[$childKey] = ConvertTo-DshTraceLoopStableValue -Value $child -Key $childKey -Depth ($Depth + 1) -RedactionCount $RedactionCount
      }
    }
    return $result
  }

  if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) {
    $items = @($Value)
    if ($items.Count -gt 128) { throw 'parameter array exceeds the bounded item count' }
    $result = [System.Collections.Generic.List[object]]::new()
    foreach ($item in $items) {
      [void]$result.Add((ConvertTo-DshTraceLoopStableValue -Value $item -Key $Key -Depth ($Depth + 1) -RedactionCount $RedactionCount))
    }
    return @($result)
  }

  throw 'parameter value uses an unsupported or dynamic type'
}

function Get-DshTraceLoopSha256 {
  param([Parameter(Mandatory = $true)][string]$Text)
  $sha = [Security.Cryptography.SHA256]::Create()
  try {
    $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
    $digest = $sha.ComputeHash($bytes)
    $hex = ($digest | ForEach-Object { $_.ToString('x2', [Globalization.CultureInfo]::InvariantCulture) }) -join ''
    return 'sha256:' + $hex
  } finally {
    $sha.Dispose()
  }
}

function Get-DshTraceLoopFingerprint {
  param(
    [Parameter(Mandatory = $true)]$Event,
    [Parameter(Mandatory = $true)]$Data,
    [Parameter(Mandatory = $true)][ref]$RedactionCount
  )
  $fingerprintNames = @('argumentFingerprint', 'argumentsFingerprint', 'parameterFingerprint', 'paramsFingerprint')
  foreach ($name in $fingerprintNames) {
    if (Test-DshTraceLoopProperty -Object $Data -Name $name) {
      $candidate = Get-DshTraceLoopProperty -Object $Data -Name $name
      if ($null -eq $candidate -or $candidate -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$candidate)) {
        throw 'argument fingerprint is missing or invalid'
      }
      if (Test-DshTraceLoopDynamicMarker -Value $candidate) { throw 'dynamic argument fingerprint requires manual review' }
      $normalized = ([string]$candidate).Trim().ToLowerInvariant()
      if ($normalized -notmatch '^(?:sha256:)?[0-9a-f]{64}$') { throw 'argument fingerprint must be a SHA-256 digest' }
      if ($normalized -notmatch '^sha256:') { $normalized = 'sha256:' + $normalized }
      return [ordered]@{ value = $normalized; basis = 'provided-sha256'; redacted = $false }
    }
  }

  if (-not (Test-DshTraceLoopProperty -Object $Data -Name 'arguments')) {
    if (Test-DshTraceLoopProperty -Object $Event -Name 'arguments') {
      $arguments = Get-DshTraceLoopProperty -Object $Event -Name 'arguments'
    } else {
      throw 'tool call has no stable argument representation'
    }
  } else {
    $arguments = Get-DshTraceLoopProperty -Object $Data -Name 'arguments'
  }
  if ($null -eq $arguments -or -not (Test-DshTraceLoopMap -Value $arguments)) {
    throw 'tool call arguments must be a stable object'
  }
  $stable = ConvertTo-DshTraceLoopStableValue -Value $arguments -Key 'arguments' -Depth 0 -RedactionCount $RedactionCount
  $canonical = $stable | ConvertTo-Json -Compress -Depth 32
  return [ordered]@{
    value = Get-DshTraceLoopSha256 -Text $canonical
    basis = 'canonical-sanitized-arguments'
    redacted = [int]$RedactionCount.Value -gt 0
  }
}

function Get-DshTraceLoopEventView {
  param([Parameter(Mandatory = $true)]$Entry)
  if ($null -eq $Entry -or $Entry -is [string] -or $Entry -is [ValueType]) { throw 'trace event is not an object' }
  $event = Get-DshTraceLoopProperty -Object $Entry -Name 'event'
  if ($null -eq $event) { $event = $Entry }
  if ($null -eq $event -or $event -is [string] -or $event -is [ValueType]) { throw 'trace event payload is not an object' }
  $data = Get-DshTraceLoopProperty -Object $event -Name 'data'
  if ($null -eq $data) { $data = $event }
  return [PSCustomObject]@{ event = $event; data = $data }
}

function Get-DshTraceLoopCallId {
  param([Parameter(Mandatory = $true)]$Event, [Parameter(Mandatory = $true)]$Data)
  $value = Get-DshTraceLoopProperty -Object $Data -Name 'callId'
  if ($null -eq $value) { $value = Get-DshTraceLoopProperty -Object $Event -Name 'callId' }
  if ($null -eq $value -or [string]::IsNullOrWhiteSpace([string]$value)) { return $null }
  $text = [string]$value
  if ($text.Length -gt 240 -or $text -match '\p{C}') { throw 'call identity is invalid' }
  return $text
}

function Get-DshTraceLoopResultCallId {
  param([Parameter(Mandatory = $true)]$Event, [Parameter(Mandatory = $true)]$Data)
  $message = Get-DshTraceLoopProperty -Object $Data -Name 'message'
  $source = Get-DshTraceLoopProperty -Object $message -Name 'source'
  $value = Get-DshTraceLoopProperty -Object $source -Name 'callId'
  if ($null -eq $value) { $value = Get-DshTraceLoopProperty -Object $Data -Name 'callId' }
  if ($null -eq $value) { $value = Get-DshTraceLoopProperty -Object $Event -Name 'callId' }
  if ($null -eq $value -or [string]::IsNullOrWhiteSpace([string]$value)) { return $null }
  $text = [string]$value
  if ($text.Length -gt 240 -or $text -match '\p{C}') { throw 'result identity is invalid' }
  return $text
}

function Get-DshTraceLoopResultState {
  param([Parameter(Mandatory = $true)]$Event, [Parameter(Mandatory = $true)]$Data)
  $observed = $false
  $isError = $false
  if (Test-DshTraceLoopProperty -Object $Data -Name 'isError') {
    $observed = $true
    $isError = (Get-DshTraceLoopProperty -Object $Data -Name 'isError') -eq $true
  }
  if (Test-DshTraceLoopProperty -Object $Event -Name 'isError') {
    $observed = $true
    $isError = (Get-DshTraceLoopProperty -Object $Event -Name 'isError') -eq $true
  }
  $message = Get-DshTraceLoopProperty -Object $Data -Name 'message'
  $content = Get-DshTraceLoopProperty -Object $message -Name 'content'
  foreach ($block in @($content)) {
    if ($null -eq $block) { continue }
    if ([string](Get-DshTraceLoopProperty -Object $block -Name 'type') -cne 'tool-result') { continue }
    if (Test-DshTraceLoopProperty -Object $block -Name 'isError') {
      $observed = $true
      if ((Get-DshTraceLoopProperty -Object $block -Name 'isError') -eq $true) { $isError = $true }
    }
  }
  if (Test-DshTraceLoopProperty -Object $Data -Name 'error') {
    $observed = $true
    $isError = $true
  }
  return [ordered]@{ observed = $observed; success = $observed -and -not $isError; error = $observed -and $isError }
}

function Test-DshTraceLoopPattern {
  param(
    [Parameter(Mandatory = $true)][string[]]$Identities,
    [Parameter(Mandatory = $true)][int]$Start,
    [Parameter(Mandatory = $true)][int]$Period,
    [Parameter(Mandatory = $true)][int]$Length
  )
  for ($offset = $Period; $offset -lt $Length; $offset++) {
    if ($Identities[$Start + $offset] -cne $Identities[$Start + ($offset % $Period)]) { return $false }
  }
  return $true
}

function Test-DshTraceLoopHasSmallerPeriod {
  param(
    [Parameter(Mandatory = $true)][string[]]$Identities,
    [Parameter(Mandatory = $true)][int]$Start,
    [Parameter(Mandatory = $true)][int]$Period,
    [Parameter(Mandatory = $true)][int]$Length
  )
  for ($candidate = 1; $candidate -lt $Period; $candidate++) {
    if (($Length % $candidate) -ne 0) { continue }
    if (Test-DshTraceLoopPattern -Identities $Identities -Start $Start -Period $candidate -Length $Length) { return $true }
  }
  return $false
}

function Get-DshTraceLoopPatternText {
  param(
    [Parameter(Mandatory = $true)][string[]]$Identities,
    [Parameter(Mandatory = $true)][int]$Start,
    [Parameter(Mandatory = $true)][int]$Length
  )
  $labels = @{}
  $nextLabel = 0
  $parts = [System.Collections.Generic.List[string]]::new()
  for ($offset = 0; $offset -lt $Length; $offset++) {
    $identity = $Identities[$Start + $offset]
    if (-not $labels.ContainsKey($identity)) {
      if ($nextLabel -lt 26) { $labels[$identity] = [char]([int][char]'A' + $nextLabel) } else { $labels[$identity] = 'P' + ($nextLabel + 1) }
      $nextLabel++
    }
    [void]$parts.Add([string]$labels[$identity])
  }
  return ($parts -join '-')
}

function Find-DshTraceLoopFindings {
  param(
    [Parameter(Mandatory = $true)][object[]]$Calls,
    [Parameter(Mandatory = $true)][int]$WindowSize,
    [Parameter(Mandatory = $true)][int]$RepeatThreshold
  )
  $findings = [System.Collections.Generic.List[object]]::new()
  if ($Calls.Count -lt $RepeatThreshold) { return @($findings) }
  $identities = @($Calls | ForEach-Object { [string]$_.tool + "`n" + [string]$_.fingerprint })
  $seen = @{}
  $maxPeriod = [Math]::Floor($WindowSize / $RepeatThreshold)
  for ($start = 0; $start -lt $Calls.Count; $start++) {
    for ($period = 1; $period -le $maxPeriod; $period++) {
      $minimumLength = $period * $RepeatThreshold
      if ($start + $minimumLength -gt $Calls.Count) { break }
      $windowEnd = [Math]::Min($Calls.Count - 1, $start + $WindowSize - 1)
      $cycles = 1
      while ($start + (($cycles + 1) * $period) - 1 -le $windowEnd) {
        $candidateLength = ($cycles + 1) * $period
        if (-not (Test-DshTraceLoopPattern -Identities $identities -Start $start -Period $period -Length $candidateLength)) { break }
        $cycles++
      }
      if ($cycles -lt $RepeatThreshold) { continue }
      $length = $cycles * $period
      if (Test-DshTraceLoopHasSmallerPeriod -Identities $identities -Start $start -Period $period -Length $length) { continue }
      if ($start -ge $period -and (Test-DshTraceLoopPattern -Identities $identities -Start ($start - $period) -Period $period -Length ($period * 2))) { continue }
      $end = $start + $length - 1
      $dedupeKey = "$start|$period|$end"
      if ($seen.ContainsKey($dedupeKey)) { continue }
      $seen[$dedupeKey] = $true
      $segment = @($Calls[$start..$end])
      $allSuccessful = $true
      $anyObservedResult = $false
      $allReturned = $true
      foreach ($call in $segment) {
        if ($call.hasResult) { $anyObservedResult = $true } else { $allReturned = $false }
        if (-not $call.success) { $allSuccessful = $false }
      }
      $returnPattern = if ($allSuccessful -and $allReturned) { 'successful-return' } elseif ($anyObservedResult) { 'mixed-or-error-return' } else { 'not-observed' }
      $findingKind = if ($returnPattern -eq 'successful-return') { 'successful-return-loop' } else { 'repeated-call-loop' }
      $fingerprints = @($segment | ForEach-Object { [string]$_.fingerprint } | Sort-Object -Unique)
      $tools = @($segment | ForEach-Object { [string]$_.tool } | Sort-Object -Unique)
      $evidence = @($segment | ForEach-Object { [ordered]@{ seq = [long]$_.seq } })
      [void]$findings.Add([ordered]@{
          kind = $findingKind
          pattern = Get-DshTraceLoopPatternText -Identities $identities -Start $start -Length $length
          period = $period
          cycleCount = $cycles
          callCount = $length
          startSeq = [long]$Calls[$start].seq
          endSeq = [long]$Calls[$end].seq
          tools = $tools
          fingerprints = $fingerprints
          returnPattern = $returnPattern
          evidence = $evidence
        })
    }
  }
  return @($findings | Sort-Object startSeq, endSeq, period)
}

function New-DshTraceLoopSafety {
  return [ordered]@{
    analysisMode = 'offline-postmortem'
    runtimeBlocking = $false
    profileWrites = $false
    toolExecution = $false
    networkAccess = $false
    inputModified = $false
    failClosed = $true
  }
}

function New-DshTraceLoopPrivacy {
  return [ordered]@{
    rawTraceReturned = $false
    parameterValuesReturned = $false
    callIdsReturned = $false
    fingerprint = 'sha256 of canonical sanitized parameter metadata or a supplied sha256 digest'
    redaction = 'Known credential, token, request identity, and timestamp fields are replaced before hashing.'
  }
}

function New-DshTraceLoopReport {
  param(
    [Parameter(Mandatory = $true)][ValidateSet('PASS', 'LOOP_DETECTED', 'FAIL')][string]$Result,
    [AllowEmptyCollection()][object[]]$Findings = @(),
    [AllowEmptyCollection()][string[]]$Errors = @(),
    [AllowEmptyCollection()][string[]]$Warnings = @(),
    [AllowNull()]$InputSummary = $null
  )
  return [ordered]@{
    kind = 'dsh-trace-loop'
    schemaVersion = $script:DshTraceLoopSchemaVersion
    result = $Result
    input = $InputSummary
    findings = @($Findings)
    errors = @($Errors)
    warnings = @($Warnings)
    safety = New-DshTraceLoopSafety
    privacy = New-DshTraceLoopPrivacy
  }
}

function Invoke-DshTraceLoop {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)]$InputObject,
    [int]$WindowSize = 12,
    [int]$RepeatThreshold = 2
  )
  $eventCount = 0
  $callCount = 0
  $redactionCount = 0
  $calls = [System.Collections.Generic.List[object]]::new()
  try {
    if ($WindowSize -lt 2 -or $WindowSize -gt $script:DshTraceLoopMaxWindowSize) { throw 'window size is outside the bounded range' }
    if ($RepeatThreshold -lt 2 -or $RepeatThreshold -gt $script:DshTraceLoopMaxRepeatThreshold) { throw 'repeat threshold is outside the bounded range' }
    if ($RepeatThreshold -gt $WindowSize) { throw 'repeat threshold cannot exceed window size' }
    if ($null -eq $InputObject -or -not (Test-DshTraceLoopProperty -Object $InputObject -Name 'events')) { throw 'trace must contain an events array' }
    $eventsValue = Get-DshTraceLoopProperty -Object $InputObject -Name 'events'
    if ($null -eq $eventsValue -or $eventsValue -is [string] -or $eventsValue -is [System.Collections.IDictionary]) { throw 'trace events must be a JSON array' }
    $events = @($eventsValue)
    $eventCount = $events.Count
    if ($eventCount -eq 0) { throw 'trace events array is empty' }
    if ($eventCount -gt $script:DshTraceLoopMaxEvents) { throw 'trace exceeds the bounded event count' }

    $results = @{}
    $seenSequences = @{}
    $previousSequence = $null
    foreach ($entry in $events) {
      $view = Get-DshTraceLoopEventView -Entry $entry
      $event = $view.event
      $data = $view.data
      $sequence = Get-DshTraceLoopInteger -Value (Get-DshTraceLoopProperty -Object $event -Name 'seq')
      if ($null -eq $sequence -or $sequence -lt 0) { throw 'trace event sequence is missing or invalid' }
      if ($seenSequences.ContainsKey([string]$sequence) -or ($null -ne $previousSequence -and $sequence -le $previousSequence)) {
        throw 'trace event sequences must be unique and increasing'
      }
      $seenSequences[[string]$sequence] = $true
      $previousSequence = $sequence
      $type = Get-DshTraceLoopProperty -Object $event -Name 'type'
      if ($null -eq $type -or $type -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$type) -or ([string]$type).Length -gt 120) {
        throw 'trace event type is missing or invalid'
      }
      $type = ([string]$type).Trim()
      if ($type -eq 'tool/call') {
        foreach ($dynamicName in @('dynamic', 'dynamicArguments', 'argumentsDynamic', 'dynamicParameters', 'isDynamic')) {
          if ((Test-DshTraceLoopProperty -Object $data -Name $dynamicName) -and ([string](Get-DshTraceLoopProperty -Object $data -Name $dynamicName) -ieq 'true')) {
            throw 'dynamic tool call requires manual review'
          }
          if ((Test-DshTraceLoopProperty -Object $event -Name $dynamicName) -and ([string](Get-DshTraceLoopProperty -Object $event -Name $dynamicName) -ieq 'true')) {
            throw 'dynamic tool call requires manual review'
          }
        }
        $nameValue = Get-DshTraceLoopProperty -Object $data -Name 'name'
        if ($null -eq $nameValue) { $nameValue = Get-DshTraceLoopProperty -Object $event -Name 'name' }
        if ($null -eq $nameValue -or $nameValue -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$nameValue)) { throw 'tool call name is missing or invalid' }
        $tool = ([string]$nameValue).Trim()
        if ($tool.Length -gt 180 -or $tool -match '\p{C}') { throw 'tool call name is invalid' }
        $callId = Get-DshTraceLoopCallId -Event $event -Data $data
        $fingerprint = Get-DshTraceLoopFingerprint -Event $event -Data $data -RedactionCount ([ref]$redactionCount)
        if ($null -ne $callId -and $results.ContainsKey($callId)) { throw 'call identity is reused ambiguously' }
        [void]$calls.Add([PSCustomObject]@{
            ordinal = $calls.Count
            seq = $sequence
            tool = $tool
            callId = $callId
            fingerprint = [string]$fingerprint.value
            fingerprintBasis = [string]$fingerprint.basis
            redacted = [bool]$fingerprint.redacted
            hasResult = $false
            success = $false
          })
        $callCount++
        if ($callCount -gt $script:DshTraceLoopMaxCalls) { throw 'trace exceeds the bounded tool call count' }
      } elseif ($type -eq 'tool/result') {
        $resultCallId = Get-DshTraceLoopResultCallId -Event $event -Data $data
        $state = Get-DshTraceLoopResultState -Event $event -Data $data
        if ($null -ne $resultCallId) {
          if ($results.ContainsKey($resultCallId)) { throw 'result identity is duplicated' }
          $results[$resultCallId] = $state
        }
      }
    }

    foreach ($call in @($calls)) {
      if ($null -ne $call.callId -and $results.ContainsKey($call.callId)) {
        $state = $results[$call.callId]
        $call.hasResult = [bool]$state.observed
        $call.success = [bool]$state.success
      }
    }
    # PowerShell unwraps an empty pipeline result to $null; keep the report shape stable.
    $findings = @(Find-DshTraceLoopFindings -Calls @($calls) -WindowSize $WindowSize -RepeatThreshold $RepeatThreshold)
    $result = if ($findings.Count -gt 0) { 'LOOP_DETECTED' } else { 'PASS' }
    $summary = [ordered]@{
      eventCount = $eventCount
      toolCallCount = $callCount
      analyzedCallCount = $callCount
      windowSize = $WindowSize
      repeatThreshold = $RepeatThreshold
      redactedParameterFieldCount = $redactionCount
    }
    return New-DshTraceLoopReport -Result $result -Findings $findings -InputSummary $summary
  } catch {
    $summary = [ordered]@{
      eventCount = $eventCount
      toolCallCount = $callCount
      windowSize = $WindowSize
      repeatThreshold = $RepeatThreshold
    }
    return New-DshTraceLoopReport -Result 'FAIL' -Errors @([string]$_.Exception.Message) -InputSummary $summary
  }
}

function Read-DshTraceLoopJson {
  param([Parameter(Mandatory = $true)][string]$Path)
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw 'trace input file does not exist' }
  $file = Get-Item -LiteralPath $Path -Force
  if ($file.Length -gt $script:DshTraceLoopMaxInputBytes) { throw 'trace input exceeds the bounded file size' }
  try {
    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) { throw 'empty trace input' }
    return $raw | ConvertFrom-Json
  } catch {
    if ($_.Exception.Message -eq 'empty trace input') { throw }
    throw 'trace input is not valid JSON'
  }
}

if ($MyInvocation.InvocationName -ne '.') {
  $report = $null
  try {
    if ([string]::IsNullOrWhiteSpace($InputPath)) {
      $report = New-DshTraceLoopReport -Result 'FAIL' -Errors @('InputPath is required') -InputSummary ([ordered]@{ eventCount = $null; toolCallCount = $null; windowSize = $WindowSize; repeatThreshold = $RepeatThreshold })
    } else {
      $report = Invoke-DshTraceLoop -InputObject (Read-DshTraceLoopJson -Path $InputPath) -WindowSize $WindowSize -RepeatThreshold $RepeatThreshold
    }
  } catch {
    $report = New-DshTraceLoopReport -Result 'FAIL' -Errors @('trace analysis could not be started') -InputSummary ([ordered]@{ eventCount = $null; toolCallCount = $null; windowSize = $WindowSize; repeatThreshold = $RepeatThreshold })
  }
  $report | ConvertTo-Json -Depth 32
  if ($report.result -eq 'FAIL') { exit 1 }
  exit 0
}
