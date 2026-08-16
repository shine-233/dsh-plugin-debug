[CmdletBinding()]
param(
  [string]$InputPath = '',
  [ValidateRange(1, 32)][int]$MaxDepth = 4
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:DshTraceRecursionSchemaVersion = 1
$script:DshTraceRecursionMaxInputBytes = 4194304
$script:DshTraceRecursionMaxEvents = 2000
$script:DshTraceRecursionMaxTypeLength = 120

function Get-DshTraceRecursionProperty {
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

function Test-DshTraceRecursionProperty {
  param(
    [AllowNull()]$Object,
    [Parameter(Mandatory = $true)][string]$Name
  )
  if ($null -eq $Object) { return $false }
  if ($Object -is [System.Collections.IDictionary]) { return $Object.Contains($Name) }
  return $null -ne $Object.PSObject.Properties[$Name]
}

function Get-DshTraceRecursionInteger {
  param([AllowNull()]$Value)
  if ($null -eq $Value -or $Value -is [bool]) { return $null }
  $parsed = [long]0
  if ([long]::TryParse([string]$Value, [Globalization.NumberStyles]::Integer, [Globalization.CultureInfo]::InvariantCulture, [ref]$parsed)) {
    return $parsed
  }
  return $null
}

function Get-DshTraceRecursionEventView {
  param([Parameter(Mandatory = $true)]$Entry)
  if ($null -eq $Entry -or $Entry -is [string] -or $Entry -is [ValueType]) { throw 'trace event is not an object' }
  $event = Get-DshTraceRecursionProperty -Object $Entry -Name 'event'
  if ($null -eq $event) { $event = $Entry }
  if ($null -eq $event -or $event -is [string] -or $event -is [ValueType]) { throw 'trace event payload is not an object' }
  $data = Get-DshTraceRecursionProperty -Object $event -Name 'data'
  if ($null -eq $data -or $data -is [string] -or $data -is [ValueType]) { $data = $event }
  return [PSCustomObject]@{ event = $event; data = $data }
}

function Get-DshTraceRecursionText {
  param(
    [Parameter(Mandatory = $true)]$Event,
    [Parameter(Mandatory = $true)]$Data,
    [Parameter(Mandatory = $true)][string[]]$Names
  )
  foreach ($name in $Names) {
    foreach ($source in @($Event, $Data)) {
      if (-not (Test-DshTraceRecursionProperty -Object $source -Name $name)) { continue }
      $value = Get-DshTraceRecursionProperty -Object $source -Name $name
      if ($null -eq $value -or $value -isnot [string]) { continue }
      $text = ([string]$value).Trim()
      if (-not [string]::IsNullOrWhiteSpace($text)) { return $text }
    }
  }
  return ''
}

function ConvertTo-DshTraceRecursionToken {
  param([Parameter(Mandatory = $true)][string]$Value)
  if ($Value.Length -gt $script:DshTraceRecursionMaxTypeLength -or $Value -match '\p{C}') { throw 'trace event type is invalid' }
  return (($Value.Trim().ToLowerInvariant() -replace '[\/_.\s]+', '-') -replace '-+', '-').Trim('-')
}

function Resolve-DshTraceRecursionMarker {
  param(
    [Parameter(Mandatory = $true)]$Event,
    [Parameter(Mandatory = $true)]$Data
  )
  $rawType = Get-DshTraceRecursionText -Event $Event -Data $Data -Names @('type', 'eventType', 'kind', 'name')
  if ([string]::IsNullOrWhiteSpace($rawType)) { return [PSCustomObject]@{ classification = 'ignored'; scope = $null; type = $null } }
  $type = ConvertTo-DshTraceRecursionToken -Value $rawType
  if ($type -match '(\$\{|\{\{|<dynamic>|\[dynamic\]|\*)' -and $type -match '(agent|workflow)') {
    return [PSCustomObject]@{ classification = 'ambiguous'; scope = $null; type = $null }
  }
  $phaseText = Get-DshTraceRecursionText -Event $Event -Data $Data -Names @('phase', 'action', 'state')
  $phase = if ([string]::IsNullOrWhiteSpace($phaseText)) { '' } else { ConvertTo-DshTraceRecursionToken -Value $phaseText }

  $startTypes = @('agent-start', 'agent-begin', 'agent-enter', 'subagent-start', 'subagent-begin', 'subagent-enter')
  $endTypes = @('agent-end', 'agent-finish', 'agent-stop', 'agent-exit', 'subagent-end', 'subagent-finish', 'subagent-stop', 'subagent-exit')
  $workflowStartTypes = @(
    'workflow-start', 'workflow-begin', 'workflow-enter',
    'tool-workflow-start', 'tool-workflow-begin', 'tool-workflow-enter',
    'tool-workflow-agent-start', 'tool-workflow-run-start'
  )
  $workflowEndTypes = @(
    'workflow-end', 'workflow-finish', 'workflow-stop', 'workflow-exit',
    'tool-workflow-end', 'tool-workflow-finish', 'tool-workflow-stop', 'tool-workflow-exit',
    'tool-workflow-agent-end', 'tool-workflow-run-end'
  )
  if ($startTypes -contains $type) { return [PSCustomObject]@{ classification = 'start'; scope = 'agent'; type = $type } }
  if ($endTypes -contains $type) { return [PSCustomObject]@{ classification = 'end'; scope = 'agent'; type = $type } }
  if ($workflowStartTypes -contains $type) { return [PSCustomObject]@{ classification = 'start'; scope = 'workflow'; type = $type } }
  if ($workflowEndTypes -contains $type) { return [PSCustomObject]@{ classification = 'end'; scope = 'workflow'; type = $type } }

  if ($type -in @('agent', 'subagent', 'workflow', 'tool-workflow')) {
    $scope = if ($type -match 'workflow') { 'workflow' } else { 'agent' }
    if ($phase -in @('start', 'begin', 'enter')) { return [PSCustomObject]@{ classification = 'start'; scope = $scope; type = "$type-$phase" } }
    if ($phase -in @('end', 'finish', 'stop', 'exit')) { return [PSCustomObject]@{ classification = 'end'; scope = $scope; type = "$type-$phase" } }
    return [PSCustomObject]@{ classification = 'ambiguous'; scope = $scope; type = $type }
  }
  if ($type -match '(agent|workflow)' -and $type -match '(start|begin|enter|end|finish|stop|exit)') {
    return [PSCustomObject]@{ classification = 'ambiguous'; scope = $null; type = $null }
  }
  return [PSCustomObject]@{ classification = 'ignored'; scope = $null; type = $null }
}

function New-DshTraceRecursionSafety {
  return [ordered]@{
    analysisMode = 'offline-postmortem'
    runtimeBlocking = $false
    profileWrites = $false
    sessionCreation = $false
    toolExecution = $false
    networkAccess = $false
    inputModified = $false
    failClosed = $true
  }
}

function New-DshTraceRecursionPrivacy {
  return [ordered]@{
    rawTraceReturned = $false
    agentIdsReturned = $false
    sessionIdsReturned = $false
    messagesReturned = $false
    toolArgumentsReturned = $false
    evidence = 'event category, sequence number, and observed nesting depth only'
  }
}

function New-DshTraceRecursionReport {
  param(
    [Parameter(Mandatory = $true)][ValidateSet('PASS', 'RECURSION_DETECTED', 'MANUAL_REVIEW', 'FAIL')][string]$Result,
    [AllowEmptyCollection()][object[]]$Findings = @(),
    [AllowEmptyCollection()][string[]]$Warnings = @(),
    [AllowEmptyCollection()][string[]]$Errors = @(),
    [AllowNull()]$InputSummary = $null
  )
  return [ordered]@{
    kind = 'dsh-trace-recursion'
    schemaVersion = $script:DshTraceRecursionSchemaVersion
    result = $Result
    input = $InputSummary
    findings = @($Findings)
    warnings = @($Warnings)
    errors = @($Errors)
    safety = New-DshTraceRecursionSafety
    privacy = New-DshTraceRecursionPrivacy
  }
}

function Invoke-DshTraceRecursion {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)]$InputObject,
    [ValidateRange(1, 32)][int]$MaxDepth = 4
  )
  $eventCount = 0
  $markerCount = 0
  $startCount = 0
  $endCount = 0
  $ignoredCount = 0
  $ambiguityCount = 0
  $maxObservedDepth = 0
  $findings = [System.Collections.Generic.List[object]]::new()
  $warnings = [System.Collections.Generic.List[string]]::new()
  $stack = [System.Collections.Generic.List[object]]::new()
  $activeFinding = $null
  try {
    if ($null -eq $InputObject -or -not (Test-DshTraceRecursionProperty -Object $InputObject -Name 'events')) { throw 'trace must contain an events array' }
    # Read the property directly so a one-item JSON array is not unrolled by
    # PowerShell's function output enumeration.
    if ($InputObject -is [System.Collections.IDictionary]) {
      $eventsValue = $InputObject['events']
    } else {
      $eventsValue = $InputObject.PSObject.Properties['events'].Value
    }
    if ($null -eq $eventsValue -or $eventsValue -isnot [System.Array]) { throw 'trace events must be a JSON array' }
    $events = @($eventsValue)
    $eventCount = $events.Count
    if ($eventCount -eq 0) { throw 'trace events array is empty' }
    if ($eventCount -gt $script:DshTraceRecursionMaxEvents) { throw 'trace exceeds the bounded event count' }

    $seenSequences = @{}
    $previousSequence = $null
    foreach ($entry in $events) {
      $view = Get-DshTraceRecursionEventView -Entry $entry
      $sequenceValue = Get-DshTraceRecursionProperty -Object $view.event -Name 'seq'
      if ($null -eq $sequenceValue) { $sequenceValue = Get-DshTraceRecursionProperty -Object $entry -Name 'seq' }
      $sequence = Get-DshTraceRecursionInteger -Value $sequenceValue
      if ($null -eq $sequence -or $sequence -lt 0) { throw 'trace event sequence is missing or invalid' }
      if ($seenSequences.ContainsKey([string]$sequence) -or ($null -ne $previousSequence -and $sequence -le $previousSequence)) {
        throw 'trace event sequences must be unique and increasing'
      }
      $seenSequences[[string]$sequence] = $true
      $previousSequence = $sequence

      $marker = Resolve-DshTraceRecursionMarker -Event $view.event -Data $view.data
      if ($marker.classification -eq 'ignored') {
        $ignoredCount++
        continue
      }
      if ($marker.classification -eq 'ambiguous') {
        $ambiguityCount++
        continue
      }
      $markerCount++
      if ($marker.classification -eq 'start') {
        $startCount++
        [void]$stack.Add([PSCustomObject]@{ scope = [string]$marker.scope; seq = [long]$sequence })
        $depth = $stack.Count
        if ($depth -gt $maxObservedDepth) { $maxObservedDepth = $depth }
        if ($depth -gt $MaxDepth) {
          if ($null -eq $activeFinding) {
            $pattern = @($stack | ForEach-Object { [string]$_.scope }) -join '>'
            $activeFinding = [ordered]@{
              kind = 'nested-agent-depth-exceeded'
              startSeq = [long]$sequence
              endSeq = $null
              threshold = $MaxDepth
              observedDepth = $depth
              scopePattern = $pattern
              closed = $false
            }
          } elseif ($depth -gt [int]$activeFinding.observedDepth) {
            $activeFinding.observedDepth = $depth
            $activeFinding.scopePattern = @($stack | ForEach-Object { [string]$_.scope }) -join '>'
          }
        }
        continue
      }

      $endCount++
      if ($stack.Count -eq 0) {
        $ambiguityCount++
        continue
      }
      $top = $stack[$stack.Count - 1]
      if ([string]$top.scope -cne [string]$marker.scope) {
        $ambiguityCount++
        continue
      }
      $stack.RemoveAt($stack.Count - 1)
      if ($null -ne $activeFinding -and $stack.Count -le $MaxDepth) {
        $activeFinding.endSeq = [long]$sequence
        $activeFinding.closed = $true
        [void]$findings.Add([PSCustomObject]$activeFinding)
        $activeFinding = $null
      }
    }

    if ($null -ne $activeFinding) { [void]$findings.Add([PSCustomObject]$activeFinding) }
    if ($stack.Count -gt 0) {
      $ambiguityCount += $stack.Count
      [void]$warnings.Add('trace ended with open agent or workflow frames')
    }
    if ($markerCount -eq 0) {
      $ambiguityCount++
      [void]$warnings.Add('trace contained no supported agent or workflow lifecycle markers')
    }
    if ($ambiguityCount -gt 0) { [void]$warnings.Add('unsupported, mismatched, or incomplete lifecycle metadata requires manual review') }

    $result = if ($findings.Count -gt 0) { 'RECURSION_DETECTED' } elseif ($ambiguityCount -gt 0) { 'MANUAL_REVIEW' } else { 'PASS' }
    $summary = [ordered]@{
      eventCount = $eventCount
      markerCount = $markerCount
      startCount = $startCount
      endCount = $endCount
      ignoredEventCount = $ignoredCount
      ambiguityCount = $ambiguityCount
      openFrameCount = $stack.Count
      maxObservedDepth = $maxObservedDepth
      maxAllowedDepth = $MaxDepth
    }
    return New-DshTraceRecursionReport -Result $result -Findings @($findings) -Warnings @($warnings) -InputSummary $summary
  } catch {
    $summary = [ordered]@{
      eventCount = $eventCount
      markerCount = $markerCount
      maxObservedDepth = $maxObservedDepth
      maxAllowedDepth = $MaxDepth
    }
    return New-DshTraceRecursionReport -Result 'FAIL' -Errors @([string]$_.Exception.Message) -InputSummary $summary
  }
}

function Read-DshTraceRecursionJson {
  param([Parameter(Mandatory = $true)][string]$Path)
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw 'trace input file does not exist' }
  $file = Get-Item -LiteralPath $Path -Force
  if ($file.Length -gt $script:DshTraceRecursionMaxInputBytes) { throw 'trace input exceeds the bounded file size' }
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
      $report = New-DshTraceRecursionReport -Result 'FAIL' -Errors @('InputPath is required') -InputSummary ([ordered]@{ eventCount = $null; maxAllowedDepth = $MaxDepth })
    } else {
      $report = Invoke-DshTraceRecursion -InputObject (Read-DshTraceRecursionJson -Path $InputPath) -MaxDepth $MaxDepth
    }
  } catch {
    $report = New-DshTraceRecursionReport -Result 'FAIL' -Errors @('trace recursion analysis could not be started') -InputSummary ([ordered]@{ eventCount = $null; maxAllowedDepth = $MaxDepth })
  }
  $report | ConvertTo-Json -Depth 32
  if ($report.result -eq 'FAIL') { exit 1 }
  exit 0
}
