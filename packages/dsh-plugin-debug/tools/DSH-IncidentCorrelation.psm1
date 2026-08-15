Set-StrictMode -Version Latest

$script:IncidentCorrelationSchemaVersion = 1
$script:IncidentCorrelationRequiredLayers = @(
  'pointer-provenance',
  'plugin-inventory',
  'slot-render',
  'tool-call',
  'session-turn',
  'quarantine',
  'restart',
  'web-readiness',
  'known-good'
)
$script:IncidentCorrelationMaxTextLength = 160

function Get-DshIncidentCorrelationProperty {
  param(
    [AllowNull()]$Object,
    [Parameter(Mandatory = $true)][string]$Name
  )
  if ($null -eq $Object) { return $null }
  if ($Object -is [System.Collections.IDictionary]) {
    if ($Object.Contains($Name)) { return $Object[$Name] }
    return $null
  }
  $property = $Object.PSObject.Properties[$Name]
  if ($null -eq $property) { return $null }
  return $property.Value
}

function Test-DshIncidentCorrelationProperty {
  param(
    [AllowNull()]$Object,
    [Parameter(Mandatory = $true)][string]$Name
  )
  if ($null -eq $Object) { return $false }
  if ($Object -is [System.Collections.IDictionary]) { return $Object.Contains($Name) }
  return $null -ne $Object.PSObject.Properties[$Name]
}

function Get-DshIncidentCorrelationPropertyNames {
  param([AllowNull()]$Object)
  if ($null -eq $Object) { return @() }
  if ($Object -is [System.Collections.IDictionary]) {
    return @($Object.Keys | ForEach-Object { [string]$_ })
  }
  return @($Object.PSObject.Properties | ForEach-Object { [string]$_.Name })
}

function Test-DshIncidentCorrelationDictionary {
  param([AllowNull()]$Object)
  return $null -ne $Object -and
    ($Object -is [System.Collections.IDictionary] -or
      ($Object -isnot [string] -and $Object -isnot [System.Collections.IEnumerable] -and @($Object.PSObject.Properties).Count -gt 0))
}

function Test-DshIncidentCorrelationSequence {
  param([AllowNull()]$Object)
  return $null -ne $Object -and
    $Object -is [System.Collections.IEnumerable] -and
    $Object -isnot [string] -and
    $Object -isnot [System.Collections.IDictionary]
}

function Get-DshIncidentCorrelationScalar {
  param(
    [AllowNull()]$Object,
    [Parameter(Mandatory = $true)][string]$Name
  )
  $value = Get-DshIncidentCorrelationProperty -Object $Object -Name $Name
  if ($null -eq $value) { return $null }
  if ($value -is [System.Collections.IDictionary] -or
      ($value -is [System.Collections.IEnumerable] -and $value -isnot [string])) { return $null }
  return $value
}

function Get-DshIncidentCorrelationFirstScalar {
  param(
    [object[]]$Objects = @(),
    [Parameter(Mandatory = $true)][string[]]$Names
  )
  foreach ($object in @($Objects)) {
    if ($null -eq $object) { continue }
    foreach ($name in $Names) {
      $value = Get-DshIncidentCorrelationScalar -Object $object -Name $name
      if ($null -ne $value) { return $value }
    }
  }
  return $null
}

function Get-DshIncidentCorrelationPathValue {
  param(
    [AllowNull()]$Object,
    [Parameter(Mandatory = $true)][string[]]$Path
  )
  $current = $Object
  foreach ($segment in $Path) {
    $current = Get-DshIncidentCorrelationProperty -Object $current -Name $segment
    if ($null -eq $current) { return $null }
  }
  if ($current -is [System.Collections.IDictionary] -or
      ($current -is [System.Collections.IEnumerable] -and $current -isnot [string])) { return $null }
  return $current
}

function Get-DshIncidentCorrelationHash {
  param([Parameter(Mandatory = $true)][string]$Text)
  $sha = [Security.Cryptography.SHA256]::Create()
  try {
    return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)))).Replace('-', '').ToLowerInvariant()
  } finally {
    $sha.Dispose()
  }
}

function Get-DshIncidentCorrelationSortedUnique {
  param([object[]]$Values = @())
  $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
  $list = [System.Collections.Generic.List[string]]::new()
  foreach ($value in @($Values)) {
    if ($null -eq $value) { continue }
    $text = [string]$value
    if ($seen.Add($text)) { [void]$list.Add($text) }
  }
  $list.Sort([StringComparer]::Ordinal)
  return @($list)
}

function Get-DshIncidentCorrelationSafeValue {
  param(
    [AllowNull()]$Value,
    [Parameter(Mandatory = $true)][ref]$Rejected,
    [int]$MaxLength = $script:IncidentCorrelationMaxTextLength
  )
  if ($null -eq $Value) { return $null }
  $text = ([string]$Value).Trim()
  if ([string]::IsNullOrWhiteSpace($text)) { return $null }
  if ($text.Length -gt $MaxLength -or $text -match '[\r\n\t]') {
    $Rejected.Value = $true
    return $null
  }
  if ($text -match '(?i)(authorization|cookie|set-cookie|bearer|api[_-]?key|access[_-]?token|refresh[_-]?token|password|secret|command|script|arguments?|result|content|cwd)') {
    $Rejected.Value = $true
    return $null
  }
  if ($text -match '(?i)^(?:[a-z]:[\\/]|\\\\|/|file:|https?://)') {
    $Rejected.Value = $true
    return $null
  }
  if ($text -match '[<>]') {
    $Rejected.Value = $true
    return $null
  }
  return $text
}

function Get-DshIncidentCorrelationSafeInteger {
  param([AllowNull()]$Value)
  if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) { return $null }
  try {
    $number = [int64]$Value
    if ($number -lt 0 -or $number -gt 1000000000000000) { return $null }
    return $number
  } catch {
    return $null
  }
}

function Get-DshIncidentCorrelationBoolean {
  param([AllowNull()]$Value)
  if ($null -eq $Value) { return $null }
  if ($Value -is [bool]) { return [bool]$Value }
  $text = ([string]$Value).Trim().ToLowerInvariant()
  if ($text -eq 'true') { return $true }
  if ($text -eq 'false') { return $false }
  return $null
}

function Get-DshIncidentCorrelationLayer {
  param([AllowNull()][string]$Value)
  if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
  $text = $Value.Trim().ToLowerInvariant()
  switch -Regex ($text) {
    'pointer|provenance' { return 'pointer-provenance' }
    'plugin.?inventory|inventory|dynamic.?plugin|plugin.?failure' { return 'plugin-inventory' }
    'slot|render|cell|entry.?error' { return 'slot-render' }
    'tool|dispatch|call' { return 'tool-call' }
    'session|turn|agent.?error' { return 'session-turn' }
    'quarantine|isolation|guard' { return 'quarantine' }
    'restart|supervisor|recovery' { return 'restart' }
    'web|readiness|ready|http' { return 'web-readiness' }
    'known.?good|checkpoint|snapshot|restore' { return 'known-good' }
    default { return $null }
  }
}

function Get-DshIncidentCorrelationLayerForKey {
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    [AllowNull()][string]$CurrentLayer
  )
  $key = $Name.ToLowerInvariant()
  if ($CurrentLayer -eq 'tool-call' -and $key -in @('session', 'history', 'observation')) { return $CurrentLayer }
  switch -Regex ($key) {
    '^pointer(provenance|evidence)?$' { return 'pointer-provenance' }
    'provenance' { return 'pointer-provenance' }
    '^plugin(inventory|entries|failure|failures)?$' { return 'plugin-inventory' }
    'inventory' { return 'plugin-inventory' }
    'render|slot|cell|runerror|renderfailure' { return 'slot-render' }
    'tool(call|result|calls|results)?|dispatch' { return 'tool-call' }
    'session|turn|history' { return 'session-turn' }
    'quarantine|guard|isolat' { return 'quarantine' }
    'restart|supervisor|recovery' { return 'restart' }
    'readiness|web|health' { return 'web-readiness' }
    'known.?good|checkpoint|snapshot|restore' { return 'known-good' }
    default { return $null }
  }
}

function Get-DshIncidentCorrelationEventType {
  param([object[]]$Objects = @())
  return [string](Get-DshIncidentCorrelationFirstScalar -Objects $Objects -Names @('type', 'eventType', 'kind'))
}

function Get-DshIncidentCorrelationStatus {
  param(
    [AllowNull()][string]$Layer,
    [AllowNull()][string]$EventType,
    [object[]]$Objects = @()
  )
  $statusRaw = Get-DshIncidentCorrelationFirstScalar -Objects $Objects -Names @('status', 'state', 'outcome', 'result', 'reasonKind', 'fiberPhase')
  if ($null -eq $statusRaw) {
    foreach ($object in @($Objects)) {
      $reason = Get-DshIncidentCorrelationProperty -Object $object -Name 'reason'
      $reasonKind = Get-DshIncidentCorrelationScalar -Object $reason -Name 'kind'
      if ($null -ne $reasonKind) { $statusRaw = $reasonKind; break }
    }
  }

  $isError = Get-DshIncidentCorrelationFirstScalar -Objects $Objects -Names @('isError', 'dispatchError', 'failed')
  $isErrorBool = Get-DshIncidentCorrelationBoolean -Value $isError
  if ($isErrorBool -eq $true) {
    return [PSCustomObject]@{ value = 'ERROR'; known = $true }
  }

  $ready = Get-DshIncidentCorrelationFirstScalar -Objects $Objects -Names @('ready', 'webReady')
  $readyBool = Get-DshIncidentCorrelationBoolean -Value $ready
  if ($null -ne $readyBool) {
    return [PSCustomObject]@{ value = if ($readyBool) { 'OK' } else { 'ERROR' }; known = $true }
  }

  $hasErrorProperty = $false
  foreach ($object in @($Objects)) {
    if (Test-DshIncidentCorrelationProperty -Object $object -Name 'error') {
      if ($null -ne (Get-DshIncidentCorrelationProperty -Object $object -Name 'error')) { $hasErrorProperty = $true }
    }
  }
  if ($hasErrorProperty) {
    return [PSCustomObject]@{ value = 'ERROR'; known = $true }
  }

  $text = if ($null -eq $statusRaw) { '' } else { ([string]$statusRaw).Trim().ToLowerInvariant() }
  if (-not [string]::IsNullOrWhiteSpace($text)) {
    switch -Regex ($text) {
      '^(error|failed|failure|crash|timeout|timed.?out|deadline|unavailable|not.?ready|missing|broken|aborted)$' { return [PSCustomObject]@{ value = 'ERROR'; known = $true } }
      '^(quarantined|isolated|disabled)$' { return [PSCustomObject]@{ value = 'QUARANTINED'; known = $true } }
      '^(restarted|restart|recovered)$' { return [PSCustomObject]@{ value = 'RESTARTED'; known = $true } }
      '^(ready|healthy|success|succeeded|pass|passed|complete|completed|restored|known.?good|ok|present)$' {
        $value = if ($Layer -eq 'restart') { 'RESTARTED' } elseif ($Layer -eq 'quarantine') { 'QUARANTINED' } else { 'OK' }
        return [PSCustomObject]@{ value = $value; known = $true }
      }
      '^observed$' { return [PSCustomObject]@{ value = 'OBSERVED'; known = $true } }
      '^(pending|loading|running|started)$' { return [PSCustomObject]@{ value = 'PENDING'; known = $true } }
      '^conflict$' { return [PSCustomObject]@{ value = 'CONFLICT'; known = $true } }
      '^unknown$' { return [PSCustomObject]@{ value = 'UNKNOWN'; known = $false } }
      default { return [PSCustomObject]@{ value = 'UNKNOWN'; known = $false } }
    }
  }

  $event = if ([string]::IsNullOrWhiteSpace($EventType)) { '' } else { $EventType.ToLowerInvariant() }
  switch ($Layer) {
    'tool-call' {
      if ($event -match 'result|dispatch') { return [PSCustomObject]@{ value = 'OK'; known = $true } }
      if ($event -match 'call') { return [PSCustomObject]@{ value = 'PENDING'; known = $true } }
    }
    'session-turn' {
      if ($event -match 'error|turn.?end') { return [PSCustomObject]@{ value = 'OBSERVED'; known = $true } }
    }
    'quarantine' { return [PSCustomObject]@{ value = 'QUARANTINED'; known = $true } }
    'restart' { return [PSCustomObject]@{ value = 'RESTARTED'; known = $true } }
    'web-readiness' { return [PSCustomObject]@{ value = 'UNKNOWN'; known = $false } }
    'known-good' { return [PSCustomObject]@{ value = 'OBSERVED'; known = $true } }
    default { }
  }
  return [PSCustomObject]@{ value = 'OBSERVED'; known = $true }
}

function Get-DshIncidentCorrelationConfidence {
  param([object[]]$Objects = @())
  $raw = Get-DshIncidentCorrelationFirstScalar -Objects $Objects -Names @('confidence')
  if ($null -eq $raw) { return 'none' }
  switch (([string]$raw).Trim().ToLowerInvariant()) {
    'high' { return 'strong' }
    'strong' { return 'strong' }
    'medium' { return 'weak' }
    'low' { return 'weak' }
    'weak' { return 'weak' }
    default { return 'none' }
  }
}

function Test-DshIncidentCorrelationSensitiveObject {
  param(
    [AllowNull()]$Object,
    [int]$Depth = 0
  )
  if ($null -eq $Object -or $Depth -gt 10) { return $false }
  if (Test-DshIncidentCorrelationSequence -Object $Object) {
    foreach ($item in @($Object)) {
      if (Test-DshIncidentCorrelationSensitiveObject -Object $item -Depth ($Depth + 1)) { return $true }
    }
    return $false
  }
  if (-not (Test-DshIncidentCorrelationDictionary -Object $Object)) { return $false }
  foreach ($name in @(Get-DshIncidentCorrelationPropertyNames -Object $Object)) {
    $lower = $name.ToLowerInvariant()
    if ($lower -match '^(command|commands|script|arguments?|result(body)?|content|text|body|cookie|authorization|headers?|cwd|path|url|raw)$' -or
        $lower -match '(token|secret|password)') {
      return $true
    }
    $child = Get-DshIncidentCorrelationProperty -Object $Object -Name $name
    if (Test-DshIncidentCorrelationSensitiveObject -Object $child -Depth ($Depth + 1)) { return $true }
  }
  return $false
}

function Get-DshIncidentCorrelationContext {
  param(
    [AllowNull()]$Object,
    [AllowNull()][hashtable]$BaseContext,
    [Parameter(Mandatory = $true)][ref]$Sensitive
  )
  $context = [ordered]@{
    sessionId = if ($null -ne $BaseContext) { $BaseContext.sessionId } else { $null }
    turn = if ($null -ne $BaseContext) { $BaseContext.turn } else { $null }
    incidentKey = if ($null -ne $BaseContext) { $BaseContext.incidentKey } else { $null }
    checkpointId = if ($null -ne $BaseContext) { $BaseContext.checkpointId } else { $null }
    restartId = if ($null -ne $BaseContext) { $BaseContext.restartId } else { $null }
  }
  $rejected = $false
  $session = Get-DshIncidentCorrelationSafeValue -Value (Get-DshIncidentCorrelationScalar -Object $Object -Name 'sessionId') -Rejected ([ref]$rejected)
  $turn = Get-DshIncidentCorrelationSafeInteger -Value (Get-DshIncidentCorrelationScalar -Object $Object -Name 'turn')
  $incident = Get-DshIncidentCorrelationScalar -Object $Object -Name 'incidentKey'
  if ($null -eq $incident) { $incident = Get-DshIncidentCorrelationScalar -Object $Object -Name 'correlationKey' }
  if ($null -eq $incident) { $incident = Get-DshIncidentCorrelationScalar -Object $Object -Name 'correlationId' }
  if ($null -eq $incident) { $incident = Get-DshIncidentCorrelationScalar -Object $Object -Name 'traceId' }
  if ($null -eq $incident) { $incident = Get-DshIncidentCorrelationScalar -Object $Object -Name 'incidentId' }
  $incidentSafe = Get-DshIncidentCorrelationSafeValue -Value $incident -Rejected ([ref]$rejected)
  $checkpoint = Get-DshIncidentCorrelationScalar -Object $Object -Name 'checkpointId'
  if ($null -eq $checkpoint) { $checkpoint = Get-DshIncidentCorrelationScalar -Object $Object -Name 'snapshotId' }
  $checkpointSafe = Get-DshIncidentCorrelationSafeValue -Value $checkpoint -Rejected ([ref]$rejected)
  $restart = Get-DshIncidentCorrelationScalar -Object $Object -Name 'restartId'
  if ($null -eq $restart) { $restart = Get-DshIncidentCorrelationScalar -Object $Object -Name 'runId' }
  $restartSafe = Get-DshIncidentCorrelationSafeValue -Value $restart -Rejected ([ref]$rejected)
  if ($null -ne $session) { $context.sessionId = $session }
  if ($null -ne $turn) { $context.turn = $turn }
  if ($null -ne $incidentSafe) { $context.incidentKey = $incidentSafe }
  if ($null -ne $checkpointSafe) { $context.checkpointId = $checkpointSafe }
  if ($null -ne $restartSafe) { $context.restartId = $restartSafe }
  if ($rejected) { $Sensitive.Value = $true }
  return $context
}

function Get-DshIncidentCorrelationRecord {
  param(
    [AllowNull()]$Container,
    [AllowNull()]$Event,
    [AllowNull()]$Data,
    [AllowNull()][string]$LayerHint,
    [Parameter(Mandatory = $true)][hashtable]$Context,
    [Parameter(Mandatory = $true)][ref]$Sensitive
  )
  $objects = @($Container, $Event, $Data) | Where-Object { $null -ne $_ }
  $eventType = Get-DshIncidentCorrelationEventType -Objects $objects
  $rawLayer = Get-DshIncidentCorrelationFirstScalar -Objects $objects -Names @('layer', 'sourceLayer', 'category')
  $layer = Get-DshIncidentCorrelationLayer -Value ([string]$rawLayer)
  if ($null -eq $layer) { $layer = Get-DshIncidentCorrelationLayer -Value $eventType }
  if ($null -eq $layer) { $layer = Get-DshIncidentCorrelationLayer -Value (Get-DshIncidentCorrelationFirstScalar -Objects $objects -Names @('kind')) }
  if ($null -eq $layer) { $layer = $LayerHint }
  $layerKnown = $null -ne $layer
  if (-not $layerKnown) { $layer = 'unknown' }

  $localRejected = $false
  $seq = Get-DshIncidentCorrelationSafeInteger -Value (Get-DshIncidentCorrelationFirstScalar -Objects $objects -Names @('seq', 'sequence'))
  $turn = Get-DshIncidentCorrelationSafeInteger -Value (Get-DshIncidentCorrelationFirstScalar -Objects $objects -Names @('turn'))
  if ($null -eq $turn) { $turn = $Context.turn }

  $callIdRaw = Get-DshIncidentCorrelationFirstScalar -Objects $objects -Names @('callId', 'toolCallId')
  if ($null -eq $callIdRaw) {
    foreach ($object in @($objects)) {
      $sourceCallId = Get-DshIncidentCorrelationPathValue -Object $object -Path @('message', 'source', 'callId')
      if ($null -eq $sourceCallId) { $sourceCallId = Get-DshIncidentCorrelationPathValue -Object $object -Path @('source', 'callId') }
      if ($null -ne $sourceCallId) { $callIdRaw = $sourceCallId; break }
    }
  }
  $callId = Get-DshIncidentCorrelationSafeValue -Value $callIdRaw -Rejected ([ref]$localRejected)

  $pluginRaw = Get-DshIncidentCorrelationFirstScalar -Objects $objects -Names @('pluginId', 'plugin', 'entryId', 'inventoryEntryId')
  $pluginId = Get-DshIncidentCorrelationSafeValue -Value $pluginRaw -Rejected ([ref]$localRejected)
  $moduleRaw = Get-DshIncidentCorrelationFirstScalar -Objects $objects -Names @('module', 'moduleName', 'registrant')
  $module = Get-DshIncidentCorrelationSafeValue -Value $moduleRaw -Rejected ([ref]$localRejected)
  $slotRaw = Get-DshIncidentCorrelationFirstScalar -Objects $objects -Names @('slot', 'slotName')
  if ($null -eq $slotRaw -and $layer -in @('pointer-provenance', 'slot-render')) {
    $slotRaw = Get-DshIncidentCorrelationFirstScalar -Objects $objects -Names @('name')
  }
  $slot = Get-DshIncidentCorrelationSafeValue -Value $slotRaw -Rejected ([ref]$localRejected)

  $toolRaw = Get-DshIncidentCorrelationFirstScalar -Objects $objects -Names @('tool', 'toolName')
  if ($null -eq $toolRaw -and $layer -eq 'tool-call') { $toolRaw = Get-DshIncidentCorrelationFirstScalar -Objects $objects -Names @('name') }
  $tool = Get-DshIncidentCorrelationSafeValue -Value $toolRaw -Rejected ([ref]$localRejected) -MaxLength 120

  $status = Get-DshIncidentCorrelationStatus -Layer $layer -EventType $eventType -Objects $objects
  $confidence = Get-DshIncidentCorrelationConfidence -Objects $objects

  $record = [ordered]@{
    seq = $seq
    callId = $callId
    pluginId = $pluginId
    module = $module
    slot = $slot
    turn = $turn
    tool = $tool
    layer = $layer
    layerKnown = $layerKnown
    status = [string]$status.value
    statusKnown = [bool]$status.known
    confidence = $confidence
    sessionId = $Context.sessionId
    incidentKey = $Context.incidentKey
    checkpointId = $Context.checkpointId
    restartId = $Context.restartId
    sensitiveObserved = $localRejected
  }
  if ($localRejected) { $Sensitive.Value = $true }
  return $record
}

function Test-DshIncidentCorrelationRecordShape {
  param(
    [AllowNull()]$Container,
    [AllowNull()]$Event,
    [AllowNull()]$Data,
    [AllowNull()][string]$LayerHint
  )
  if ($null -ne $Event) { return $true }
  $objects = @($Container, $Data) | Where-Object { $null -ne $_ }
  $collectionNames = @('events', 'records', 'evidence', 'signals', 'entries', 'items', 'children', 'toolCalls', 'toolResults')
  $hasCollection = $false
  foreach ($object in @($objects)) {
    foreach ($name in $collectionNames) {
      if (Test-DshIncidentCorrelationProperty -Object $object -Name $name) { $hasCollection = $true; break }
    }
    if ($hasCollection) { break }
  }
  $identityNames = @('seq', 'sequence', 'callId', 'toolCallId', 'pluginId', 'plugin', 'entryId', 'module', 'moduleName', 'registrant', 'slot', 'slotName', 'turn', 'isError', 'dispatchError', 'failed', 'ready', 'webReady', 'status', 'state', 'outcome', 'reasonKind', 'fiberPhase', 'type', 'eventType', 'kind')
  foreach ($object in @($objects)) {
    foreach ($name in $identityNames) {
      if (Test-DshIncidentCorrelationProperty -Object $object -Name $name) {
        if (-not $hasCollection -or $name -in @('seq', 'sequence', 'callId', 'toolCallId', 'pluginId', 'plugin', 'entryId', 'module', 'moduleName', 'registrant', 'slot', 'slotName', 'isError', 'dispatchError', 'failed', 'ready', 'webReady', 'type', 'eventType')) { return $true }
      }
    }
  }
  return (-not $hasCollection -and -not [string]::IsNullOrWhiteSpace($LayerHint) -and $null -ne $Container)
}

function Get-DshIncidentCorrelationRecordFingerprint {
  param([Parameter(Mandatory = $true)][System.Collections.IDictionary]$Record)
  $parts = @(
    [string]$Record.layer,
    [string]$Record.seq,
    [string]$Record.callId,
    [string]$Record.pluginId,
    [string]$Record.module,
    [string]$Record.slot,
    [string]$Record.turn,
    [string]$Record.tool,
    [string]$Record.status,
    [string]$Record.confidence
  )
  return ($parts -join ([char]31))
}

function Set-DshIncidentCorrelationAnchors {
  param([Parameter(Mandatory = $true)][System.Collections.IDictionary]$Record)
  $strong = [System.Collections.Generic.List[string]]::new()
  $weak = [System.Collections.Generic.List[string]]::new()
  if (-not [string]::IsNullOrWhiteSpace([string]$Record.incidentKey)) {
    [void]$strong.Add('explicit|' + [string]$Record.incidentKey.ToLowerInvariant())
  }
  if (-not [string]::IsNullOrWhiteSpace([string]$Record.checkpointId)) {
    [void]$strong.Add('checkpoint|' + [string]$Record.checkpointId.ToLowerInvariant())
  }
  if (-not [string]::IsNullOrWhiteSpace([string]$Record.restartId)) {
    [void]$strong.Add('restart|' + [string]$Record.restartId.ToLowerInvariant())
  }
  $sessionDigest = $null
  if (-not [string]::IsNullOrWhiteSpace([string]$Record.sessionId)) {
    $sessionDigest = Get-DshIncidentCorrelationHash -Text ([string]$Record.sessionId.ToLowerInvariant())
  }
  if ($null -ne $sessionDigest -and $null -ne $Record.turn) {
    [void]$strong.Add("session-turn|$sessionDigest|$($Record.turn)")
  } elseif ($null -ne $sessionDigest -and $null -ne $Record.seq) {
    [void]$strong.Add("session-seq|$sessionDigest|$($Record.seq)")
  }
  if (-not [string]::IsNullOrWhiteSpace([string]$Record.callId)) {
    [void]$strong.Add('call|' + [string]$Record.callId.ToLowerInvariant())
  }
  if (-not [string]::IsNullOrWhiteSpace([string]$Record.pluginId) -and
      -not [string]::IsNullOrWhiteSpace([string]$Record.module) -and
      -not [string]::IsNullOrWhiteSpace([string]$Record.slot)) {
    [void]$weak.Add(('tuple|' + ((@($Record.pluginId, $Record.module, $Record.slot)) -join '|')).ToLowerInvariant())
  } elseif (-not [string]::IsNullOrWhiteSpace([string]$Record.pluginId) -and
      -not [string]::IsNullOrWhiteSpace([string]$Record.module)) {
    [void]$weak.Add(('plugin-module|' + ((@($Record.pluginId, $Record.module)) -join '|')).ToLowerInvariant())
  } elseif ($null -ne $Record.seq -and -not [string]::IsNullOrWhiteSpace([string]$Record.layer)) {
    [void]$weak.Add("layer-seq|$($Record.layer.ToLowerInvariant())|$($Record.seq)")
  }
  $fingerprint = Get-DshIncidentCorrelationRecordFingerprint -Record $Record
  if ($strong.Count -eq 0 -and $weak.Count -eq 0) { [void]$weak.Add('record|' + (Get-DshIncidentCorrelationHash -Text $fingerprint)) }
  $Record.strongAnchors = @(Get-DshIncidentCorrelationSortedUnique -Values @($strong))
  $Record.weakAnchors = @(Get-DshIncidentCorrelationSortedUnique -Values @($weak))
  $combinedAnchors = @($strong) + @($weak)
  $Record.anchors = @(Get-DshIncidentCorrelationSortedUnique -Values $combinedAnchors)
  $Record.fingerprint = $fingerprint
}

function Add-DshIncidentCorrelationCandidate {
  param(
    [AllowNull()]$Candidate,
    [Parameter(Mandatory = $true)][AllowEmptyCollection()][System.Collections.Generic.List[object]]$Records,
    [Parameter(Mandatory = $true)][hashtable]$State
  )
  if ($null -eq $Candidate) { return }
  if ($Records.Count -ge [int]$State.maxRecords) {
    $State.limitHit = $true
    return
  }
  Set-DshIncidentCorrelationAnchors -Record $Candidate
  $dedupeKey = Get-DshIncidentCorrelationHash -Text ([string]$Candidate.layer + '|' + [string]$Candidate.fingerprint)
  if ($State.dedupe.ContainsKey($dedupeKey)) {
    $State.ignoredRecords = [int]$State.ignoredRecords + 1
    return
  }
  $State.dedupe[$dedupeKey] = $true
  [void]$Records.Add($Candidate)
}

function Add-DshIncidentCorrelationCandidatesFromObject {
  param(
    [AllowNull()]$Object,
    [AllowNull()][string]$LayerHint,
    [Parameter(Mandatory = $true)][hashtable]$Context,
    [Parameter(Mandatory = $true)][AllowEmptyCollection()][System.Collections.Generic.List[object]]$Records,
    [Parameter(Mandatory = $true)][hashtable]$State,
    [int]$Depth = 0,
    [switch]$Root
  )
  if ($null -eq $Object) { return }
  if ($Depth -gt 10) { $State.limitHit = $true; return }

  if ($Object -is [string]) {
    $parsed = $null
    try {
      $parsed = $Object | ConvertFrom-Json -ErrorAction Stop
    } catch {
      $State.invalidFragments = [int]$State.invalidFragments + 1
      return
    }
    Add-DshIncidentCorrelationCandidatesFromObject -Object $parsed -LayerHint $LayerHint -Context $Context -Records $Records -State $State -Depth ($Depth + 1)
    return
  }
  if (Test-DshIncidentCorrelationSequence -Object $Object) {
    foreach ($item in @($Object)) {
      Add-DshIncidentCorrelationCandidatesFromObject -Object $item -LayerHint $LayerHint -Context $Context -Records $Records -State $State -Depth ($Depth + 1)
    }
    return
  }
  if (-not (Test-DshIncidentCorrelationDictionary -Object $Object)) { return }

  if ($Root) {
    if (Test-DshIncidentCorrelationSensitiveObject -Object $Object) { $State.sensitiveObserved = $true }
  }
  $localSensitive = $false
  $localContext = Get-DshIncidentCorrelationContext -Object $Object -BaseContext $Context -Sensitive ([ref]$localSensitive)
  if ($localSensitive) { $State.sensitiveObserved = $true }

  $event = Get-DshIncidentCorrelationProperty -Object $Object -Name 'event'
  $data = $null
  if ($null -ne $event) { $data = Get-DshIncidentCorrelationProperty -Object $event -Name 'data' }
  if ($null -eq $data) { $data = Get-DshIncidentCorrelationProperty -Object $Object -Name 'data' }
  $objectLayer = Get-DshIncidentCorrelationLayer -Value ([string](Get-DshIncidentCorrelationFirstScalar -Objects @($Object, $event) -Names @('layer', 'sourceLayer', 'category')))
  if ($null -eq $objectLayer) { $objectLayer = Get-DshIncidentCorrelationLayer -Value (Get-DshIncidentCorrelationEventType -Objects @($Object, $event)) }
  if ($null -eq $objectLayer) { $objectLayer = Get-DshIncidentCorrelationLayer -Value ([string](Get-DshIncidentCorrelationFirstScalar -Objects @($Object, $event) -Names @('kind'))) }
  $effectiveLayer = if ($null -ne $objectLayer) { $objectLayer } else { $LayerHint }
  if (Test-DshIncidentCorrelationRecordShape -Container $Object -Event $event -Data $data -LayerHint $effectiveLayer) {
    $candidate = Get-DshIncidentCorrelationRecord -Container $Object -Event $event -Data $data -LayerHint $effectiveLayer -Context $localContext -Sensitive ([ref]$localSensitive)
    if ($localSensitive) { $State.sensitiveObserved = $true }
    Add-DshIncidentCorrelationCandidate -Candidate $candidate -Records $Records -State $State
  }

  foreach ($name in @(Get-DshIncidentCorrelationPropertyNames -Object $Object)) {
    $lower = $name.ToLowerInvariant()
    if ($lower -eq 'event' -or ($lower -eq 'data' -and $null -ne $event)) { continue }
    $child = Get-DshIncidentCorrelationProperty -Object $Object -Name $name
    if ($null -eq $child) { continue }
    if ($lower -match '^(command|commands|script|arguments?|result(body)?|content|text|body|cookie|authorization|headers?|cwd|path|url|raw)$' -or $lower -match '(token|secret|password)') {
      $State.sensitiveObserved = $true
      continue
    }
    if (-not (Test-DshIncidentCorrelationDictionary -Object $child) -and -not (Test-DshIncidentCorrelationSequence -Object $child)) { continue }
    $childLayer = Get-DshIncidentCorrelationLayerForKey -Name $name -CurrentLayer $effectiveLayer
    $isContainer = $lower -in @('events', 'records', 'evidence', 'signals', 'entries', 'items', 'children', 'observations', 'toolcalls', 'toolresults', 'turnerrors', 'resulterrors', 'runerrors', 'renderfailures', 'runtimeDiagnostics'.ToLowerInvariant())
    if ($null -eq $childLayer -and $isContainer) { $childLayer = $effectiveLayer }
    if ($null -ne $childLayer -or $isContainer -or $lower -in @('event', 'data', 'session', 'history', 'snapshot', 'value')) {
      Add-DshIncidentCorrelationCandidatesFromObject -Object $child -LayerHint $childLayer -Context $localContext -Records $Records -State $State -Depth ($Depth + 1)
    }
  }
}

function Get-DshIncidentCorrelationGroupCommonStrongAnchors {
  param([object[]]$Records = @())
  if (@($Records).Count -eq 0) { return @() }
  $common = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
  foreach ($anchor in @($Records[0].strongAnchors)) { [void]$common.Add([string]$anchor) }
  foreach ($record in @($Records | Select-Object -Skip 1)) {
    $current = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($anchor in @($record.strongAnchors)) { [void]$current.Add([string]$anchor) }
    foreach ($anchor in @($common)) {
      if (-not $current.Contains($anchor)) { [void]$common.Remove($anchor) }
    }
  }
  return @(Get-DshIncidentCorrelationSortedUnique -Values @($common))
}

function Get-DshIncidentCorrelationGroupReasonCodes {
  param(
    [object[]]$Records = @(),
    [string[]]$RequiredLayers = @()
  )
  $codes = [System.Collections.Generic.List[string]]::new()
  $add = {
    param([string]$Code)
    if (-not [string]::IsNullOrWhiteSpace($Code) -and $Code -notin @($codes)) { [void]$codes.Add($Code) }
  }
  $distinct = {
    param([string]$Name)
    @(Get-DshIncidentCorrelationSortedUnique -Values @($Records | ForEach-Object { [string]$_.($Name) } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }))
  }
  if (@($Records | Where-Object { -not $_.layerKnown }).Count -gt 0) { & $add 'UNKNOWN_LAYER' }
  if (@($Records | Where-Object { -not $_.statusKnown }).Count -gt 0) { & $add 'UNKNOWN_STATUS' }
  if (@($Records | Where-Object { $_.sensitiveObserved }).Count -gt 0) { & $add 'SENSITIVE_FIELD_OBSERVED' }

  if (@(& $distinct 'incidentKey').Count -gt 1) { & $add 'EXPLICIT_ID_CONFLICT' }
  if (@(& $distinct 'sessionId').Count -gt 1) { & $add 'SESSION_ID_CONFLICT' }
  if (@(& $distinct 'checkpointId').Count -gt 1) { & $add 'CHECKPOINT_CONFLICT' }
  if (@(& $distinct 'restartId').Count -gt 1) { & $add 'RESTART_CONFLICT' }
  if (@(& $distinct 'pluginId').Count -gt 1) { & $add 'PLUGIN_ID_CONFLICT' }
  if (@(& $distinct 'module').Count -gt 1) { & $add 'MODULE_CONFLICT' }
  if (@(& $distinct 'slot').Count -gt 1) { & $add 'SLOT_CONFLICT' }

  $observedLayers = @(Get-DshIncidentCorrelationSortedUnique -Values @($Records | ForEach-Object { [string]$_.layer }))
  foreach ($required in @($RequiredLayers)) {
    if ($required -notin $observedLayers) { & $add ('MISSING_' + $required.ToUpperInvariant().Replace('-', '_')) }
  }
  return @(Get-DshIncidentCorrelationSortedUnique -Values @($codes))
}

function New-DshIncidentCorrelationIncidentId {
  param(
    [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$CommonStrongAnchors,
    [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$AllAnchors,
    [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Fingerprints
  )
  $basis = if (@($CommonStrongAnchors).Count -gt 0) {
    'strong|' + ((Get-DshIncidentCorrelationSortedUnique -Values $CommonStrongAnchors) -join '|')
  } elseif (@($AllAnchors).Count -gt 0) {
    'weak|' + ((Get-DshIncidentCorrelationSortedUnique -Values $AllAnchors) -join '|')
  } else {
    'records|' + ((Get-DshIncidentCorrelationSortedUnique -Values $Fingerprints) -join '|')
  }
  return 'dsh-inc-' + (Get-DshIncidentCorrelationHash -Text $basis).Substring(0, 32)
}

function Get-DshIncidentCorrelationEvidenceProjection {
  param(
    [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Record,
    [Parameter(Mandatory = $true)][string]$IncidentId
  )
  return [ordered]@{
    seq = $Record.seq
    callId = $Record.callId
    pluginId = $Record.pluginId
    module = $Record.module
    slot = $Record.slot
    turn = $Record.turn
    tool = $Record.tool
    layer = $Record.layer
    status = $Record.status
    confidence = $Record.confidence
    incidentId = $IncidentId
  }
}

function ConvertTo-DshIncidentCorrelation {
  [CmdletBinding()]
  param(
    [Parameter(Position = 0)]
    [Alias('Fragment', 'Fragments', 'Json', 'JsonFragments')]
    [AllowEmptyCollection()]
    [object[]]$InputObject = @(),
    [Alias('Path', 'InputPaths')]
    [string[]]$InputPath = @(),
    [Alias('RequiredLayer')]
    [string[]]$RequiredLayers = @(),
    [ValidateRange(1, 4096)]
    [int]$MaxRecords = 512,
    [ValidateRange(1, 128)]
    [int]$MaxFragments = 64
  )
  $required = if (@($RequiredLayers).Count -eq 0) {
    @($script:IncidentCorrelationRequiredLayers)
  } else {
    @(Get-DshIncidentCorrelationSortedUnique -Values @($RequiredLayers | ForEach-Object { Get-DshIncidentCorrelationLayer -Value ([string]$_) } | Where-Object { $null -ne $_ }))
  }
  if (@($required).Count -eq 0) { $required = @($script:IncidentCorrelationRequiredLayers) }

  $records = [System.Collections.Generic.List[object]]::new()
  $state = @{
    maxRecords = $MaxRecords
    invalidFragments = 0
    sensitiveObserved = $false
    limitHit = $false
    ignoredRecords = 0
    dedupe = [System.Collections.Generic.Dictionary[string, bool]]::new([StringComparer]::Ordinal)
  }
  $fragmentCount = 0
  $baseContext = [ordered]@{ sessionId = $null; turn = $null; incidentKey = $null; checkpointId = $null; restartId = $null }

  foreach ($fragment in @($InputObject)) {
    if ($fragmentCount -ge $MaxFragments) { $state.limitHit = $true; break }
    $fragmentCount++
    Add-DshIncidentCorrelationCandidatesFromObject -Object $fragment -LayerHint $null -Context $baseContext -Records $records -State $state -Root
  }
  foreach ($path in @($InputPath)) {
    if ($fragmentCount -ge $MaxFragments) { $state.limitHit = $true; break }
    $fragmentCount++
    try {
      $text = Get-Content -LiteralPath $path -Raw -Encoding UTF8 -ErrorAction Stop
      Add-DshIncidentCorrelationCandidatesFromObject -Object $text -LayerHint $null -Context $baseContext -Records $records -State $state -Root
    } catch {
      $state.invalidFragments = [int]$state.invalidFragments + 1
    }
  }
  if ($state.limitHit) { $state.invalidFragments = [int]$state.invalidFragments + 1 }

  $groups = [System.Collections.Generic.List[object]]::new()
  $keyToIndexes = [System.Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
  for ($index = 0; $index -lt $records.Count; $index++) {
    foreach ($anchor in @($records[$index].anchors)) {
      if (-not $keyToIndexes.ContainsKey([string]$anchor)) { $keyToIndexes[[string]$anchor] = [System.Collections.Generic.List[int]]::new() }
      [void]$keyToIndexes[[string]$anchor].Add($index)
    }
  }

  $visited = [bool[]]::new($records.Count)
  for ($index = 0; $index -lt $records.Count; $index++) {
    if ($visited[$index]) { continue }
    $queue = [System.Collections.Generic.Queue[int]]::new()
    $queue.Enqueue($index)
    $groupRecords = [System.Collections.Generic.List[object]]::new()
    while ($queue.Count -gt 0) {
      $currentIndex = $queue.Dequeue()
      if ($visited[$currentIndex]) { continue }
      $visited[$currentIndex] = $true
      [void]$groupRecords.Add($records[$currentIndex])
      foreach ($anchor in @($records[$currentIndex].anchors)) {
        if (-not $keyToIndexes.ContainsKey([string]$anchor)) { continue }
        foreach ($linkedIndex in @($keyToIndexes[[string]$anchor])) {
          if (-not $visited[$linkedIndex]) { $queue.Enqueue($linkedIndex) }
        }
      }
    }
    [void]$groups.Add(@($groupRecords))
  }

  $incidentReports = [System.Collections.Generic.List[object]]::new()
  $groupStatuses = [System.Collections.Generic.List[string]]::new()
  $globalIssues = [System.Collections.Generic.List[string]]::new()
  if ([int]$state.invalidFragments -gt 0) { [void]$globalIssues.Add('INVALID_FRAGMENT') }
  if ($state.limitHit) { [void]$globalIssues.Add('INPUT_LIMIT') }
  if ($state.sensitiveObserved) { [void]$globalIssues.Add('SENSITIVE_FIELD_OBSERVED') }

  foreach ($group in @($groups)) {
    $groupArray = @($group)
    $commonStrong = @(Get-DshIncidentCorrelationGroupCommonStrongAnchors -Records $groupArray)
    $allAnchors = @(Get-DshIncidentCorrelationSortedUnique -Values @($groupArray | ForEach-Object { @($_.anchors) }))
    $fingerprints = @(Get-DshIncidentCorrelationSortedUnique -Values @($groupArray | ForEach-Object { [string]$_.fingerprint }))
    $incidentId = New-DshIncidentCorrelationIncidentId -CommonStrongAnchors $commonStrong -AllAnchors $allAnchors -Fingerprints $fingerprints
    $reasonCodes = [System.Collections.Generic.List[string]]::new()
    foreach ($code in @(Get-DshIncidentCorrelationGroupReasonCodes -Records $groupArray -RequiredLayers $required)) { [void]$reasonCodes.Add($code) }
    if ($commonStrong.Count -eq 0) {
      if ($groupArray.Count -gt 1) { [void]$reasonCodes.Add('AMBIGUOUS_WEAK_LINK') } else { [void]$reasonCodes.Add('NO_STABLE_ANCHOR') }
    }
    $uniqueReasonCodes = @(Get-DshIncidentCorrelationSortedUnique -Values @($reasonCodes))
    $reasonCodes = [System.Collections.Generic.List[string]]::new()
    foreach ($code in $uniqueReasonCodes) { [void]$reasonCodes.Add([string]$code) }
    $missing = @(Get-DshIncidentCorrelationSortedUnique -Values @($required | Where-Object { $_ -notin @($groupArray | ForEach-Object { [string]$_.layer } | Select-Object -Unique) }))
    $conflictCodes = @(Get-DshIncidentCorrelationSortedUnique -Values @($reasonCodes | Where-Object { $_ -match 'CONFLICT|AMBIGUOUS|SENSITIVE' }))
    $status = if ($conflictCodes.Count -gt 0) {
      'MANUAL_REVIEW'
    } elseif ($reasonCodes.Count -gt 0 -or $commonStrong.Count -eq 0) {
      'INCONCLUSIVE'
    } else {
      'CORRELATED'
    }
    [void]$groupStatuses.Add($status)
    foreach ($code in @($reasonCodes)) { if ($code -notin @($globalIssues)) { [void]$globalIssues.Add($code) } }

    $evidence = @($groupArray |
      Sort-Object @{ Expression = { if ($null -eq $_.seq) { [int64]9223372036854775807 } else { [int64]$_.seq } } }, layer, callId, pluginId |
      ForEach-Object { Get-DshIncidentCorrelationEvidenceProjection -Record $_ -IncidentId $incidentId })
    $observedLayers = @(Get-DshIncidentCorrelationSortedUnique -Values @($groupArray | ForEach-Object { [string]$_.layer }))
    $anchorStrength = if ($commonStrong.Count -gt 0) { 'strong' } elseif (@($groupArray | Where-Object { @($_.strongAnchors).Count -gt 0 }).Count -gt 0) { 'weak' } else { 'none' }
    $report = [ordered]@{
      incidentId = $incidentId
      status = $status
      anchorStrength = $anchorStrength
      evidenceCount = $evidence.Count
      observedLayers = @($observedLayers)
      missingLayers = @($missing)
      conflictCodes = @($conflictCodes)
      evidence = @($evidence)
    }
    [void]$incidentReports.Add($report)
  }

  $orderedIncidents = @($incidentReports | Sort-Object incidentId)
  $overallStatus = if (@($groupStatuses | Where-Object { $_ -eq 'MANUAL_REVIEW' }).Count -gt 0 -or $state.sensitiveObserved) {
    'MANUAL_REVIEW'
  } elseif ($orderedIncidents.Count -eq 0 -or @($groupStatuses | Where-Object { $_ -eq 'INCONCLUSIVE' }).Count -gt 0 -or [int]$state.invalidFragments -gt 0) {
    'INCONCLUSIVE'
  } else {
    'CORRELATED'
  }
  $privacy = [ordered]@{ metadataOnly = $true; rawPayloadStored = $false }
  return [ordered]@{
    schemaVersion = $script:IncidentCorrelationSchemaVersion
    kind = 'dsh-incident-correlation'
    status = $overallStatus
    incidentId = if ($orderedIncidents.Count -eq 1) { [string]$orderedIncidents[0].incidentId } else { $null }
    incidentCount = $orderedIncidents.Count
    requiredLayers = @($required)
    incidents = @($orderedIncidents)
    issueCodes = @(Get-DshIncidentCorrelationSortedUnique -Values @($globalIssues))
    invalidFragmentCount = [int]$state.invalidFragments
    ignoredRecordCount = [int]$state.ignoredRecords
    privacy = $privacy
  }
}

function Invoke-DshIncidentCorrelation {
  [CmdletBinding()]
  param(
    [Parameter(Position = 0)]
    [Alias('Fragment', 'Fragments', 'Json', 'JsonFragments')]
    [AllowEmptyCollection()]
    [object[]]$InputObject = @(),
    [Alias('Path', 'InputPaths')]
    [string[]]$InputPath = @(),
    [Alias('RequiredLayer')]
    [string[]]$RequiredLayers = @(),
    [ValidateRange(1, 4096)]
    [int]$MaxRecords = 512,
    [ValidateRange(1, 128)]
    [int]$MaxFragments = 64
  )
  return ConvertTo-DshIncidentCorrelation @PSBoundParameters
}

function New-DshIncidentCorrelation {
  [CmdletBinding()]
  param(
    [Parameter(Position = 0)]
    [Alias('Fragment', 'Fragments', 'Json', 'JsonFragments')]
    [AllowEmptyCollection()]
    [object[]]$InputObject = @(),
    [Alias('Path', 'InputPaths')]
    [string[]]$InputPath = @(),
    [Alias('RequiredLayer')]
    [string[]]$RequiredLayers = @(),
    [ValidateRange(1, 4096)]
    [int]$MaxRecords = 512,
    [ValidateRange(1, 128)]
    [int]$MaxFragments = 64
  )
  return ConvertTo-DshIncidentCorrelation @PSBoundParameters
}

function Test-DshIncidentCorrelationOutput {
  [CmdletBinding()]
  param([Parameter(Mandatory = $true)]$Report)
  $errors = [System.Collections.Generic.List[string]]::new()
  $topAllowed = @('schemaVersion', 'kind', 'status', 'incidentId', 'incidentCount', 'requiredLayers', 'incidents', 'issueCodes', 'invalidFragmentCount', 'ignoredRecordCount', 'privacy')
  $incidentAllowed = @('incidentId', 'status', 'anchorStrength', 'evidenceCount', 'observedLayers', 'missingLayers', 'conflictCodes', 'evidence')
  $evidenceAllowed = @('seq', 'callId', 'pluginId', 'module', 'slot', 'turn', 'tool', 'layer', 'status', 'confidence', 'incidentId')
  $privacyAllowed = @('metadataOnly', 'rawPayloadStored')
  $checkNames = {
    param($Object, [string[]]$Allowed, [string]$Prefix)
    foreach ($name in @(Get-DshIncidentCorrelationPropertyNames -Object $Object)) {
      if ($name -notin $Allowed) { [void]$errors.Add("$Prefix contains unsupported field") }
    }
  }
  & $checkNames $Report $topAllowed 'report'
  if ([int](Get-DshIncidentCorrelationProperty -Object $Report -Name 'schemaVersion') -ne $script:IncidentCorrelationSchemaVersion) { [void]$errors.Add('unsupported schemaVersion') }
  if ([string](Get-DshIncidentCorrelationProperty -Object $Report -Name 'kind') -cne 'dsh-incident-correlation') { [void]$errors.Add('unsupported kind') }
  if ([string](Get-DshIncidentCorrelationProperty -Object $Report -Name 'status') -notin @('CORRELATED', 'INCONCLUSIVE', 'MANUAL_REVIEW')) { [void]$errors.Add('unsupported report status') }
  $privacy = Get-DshIncidentCorrelationProperty -Object $Report -Name 'privacy'
  & $checkNames $privacy $privacyAllowed 'privacy'
  if ((Get-DshIncidentCorrelationProperty -Object $privacy -Name 'metadataOnly') -ne $true) { [void]$errors.Add('metadataOnly must be true') }
  if ((Get-DshIncidentCorrelationProperty -Object $privacy -Name 'rawPayloadStored') -ne $false) { [void]$errors.Add('rawPayloadStored must be false') }

  foreach ($incident in @(Get-DshIncidentCorrelationProperty -Object $Report -Name 'incidents')) {
    & $checkNames $incident $incidentAllowed 'incident'
    $incidentId = [string](Get-DshIncidentCorrelationProperty -Object $incident -Name 'incidentId')
    if ($incidentId -notmatch '^dsh-inc-[0-9a-f]{32}$') { [void]$errors.Add('incidentId is not stable-format') }
    if ([string](Get-DshIncidentCorrelationProperty -Object $incident -Name 'status') -notin @('CORRELATED', 'INCONCLUSIVE', 'MANUAL_REVIEW')) { [void]$errors.Add('unsupported incident status') }
    foreach ($evidence in @(Get-DshIncidentCorrelationProperty -Object $incident -Name 'evidence')) {
      & $checkNames $evidence $evidenceAllowed 'evidence'
      if ([string](Get-DshIncidentCorrelationProperty -Object $evidence -Name 'incidentId') -cne $incidentId) { [void]$errors.Add('evidence incidentId mismatch') }
      if ([string](Get-DshIncidentCorrelationProperty -Object $evidence -Name 'status') -notin @('OBSERVED', 'OK', 'ERROR', 'PENDING', 'QUARANTINED', 'RESTARTED', 'CONFLICT', 'UNKNOWN')) { [void]$errors.Add('unsupported evidence status') }
    }
  }
  return [ordered]@{ valid = $errors.Count -eq 0; errors = @($errors) }
}

Export-ModuleMember -Function @(
  'ConvertTo-DshIncidentCorrelation',
  'Invoke-DshIncidentCorrelation',
  'New-DshIncidentCorrelation',
  'Test-DshIncidentCorrelationOutput'
)
