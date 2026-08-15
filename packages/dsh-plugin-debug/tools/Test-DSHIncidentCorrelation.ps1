[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$toolRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $toolRoot 'DSH-IncidentCorrelation.psm1') -Force

function Get-TestIncidentProperty {
  param([AllowNull()]$Object, [Parameter(Mandatory = $true)][string]$Name)
  if ($null -eq $Object) { return $null }
  if ($Object -is [System.Collections.IDictionary] -and $Object.Contains($Name)) { return $Object[$Name] }
  $property = $Object.PSObject.Properties[$Name]
  if ($null -eq $property) { return $null }
  return $property.Value
}

function Assert-TestIncident {
  param([Parameter(Mandatory = $true)][bool]$Condition, [Parameter(Mandatory = $true)][string]$Message)
  if (-not $Condition) { throw $Message }
}

function Get-TestIncidentPropertyNames {
  param([AllowNull()]$Object)
  if ($null -eq $Object) { return @() }
  if ($Object -is [System.Collections.IDictionary]) { return @($Object.Keys | ForEach-Object { [string]$_ }) }
  return @($Object.PSObject.Properties | ForEach-Object { [string]$_.Name })
}

function New-TestIncidentLayerFragment {
  param(
    [Parameter(Mandatory = $true)][string]$Layer,
    [Parameter(Mandatory = $true)][int]$Seq,
    [Parameter(Mandatory = $true)][string]$PluginId,
    [string]$Module = 'fixture.module',
    [string]$Slot = 'fixture.slot',
    [string]$Status = 'observed',
    [string]$CallId = '',
    [string]$CheckpointId = '',
    [string]$RestartId = ''
  )
  $event = [ordered]@{
    seq = $Seq
    pluginId = $PluginId
    module = $Module
    slot = $Slot
    status = $Status
    turn = 7
  }
  if (-not [string]::IsNullOrWhiteSpace($CallId)) { $event.callId = $CallId }
  $fragment = [ordered]@{
    layer = $Layer
    sessionId = 'fixture-session-7'
    turn = 7
    events = @($event)
  }
  if (-not [string]::IsNullOrWhiteSpace($CheckpointId)) { $fragment.checkpointId = $CheckpointId }
  if (-not [string]::IsNullOrWhiteSpace($RestartId)) { $fragment.restartId = $RestartId }
  return $fragment
}

function New-TestFullIncidentFragments {
  return @(
    (New-TestIncidentLayerFragment -Layer 'pointer-provenance' -Seq 100 -PluginId 'fixture.plugin' -Module 'fixture.overlay' -Slot 'main' -Status 'observed'),
    (New-TestIncidentLayerFragment -Layer 'plugin-inventory' -Seq 101 -PluginId 'fixture.plugin' -Module 'fixture.overlay' -Slot 'main' -Status 'failure'),
    (New-TestIncidentLayerFragment -Layer 'slot-render' -Seq 102 -PluginId 'fixture.plugin' -Module 'fixture.overlay' -Slot 'main' -Status 'error'),
    (New-TestIncidentLayerFragment -Layer 'tool-call' -Seq 103 -PluginId 'fixture.plugin' -Module 'fixture.overlay' -Slot 'main' -Status 'error' -CallId 'fixture-call-7'),
    (New-TestIncidentLayerFragment -Layer 'session-turn' -Seq 104 -PluginId 'fixture.plugin' -Module 'fixture.overlay' -Slot 'main' -Status 'error'),
    (New-TestIncidentLayerFragment -Layer 'quarantine' -Seq 105 -PluginId 'fixture.plugin' -Module 'fixture.overlay' -Slot 'main' -Status 'quarantined'),
    (New-TestIncidentLayerFragment -Layer 'restart' -Seq 106 -PluginId 'fixture.plugin' -Module 'fixture.overlay' -Slot 'main' -Status 'restarted' -RestartId 'fixture-restart-7'),
    (New-TestIncidentLayerFragment -Layer 'web-readiness' -Seq 107 -PluginId 'fixture.plugin' -Module 'fixture.overlay' -Slot 'main' -Status 'ready'),
    (New-TestIncidentLayerFragment -Layer 'known-good' -Seq 108 -PluginId 'fixture.plugin' -Module 'fixture.overlay' -Slot 'main' -Status 'healthy' -CheckpointId 'fixture-checkpoint-7')
  )
}

function Test-IncidentEvidenceFieldAllowlist {
  param([Parameter(Mandatory = $true)]$Report)
  $allowed = @('seq', 'callId', 'pluginId', 'module', 'slot', 'turn', 'tool', 'layer', 'status', 'confidence', 'incidentId')
  foreach ($incident in @($Report.incidents)) {
    foreach ($evidence in @($incident.evidence)) {
      foreach ($name in @(Get-TestIncidentPropertyNames -Object $evidence)) {
        if ($name -notin $allowed) { return $false }
      }
    }
  }
  return $true
}

try {
  $fullFragments = @(New-TestFullIncidentFragments)
  $jsonFragments = @($fullFragments | ForEach-Object { $_ | ConvertTo-Json -Depth 12 -Compress })
  $fullReport = ConvertTo-DshIncidentCorrelation -InputObject $jsonFragments
  $fullContract = Test-DshIncidentCorrelationOutput -Report $fullReport
  Assert-TestIncident ($fullContract.valid -eq $true) 'full correlation report failed output contract'
  Assert-TestIncident ($fullReport.status -eq 'CORRELATED') "full fixture status was $($fullReport.status)"
  Assert-TestIncident ([int]$fullReport.incidentCount -eq 1) 'full fixture did not produce exactly one incident'
  Assert-TestIncident ($fullReport.incidentId -ceq $fullReport.incidents[0].incidentId) 'top-level incidentId did not match the single incident'
  Assert-TestIncident ([int]$fullReport.incidents[0].evidenceCount -eq 9) 'full fixture did not retain all nine layer records'
  Assert-TestIncident (@($fullReport.incidents[0].observedLayers).Count -eq 9) 'full fixture did not observe all nine layers'
  Assert-TestIncident (@($fullReport.incidents[0].missingLayers).Count -eq 0) 'full fixture reported missing required layers'
  Assert-TestIncident (Test-IncidentEvidenceFieldAllowlist -Report $fullReport) 'evidence projection contains an unsupported field'

  $reversedReport = ConvertTo-DshIncidentCorrelation -InputObject @($jsonFragments | Sort-Object -Descending)
  Assert-TestIncident ($reversedReport.incidents[0].incidentId -ceq $fullReport.incidents[0].incidentId) 'incidentId changed when fragment order changed'
  Assert-TestIncident ($reversedReport.status -ceq 'CORRELATED') 'reordered full fixture changed status'

  $missingReport = ConvertTo-DshIncidentCorrelation -InputObject @(
    ([ordered]@{ layer = 'pointer-provenance'; sessionId = 'missing-session'; turn = 1; events = @([ordered]@{ seq = 1; pluginId = 'fixture.plugin'; module = 'fixture.overlay'; slot = 'main'; status = 'observed'; turn = 1 }) } | ConvertTo-Json -Depth 10 -Compress),
    ([ordered]@{ layer = 'plugin-inventory'; sessionId = 'missing-session'; turn = 1; events = @([ordered]@{ seq = 2; pluginId = 'fixture.plugin'; module = 'fixture.overlay'; slot = 'main'; status = 'failure'; turn = 1 }) } | ConvertTo-Json -Depth 10 -Compress)
  )
  Assert-TestIncident ($missingReport.status -eq 'INCONCLUSIVE') "missing evidence status was $($missingReport.status)"
  Assert-TestIncident (@($missingReport.incidents[0].missingLayers).Count -gt 0) 'missing evidence did not report missing layers'
  Assert-TestIncident ($missingReport.incidents[0].incidentId -match '^dsh-inc-[0-9a-f]{32}$') 'missing evidence did not get a stable bounded id'

  $conflictReport = ConvertTo-DshIncidentCorrelation -InputObject @(
    ([ordered]@{ layer = 'pointer-provenance'; sessionId = 'conflict-session'; turn = 2; events = @([ordered]@{ seq = 10; pluginId = 'plugin-a'; module = 'fixture.overlay'; slot = 'main'; status = 'observed'; turn = 2 }) } | ConvertTo-Json -Depth 10 -Compress),
    ([ordered]@{ layer = 'plugin-inventory'; sessionId = 'conflict-session'; turn = 2; events = @([ordered]@{ seq = 11; pluginId = 'plugin-b'; module = 'fixture.overlay'; slot = 'main'; status = 'failure'; turn = 2 }) } | ConvertTo-Json -Depth 10 -Compress)
  )
  Assert-TestIncident ($conflictReport.status -eq 'MANUAL_REVIEW') "conflict status was $($conflictReport.status)"
  Assert-TestIncident ('PLUGIN_ID_CONFLICT' -in @($conflictReport.issueCodes)) 'plugin conflict was not surfaced'
  Assert-TestIncident ($conflictReport.incidents[0].status -eq 'MANUAL_REVIEW') 'conflict incident was not marked for manual review'

  $privateFixture = [ordered]@{
    layer = 'tool-call'
    sessionId = 'private-session'
    turn = 3
    cookie = 'PRIVATE_COOKIE'
    authorization = 'PRIVATE_AUTHORIZATION'
    cwd = 'PRIVATE_CWD'
    events = @(
      [ordered]@{
        event = [ordered]@{
          seq = 20
          type = 'tool/call'
          data = [ordered]@{
            callId = 'private-call'
            name = 'shell'
            arguments = [ordered]@{ command = 'PRIVATE_COMMAND'; token = 'PRIVATE_TOKEN' }
          }
        }
      }
    )
  }
  $privateReport = ConvertTo-DshIncidentCorrelation -InputObject ($privateFixture | ConvertTo-Json -Depth 15 -Compress)
  $privateJson = $privateReport | ConvertTo-Json -Depth 20 -Compress
  foreach ($privateValue in @('PRIVATE_COOKIE', 'PRIVATE_AUTHORIZATION', 'PRIVATE_CWD', 'PRIVATE_COMMAND', 'PRIVATE_TOKEN')) {
    Assert-TestIncident ($privateJson -notmatch [regex]::Escape($privateValue)) "private fixture leaked $privateValue"
  }
  Assert-TestIncident ($privateReport.status -eq 'MANUAL_REVIEW') 'sensitive fixture did not require manual review'
  Assert-TestIncident ('SENSITIVE_FIELD_OBSERVED' -in @($privateReport.issueCodes)) 'sensitive fixture did not report its bounded issue code'
  Assert-TestIncident ((Test-DshIncidentCorrelationOutput -Report $privateReport).valid -eq $true) 'private report failed output contract'

  $noInputReport = ConvertTo-DshIncidentCorrelation
  Assert-TestIncident ($noInputReport.status -eq 'INCONCLUSIVE') 'empty input was not inconclusive'
  Assert-TestIncident ([int]$noInputReport.incidentCount -eq 0) 'empty input fabricated an incident'

  [ordered]@{
    result = 'PASS'
    kind = 'dsh-incident-correlation-test'
    offline = $true
    networkAccessed = $false
    externalRuntimeRead = $false
    tests = [ordered]@{
      fullChain = $fullReport.status
      stableIncidentId = $fullReport.incidents[0].incidentId
      evidenceCount = [int]$fullReport.incidents[0].evidenceCount
      missingEvidence = $missingReport.status
      conflictingEvidence = $conflictReport.status
      sensitiveEvidence = $privateReport.status
      emptyInput = $noInputReport.status
      outputContract = $fullContract.valid
    }
  } | ConvertTo-Json -Depth 15
  exit 0
} catch {
  [ordered]@{
    result = 'FAIL'
    kind = 'dsh-incident-correlation-test'
    offline = $true
    networkAccessed = $false
    externalRuntimeRead = $false
    error = $_.Exception.Message
    stack = $_.ScriptStackTrace
  } | ConvertTo-Json -Depth 15
  exit 1
}
