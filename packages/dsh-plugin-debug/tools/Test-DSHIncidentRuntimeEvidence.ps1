[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $root 'DSH-PowerShell.ps1')
$incidentScript = Join-Path $root 'DSH-Incident.ps1'
$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('dsh-incident-evidence-' + [guid]::NewGuid().ToString('N'))
$profileRoot = Join-Path $fixtureRoot 'profiles\fixture'
$stateRoot = Join-Path $fixtureRoot 'state'

function Assert-IncidentEvidence {
  param([bool]$Condition, [string]$Message)
  if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
}

try {
  New-Item -ItemType Directory -Path $profileRoot, $stateRoot -Force | Out-Null
  [IO.File]::WriteAllText(
    (Join-Path $profileRoot 'package.json'),
    '{"name":"dsh-incident-evidence-fixture","dependencies":{},"dsh":{"profile":{"bundles":[]}}}',
    [Text.UTF8Encoding]::new($false)
  )
  [IO.File]::WriteAllText(
    (Join-Path $stateRoot 'startup-incident.json'),
    (@{
      schemaVersion = 1
      kind = 'dsh-startup-incident'
      incidentId = 'fixture-startup-incident'
      correlationKey = 'startup-fixture-startup-incident'
      status = 'recovered'
      reason = 'quarantine-and-controlled-restart'
      profile = 'fixture'
      port = 32992
      restartCount = 1
      quarantinedPluginIds = @('test-dsh-plugin')
      privacy = @{ rawLogsStored = $false; rawToolPayloadStored = $false; credentialsStored = $false; absolutePathsStored = $false }
    } | ConvertTo-Json -Depth 8),
    [Text.UTF8Encoding]::new($false)
  )
  $raw = & (Get-DshPowerShellPath) -NoLogo -NoProfile -ExecutionPolicy Bypass -File $incidentScript -DshHome $fixtureRoot -Profile fixture -Port 32992 -StateRoot $stateRoot -MaxMessages 10 2>&1
  $exitCode = $LASTEXITCODE
  $report = (($raw | Out-String).Trim() | ConvertFrom-Json)
  $diagnostics = $report.components.diagnostics
  Assert-IncidentEvidence ($exitCode -eq 0) 'incident capture exited non-zero'
  Assert-IncidentEvidence ([string]$diagnostics.runtimeEvidenceStatus -in @('usable', 'degraded', 'unavailable')) 'incident diagnostics omitted runtime evidence status'
  Assert-IncidentEvidence ([string]$diagnostics.resourcePressureStatus -in @('healthy', 'warning', 'critical', 'unavailable')) 'incident diagnostics omitted resource pressure status'
  Assert-IncidentEvidence ([int]$diagnostics.nodeProcessCount -ge 0) 'incident diagnostics returned invalid Node process count'
  Assert-IncidentEvidence ($report.components.startup.status -eq 'PASS' -and $report.components.startup.startupStatus -eq 'recovered') 'incident report did not consume the startup incident receipt'
  Assert-IncidentEvidence ($report.components.startup.quarantinedPluginIds -contains 'test-dsh-plugin') 'startup incident receipt lost quarantined plugin evidence'
  Assert-IncidentEvidence ($report.privacy.rawToolArgumentsStored -eq $false) 'incident report stored raw Tool arguments'
  Assert-IncidentEvidence ($report.collection.modelPromptSent -eq $false -and $report.collection.toolExecuted -eq $false) 'incident capture claimed model or Tool execution'

  [ordered]@{
    result = 'PASS'
    kind = 'dsh-incident-runtime-evidence-test'
    offline = $true
    networkAccessed = $false
    incidentResult = [string]$report.result
    diagnosticsStatus = [string]$diagnostics.status
    runtimeEvidenceStatus = [string]$diagnostics.runtimeEvidenceStatus
    resourcePressureStatus = [string]$diagnostics.resourcePressureStatus
    nodeProcessCount = [int]$diagnostics.nodeProcessCount
    startupIncidentStatus = [string]$report.components.startup.startupStatus
    startupIncidentQuarantine = @($report.components.startup.quarantinedPluginIds)
    privacyContract = $true
  } | ConvertTo-Json -Depth 12
  exit 0
} catch {
  [ordered]@{
    result = 'FAIL'
    kind = 'dsh-incident-runtime-evidence-test'
    offline = $true
    networkAccessed = $false
    error = $_.Exception.Message
  } | ConvertTo-Json -Depth 12
  exit 1
} finally {
  if (Test-Path -LiteralPath $fixtureRoot -PathType Container) {
    Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
  }
}
