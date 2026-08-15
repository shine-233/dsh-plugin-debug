[CmdletBinding()]
param(
  [string]$Profile = 'debug',
  [string]$DshHome = '',
  [int]$Port = 3081,
  [string]$HostName = '127.0.0.1',
  [string]$RuntimeRoot = '',
  [string]$Workspace = '',
  [string]$StateRoot = '',
  [string]$SessionId = '',
  [int]$MaxMessages = 100,
  [string]$ExpectedModel = '',
  [switch]$SkipApi,
  [string]$PointerPath = '',
  [string]$CorrelationKey = '',
  [string]$OutputPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$previousDshHome = $env:DSH_HOME

function Get-IncidentProperty {
  param([AllowNull()]$Object, [Parameter(Mandatory = $true)][string]$Name)
  if ($null -eq $Object) { return $null }
  if ($Object -is [System.Collections.IDictionary] -and $Object.Contains($Name)) { return $Object[$Name] }
  $property = $Object.PSObject.Properties[$Name]
  if ($null -eq $property) { return $null }
  return $property.Value
}

function Get-IncidentCount {
  param([AllowNull()]$Value)
  if ($null -eq $Value) { return 0 }
  return @($Value | Where-Object { $null -ne $_ }).Count
}

function Get-IncidentItems {
  param([AllowNull()]$Value)
  if ($null -eq $Value) { return @() }
  return @($Value | Where-Object { $null -ne $_ })
}

function Resolve-IncidentHome {
  param([string]$Value)
  if ([string]::IsNullOrWhiteSpace($Value)) {
    $Value = if ([string]::IsNullOrWhiteSpace($env:DSH_HOME)) { Join-Path $env:USERPROFILE '.dsh' } else { $env:DSH_HOME }
  }
  return [IO.Path]::GetFullPath($Value)
}

function Resolve-IncidentStateRoot {
  param([string]$Value)
  if ([string]::IsNullOrWhiteSpace($Value)) { $Value = Join-Path $root "state\$Profile-$Port" }
  return [IO.Path]::GetFullPath($Value)
}

function Get-IncidentHash {
  param([Parameter(Mandatory = $true)][string]$Text)
  $sha = [Security.Cryptography.SHA256]::Create()
  try { return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)))).Replace('-', '').ToLowerInvariant() }
  finally { $sha.Dispose() }
}

function Convert-IncidentArguments {
  param([hashtable]$Arguments)
  $tokens = [System.Collections.Generic.List[string]]::new()
  foreach ($entry in $Arguments.GetEnumerator()) {
    if ($null -eq $entry.Value) { continue }
    if ($entry.Value -is [bool] -or $entry.Value -is [System.Management.Automation.SwitchParameter]) {
      if ([bool]$entry.Value) { [void]$tokens.Add("-$($entry.Key)") }
      continue
    }
    if ([string]::IsNullOrWhiteSpace([string]$entry.Value)) { continue }
    [void]$tokens.Add("-$($entry.Key)")
    [void]$tokens.Add([string]$entry.Value)
  }
  return @($tokens)
}

function Invoke-IncidentJsonScript {
  param([Parameter(Mandatory = $true)][string]$Path, [hashtable]$Arguments = @{})
  $powerShell = Get-Command powershell.exe -ErrorAction SilentlyContinue
  if ($null -eq $powerShell) {
    return [PSCustomObject]@{ exitCode = 1; text = ''; value = $null; status = 'UNAVAILABLE'; error = 'Windows PowerShell executable not found' }
  }
  $tokens = Convert-IncidentArguments -Arguments $Arguments
  $previousErrorAction = $ErrorActionPreference
  try {
    $ErrorActionPreference = 'Continue'
    $output = & $powerShell.Source -NoLogo -NoProfile -ExecutionPolicy Bypass -File $Path @tokens 2>&1
    $exitCode = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $previousErrorAction
  }
  $text = ($output | Out-String).Trim()
  $value = $null
  try { $value = $text | ConvertFrom-Json } catch { }
  $reportedResult = Get-IncidentReportedResult -Value $value
  $status = if ($exitCode -ne 0) {
    if ($reportedResult -eq 'FAIL') { 'FAIL' } else { 'UNAVAILABLE' }
  } else {
    $reportedResult
  }
  return [PSCustomObject]@{
    exitCode = $exitCode
    text = $text
    value = $value
    status = $status
    reportedResult = $reportedResult
    error = if ($null -eq $value) { 'child did not return JSON' } elseif ($reportedResult -eq 'UNAVAILABLE') { 'child result was missing or inconclusive' } else { $null }
  }
}

function Get-IncidentReportedResult {
  param([AllowNull()]$Value)
  if ($null -eq $Value) { return 'UNAVAILABLE' }
  $reported = [string](Get-IncidentProperty -Object $Value -Name 'result')
  switch ($reported.ToUpperInvariant()) {
    'PASS' { return 'PASS' }
    'PARTIAL' { return 'PARTIAL' }
    'WARN' { return 'PARTIAL' }
    'FAIL' { return 'FAIL' }
    'UNAVAILABLE' { return 'UNAVAILABLE' }
    'INCONCLUSIVE' { return 'UNAVAILABLE' }
    default { return 'UNAVAILABLE' }
  }
}

function Get-IncidentComponentStatus {
  param([AllowNull()]$Child)
  if ($null -eq $Child) { return 'UNAVAILABLE' }
  $status = [string](Get-IncidentProperty -Object $Child -Name 'status')
  if ($status -in @('PASS', 'PARTIAL', 'UNAVAILABLE', 'FAIL', 'NOT_REQUESTED')) { return $status }
  return 'UNAVAILABLE'
}

function Get-IncidentPayload {
  param([AllowNull()]$Child)
  if ($null -eq $Child) { return $null }
  $nested = Get-IncidentProperty -Object $Child -Name 'value'
  if ($null -ne $nested) { return $nested }
  return $Child
}

function Get-IncidentManifestSummary {
  param([Parameter(Mandatory = $true)][string]$DshHomeRoot)
  $path = Join-Path $DshHomeRoot "profiles\$Profile\package.json"
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
    return [ordered]@{ present = $false; dependencyCount = 0; dependencyNames = @(); sha256 = $null }
  }
  try {
    $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8
    $manifest = $raw | ConvertFrom-Json
    $names = @($manifest.dependencies.PSObject.Properties | ForEach-Object { [string]$_.Name } | Sort-Object)
    return [ordered]@{
      present = $true
      dependencyCount = $names.Count
      dependencyNames = @($names | Select-Object -First 200)
      sha256 = Get-IncidentHash -Text $raw
    }
  } catch {
    return [ordered]@{ present = $true; dependencyCount = 0; dependencyNames = @(); sha256 = $null; parseError = 'manifest could not be parsed' }
  }
}

function Get-IncidentGuardSummary {
  param([Parameter(Mandatory = $true)][string]$StateRootPath)
  $statePath = Join-Path $StateRootPath 'guard-state.json'
  if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
    return [ordered]@{ statePresent = $false; quarantineCount = 0; failureCount = 0; quarantinedPluginIds = @() }
  }
  try {
    $state = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
    return [ordered]@{
      statePresent = $true
      quarantineCount = Get-IncidentCount -Value (Get-IncidentProperty -Object $state -Name 'quarantined')
      failureCount = Get-IncidentCount -Value (Get-IncidentProperty -Object $state -Name 'failures')
      quarantinedPluginIds = @(Get-IncidentItems -Value (Get-IncidentProperty -Object $state -Name 'quarantined') | ForEach-Object {
        $entryId = Get-IncidentProperty -Object $_ -Name 'entryId'
        if (-not [string]::IsNullOrWhiteSpace([string]$entryId)) { [string]$entryId } else { [string](Get-IncidentProperty -Object $_ -Name 'moduleName') }
      } | Select-Object -First 200)
      lastRunSource = [string]$state.lastRun.source
      lastRunChanged = $state.lastRun.changed -eq $true
    }
  } catch {
    return [ordered]@{ statePresent = $true; quarantineCount = 0; failureCount = 0; quarantinedPluginIds = @(); parseError = 'guard state could not be parsed' }
  }
}

function Get-IncidentDiagnosticsSummary {
  param([AllowNull()]$Child)
  $value = Get-IncidentPayload -Child $Child
  if ($null -eq $value) { return [ordered]@{ status = 'UNAVAILABLE'; reason = 'diagnostics did not return a report' } }
  $route = Get-IncidentProperty -Object $value -Name 'modelRoute'
  $inventory = Get-IncidentProperty -Object $value -Name 'pluginInventory'
  $observation = Get-IncidentProperty -Object $value -Name 'toolCallObservation'
  $permission = Get-IncidentProperty -Object $value -Name 'permission'
  $runtimeEvidence = Get-IncidentProperty -Object $value -Name 'runtimeEvidence'
  $resourcePressure = Get-IncidentProperty -Object $runtimeEvidence -Name 'resourcePressure'
  return [ordered]@{
    status = Get-IncidentComponentStatus -Child $Child
    schemaVersion = Get-IncidentProperty -Object $value -Name 'schemaVersion'
    provider = [string](Get-IncidentProperty -Object $route -Name 'provider')
    model = [string](Get-IncidentProperty -Object $route -Name 'model')
    pluginCount = Get-IncidentProperty -Object $inventory -Name 'count'
    failedPluginCount = Get-IncidentCount -Value (Get-IncidentProperty -Object $inventory -Name 'failed')
    toolCallStatus = [string](Get-IncidentProperty -Object $observation -Name 'status')
    sandbox = [string](Get-IncidentProperty -Object (Get-IncidentProperty -Object $permission -Name 'semantics') -Name 'sandbox')
    approval = [string](Get-IncidentProperty -Object (Get-IncidentProperty -Object $permission -Name 'semantics') -Name 'approval')
    runtimeEvidenceStatus = [string](Get-IncidentProperty -Object $runtimeEvidence -Name 'status')
    resourcePressureStatus = [string](Get-IncidentProperty -Object $resourcePressure -Name 'status')
    nodeProcessCount = Get-IncidentProperty -Object $resourcePressure -Name 'nodeProcessCount'
    nodeWorkingSetBytes = Get-IncidentProperty -Object $resourcePressure -Name 'nodeWorkingSetBytes'
  }
}

function Get-IncidentHealthSummary {
  param([AllowNull()]$Child)
  $value = Get-IncidentPayload -Child $Child
  if ($null -eq $value) { return [ordered]@{ status = 'UNAVAILABLE'; reason = 'plugin health did not return a report' } }
  $findings = @(Get-IncidentItems -Value (Get-IncidentProperty -Object $value -Name 'findings'))
  $runtime = Get-IncidentProperty -Object $value -Name 'runtime'
  $apiObserved = Get-IncidentProperty -Object $value -Name 'apiObserved'
  if ($null -eq $apiObserved) {
    $apiObserved = Get-IncidentProperty -Object $runtime -Name 'inventoryObserved'
  }
  return [ordered]@{
    status = Get-IncidentComponentStatus -Child $Child
    findingCount = $findings.Count
    errorCount = @($findings | Where-Object { [string](Get-IncidentProperty -Object $_ -Name 'severity') -eq 'error' }).Count
    warningCount = @($findings | Where-Object { [string](Get-IncidentProperty -Object $_ -Name 'severity') -eq 'warning' }).Count
    apiObserved = if ($null -eq $apiObserved) { $null } else { [bool]$apiObserved }
  }
}

function Get-IncidentSecuritySummary {
  param([AllowNull()]$Child)
  $value = Get-IncidentPayload -Child $Child
  if ($null -eq $value) { return [ordered]@{ status = 'UNAVAILABLE'; reason = 'security audit did not return a report' } }
  $findings = @(Get-IncidentItems -Value (Get-IncidentProperty -Object $value -Name 'findings'))
  return [ordered]@{
    status = Get-IncidentComponentStatus -Child $Child
    findingCount = $findings.Count
    errorCount = @($findings | Where-Object { [string](Get-IncidentProperty -Object $_ -Name 'severity') -eq 'error' }).Count
    warningCount = @($findings | Where-Object { [string](Get-IncidentProperty -Object $_ -Name 'severity') -eq 'warning' }).Count
    envContentRead = (Get-IncidentProperty -Object $value -Name 'envContentRead') -eq $true
  }
}

function Get-IncidentSessionSummary {
  param([AllowNull()]$Child)
  $value = Get-IncidentPayload -Child $Child
  if ($null -eq $value) { return [ordered]@{ status = 'UNAVAILABLE'; reason = 'session health did not return a report' } }
  $observations = @(Get-IncidentItems -Value (Get-IncidentProperty -Object $value -Name 'observations'))
  return [ordered]@{
    status = Get-IncidentComponentStatus -Child $Child
    filesScanned = Get-IncidentProperty -Object $value -Name 'filesScanned'
    tornTailCount = @($observations | Where-Object { [string](Get-IncidentProperty -Object $_ -Name 'status') -eq 'torn-tail' }).Count
    corruptFrameCount = @($observations | Where-Object { [string](Get-IncidentProperty -Object $_ -Name 'status') -eq 'corrupt-frame' }).Count
    emptyCount = @($observations | Where-Object { [string](Get-IncidentProperty -Object $_ -Name 'status') -eq 'empty' }).Count
    zstdDecoded = (Get-IncidentProperty -Object (Get-IncidentProperty -Object $value -Name 'boundaries') -Name 'zstdFramesDecoded') -eq $true
  }
}

function Get-IncidentContextSummary {
  param([AllowNull()]$Child)
  if ($null -eq $Child) { return [ordered]@{ status = 'NOT_REQUESTED'; reason = 'workspace was not supplied' } }
  $value = Get-IncidentPayload -Child $Child
  if ($null -eq $value) { return [ordered]@{ status = 'UNAVAILABLE'; reason = 'context doctor did not return a report' } }
  return [ordered]@{
    status = Get-IncidentComponentStatus -Child $Child
    totalFiles = Get-IncidentProperty -Object $value -Name 'totalFiles'
    totalBytes = Get-IncidentProperty -Object $value -Name 'totalBytes'
    approxTokens = Get-IncidentProperty -Object $value -Name 'approxTokens'
    duplicateContentCount = Get-IncidentCount -Value (Get-IncidentProperty -Object $value -Name 'duplicateContent')
    conflictCount = Get-IncidentCount -Value (Get-IncidentProperty -Object $value -Name 'conflicts')
  }
}

function Add-IncidentCorrelationFragment {
  param(
    [Parameter(Mandatory = $true)][AllowEmptyCollection()][System.Collections.Generic.List[object]]$Fragments,
    [Parameter(Mandatory = $true)][string]$Layer,
    [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Events,
    [AllowNull()][string]$CorrelationKey,
    [AllowNull()][string]$SessionId
  )
  $usable = @($Events | Where-Object { $null -ne $_ })
  if ($usable.Count -eq 0) { return }
  $fragment = [ordered]@{
    layer = $Layer
    events = @($usable)
  }
  if (-not [string]::IsNullOrWhiteSpace($CorrelationKey)) { $fragment.correlationKey = $CorrelationKey }
  if (-not [string]::IsNullOrWhiteSpace($SessionId)) { $fragment.sessionId = $SessionId }
  [void]$Fragments.Add($fragment)
}

function Get-IncidentCorrelationComponentStatus {
  param(
    [AllowNull()]$Report,
    [AllowNull()]$Contract
  )
  if ($null -eq $Report -or $null -eq $Contract -or (Get-IncidentProperty -Object $Contract -Name 'valid') -ne $true) {
    return 'FAIL'
  }
  switch ([string](Get-IncidentProperty -Object $Report -Name 'status')) {
    'CORRELATED' { return 'PASS' }
    'INCONCLUSIVE' { return 'PARTIAL' }
    'MANUAL_REVIEW' { return 'FAIL' }
    default { return 'FAIL' }
  }
}

try {
  if ($MaxMessages -lt 1 -or $MaxMessages -gt 500) { throw 'MaxMessages must be between 1 and 500' }
  $dshHomeRoot = Resolve-IncidentHome -Value $DshHome
  $stateRootPath = Resolve-IncidentStateRoot -Value $StateRoot
  $env:DSH_HOME = $dshHomeRoot
  if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path $stateRootPath ('incidents\incident-' + (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss-fff') + '.json')
  } else {
    $OutputPath = [IO.Path]::GetFullPath($OutputPath)
  }
  New-Item -ItemType Directory -Path (Split-Path -Parent $OutputPath) -Force | Out-Null

  $diagnosticsChild = Invoke-IncidentJsonScript -Path (Join-Path $root 'Get-DSH-Diagnostics.ps1') -Arguments @{
    Profile = $Profile; Port = $Port; RuntimeRoot = $RuntimeRoot; SessionId = $SessionId; MaxMessages = $MaxMessages; ExpectedModel = $ExpectedModel; SkipApi = $SkipApi
  }
  $healthChild = Invoke-IncidentJsonScript -Path (Join-Path $root 'Get-DSH-PluginHealth.ps1') -Arguments @{
    Profile = $Profile; DshHome = $dshHomeRoot; Port = $Port; RuntimeRoot = $RuntimeRoot; SkipApi = $true
  }
  $securityChild = Invoke-IncidentJsonScript -Path (Join-Path $root 'DSH-ProvenanceSuite.ps1') -Arguments @{
    Action = 'security-audit'; Profile = $Profile; DshHome = $dshHomeRoot; StateRoot = $stateRootPath
  }
  $sessionChild = Invoke-IncidentJsonScript -Path (Join-Path $root 'DSH-ProvenanceSuite.ps1') -Arguments @{
    Action = 'session-health'; Profile = $Profile; DshHome = $dshHomeRoot; StateRoot = $stateRootPath
  }
  $provenanceChild = Invoke-IncidentJsonScript -Path (Join-Path $root 'DSH-ProvenanceSuite.ps1') -Arguments @{
    Action = 'provenance'; Profile = $Profile; DshHome = $dshHomeRoot; StateRoot = $stateRootPath
  }
  $pointerChild = $null
  if (-not [string]::IsNullOrWhiteSpace($PointerPath)) {
    $pointerChild = Invoke-IncidentJsonScript -Path (Join-Path $root 'DSH-ProvenanceSuite.ps1') -Arguments @{
      Action = 'pointer-evidence'; Profile = $Profile; DshHome = $dshHomeRoot; StateRoot = $stateRootPath; InputPath = $PointerPath
    }
  }
  $contextChild = $null
  if (-not [string]::IsNullOrWhiteSpace($Workspace)) {
    $contextChild = Invoke-IncidentJsonScript -Path (Join-Path $root 'DSH-ProvenanceSuite.ps1') -Arguments @{
      Action = 'context-doctor'; Profile = $Profile; DshHome = $dshHomeRoot; StateRoot = $stateRootPath; Root = $Workspace
    }
  }
  $traceChild = $null
  if (-not [string]::IsNullOrWhiteSpace($SessionId)) {
    $traceChild = Invoke-IncidentJsonScript -Path (Join-Path $root 'DSH-TraceEval.ps1') -Arguments @{
      Action = 'live'; SessionId = $SessionId; HostName = $HostName; Port = $Port; MaxMessages = $MaxMessages
    }
  }
  $traceValue = Get-IncidentProperty -Object $traceChild -Name 'value'

  $pointerPayload = Get-IncidentPayload -Child $pointerChild
  $pointerObservation = Get-IncidentProperty -Object $pointerPayload -Name 'observation'
  $effectiveCorrelationKey = $CorrelationKey
  if ([string]::IsNullOrWhiteSpace($effectiveCorrelationKey)) {
    $effectiveCorrelationKey = [string](Get-IncidentProperty -Object $pointerObservation -Name 'pageObservationId')
  }
  $correlationFragments = [System.Collections.Generic.List[object]]::new()
  if ($null -ne $pointerObservation) {
    Add-IncidentCorrelationFragment -Fragments $correlationFragments -Layer 'pointer-provenance' -CorrelationKey $effectiveCorrelationKey -SessionId $SessionId -Events @([ordered]@{
      seq = 1
      pluginId = Get-IncidentProperty -Object $pointerObservation -Name 'plugin'
      module = Get-IncidentProperty -Object $pointerObservation -Name 'module'
      slot = Get-IncidentProperty -Object $pointerObservation -Name 'slot'
      confidence = Get-IncidentProperty -Object $pointerObservation -Name 'confidence'
      status = 'observed'
    })
  }
  $diagnosticsValue = Get-IncidentPayload -Child $diagnosticsChild
  $inventory = Get-IncidentProperty -Object $diagnosticsValue -Name 'pluginInventory'
  $pointerPluginId = [string](Get-IncidentProperty -Object $pointerObservation -Name 'plugin')
  $pointerModule = [string](Get-IncidentProperty -Object $pointerObservation -Name 'module')
  $inventoryRows = @(
    Get-IncidentItems -Value (Get-IncidentProperty -Object $inventory -Name 'failed')
    Get-IncidentItems -Value (Get-IncidentProperty -Object $inventory -Name 'shellRows')
  )
  if (-not [string]::IsNullOrWhiteSpace($pointerPluginId) -or -not [string]::IsNullOrWhiteSpace($pointerModule)) {
    $inventoryRows = @($inventoryRows | Where-Object {
      $entryId = [string](Get-IncidentProperty -Object $_ -Name 'entryId')
      $moduleName = [string](Get-IncidentProperty -Object $_ -Name 'moduleName')
      (-not [string]::IsNullOrWhiteSpace($pointerPluginId) -and $entryId -ceq $pointerPluginId) -or
        (-not [string]::IsNullOrWhiteSpace($pointerModule) -and $moduleName -ceq $pointerModule)
    })
  }
  if (([string]::IsNullOrWhiteSpace($pointerPluginId) -and [string]::IsNullOrWhiteSpace($pointerModule)) -and $inventoryRows.Count -gt 0) {
    Add-IncidentCorrelationFragment -Fragments $correlationFragments -Layer 'plugin-inventory' -CorrelationKey $effectiveCorrelationKey -SessionId $SessionId -Events @([ordered]@{
      seq = 10
      tool = 'plugin-inventory'
      status = if (@($inventoryRows | Where-Object { [string](Get-IncidentProperty -Object $_ -Name 'fiberPhase') -eq 'failed' }).Count -gt 0) { 'error' } else { 'observed' }
    })
  }
  $inventoryEvents = @($inventoryRows | ForEach-Object {
    $entryId = [string](Get-IncidentProperty -Object $_ -Name 'entryId')
    $moduleName = [string](Get-IncidentProperty -Object $_ -Name 'moduleName')
    [ordered]@{
      seq = 10
      pluginId = if (-not [string]::IsNullOrWhiteSpace($entryId)) { $entryId } else { $moduleName }
      module = $moduleName
      status = if ((Get-IncidentProperty -Object $_ -Name 'enabled') -eq $false) { 'disabled' } else { [string](Get-IncidentProperty -Object $_ -Name 'fiberPhase') }
    }
  })
  if (-not [string]::IsNullOrWhiteSpace($pointerPluginId) -or -not [string]::IsNullOrWhiteSpace($pointerModule)) {
    Add-IncidentCorrelationFragment -Fragments $correlationFragments -Layer 'plugin-inventory' -CorrelationKey $effectiveCorrelationKey -SessionId $SessionId -Events $inventoryEvents
  }
  $slotErrors = @(Get-IncidentItems -Value (Get-IncidentProperty -Object $diagnosticsValue -Name 'slotErrors') | ForEach-Object {
    [ordered]@{
      seq = 20
      pluginId = [string](Get-IncidentProperty -Object $_ -Name 'registrant')
      module = [string](Get-IncidentProperty -Object $_ -Name 'module')
      slot = [string](Get-IncidentProperty -Object $_ -Name 'slot')
      status = 'error'
    }
  })
  Add-IncidentCorrelationFragment -Fragments $correlationFragments -Layer 'slot-render' -CorrelationKey $effectiveCorrelationKey -SessionId $SessionId -Events $slotErrors
  $toolObservation = Get-IncidentProperty -Object $diagnosticsValue -Name 'toolCallObservation'
  if ($null -ne $toolObservation) {
    $toolStats = Get-IncidentProperty -Object $toolObservation -Name 'session'
    $toolStats = Get-IncidentProperty -Object $toolStats -Name 'toolCallStats'
    Add-IncidentCorrelationFragment -Fragments $correlationFragments -Layer 'tool-call' -CorrelationKey $effectiveCorrelationKey -SessionId $SessionId -Events @([ordered]@{
      seq = 30
      tool = 'tool-call'
      status = if ([int](Get-IncidentProperty -Object $toolStats -Name 'errorResultCount') -gt 0) { 'error' } else { 'observed' }
      turn = 1
    })
  }
  if ($null -ne $traceValue) {
    $traceProjection = Get-IncidentProperty -Object $traceValue -Name 'trace'
    $traceStats = Get-IncidentProperty -Object $traceProjection -Name 'toolCallStats'
    Add-IncidentCorrelationFragment -Fragments $correlationFragments -Layer 'session-turn' -CorrelationKey $effectiveCorrelationKey -SessionId $SessionId -Events @([ordered]@{
      seq = 40
      turn = 1
      status = if ([int](Get-IncidentProperty -Object $traceStats -Name 'turnErrorCount') -gt 0) { 'error' } else { 'observed' }
    })
  }

  $manifestSummary = Get-IncidentManifestSummary -DshHomeRoot $dshHomeRoot
  $guardSummary = Get-IncidentGuardSummary -StateRootPath $stateRootPath
  $quarantineEvents = @($guardSummary.quarantinedPluginIds | ForEach-Object {
    if ([string]::IsNullOrWhiteSpace([string]$_)) { return }
    [ordered]@{
      seq = 50
      pluginId = [string]$_
      status = 'quarantined'
    }
  })
  Add-IncidentCorrelationFragment -Fragments $correlationFragments -Layer 'quarantine' -CorrelationKey $effectiveCorrelationKey -SessionId $SessionId -Events $quarantineEvents
  Import-Module (Join-Path $root 'DSH-IncidentCorrelation.psm1') -Force
  $correlationReport = Invoke-DshIncidentCorrelation -InputObject @($correlationFragments.ToArray())
  $correlationContract = Test-DshIncidentCorrelationOutput -Report $correlationReport
  $components = [ordered]@{
    diagnostics = Get-IncidentDiagnosticsSummary -Child $diagnosticsChild
    pluginHealth = Get-IncidentHealthSummary -Child $healthChild
    security = Get-IncidentSecuritySummary -Child $securityChild
    sessionHealth = Get-IncidentSessionSummary -Child $sessionChild
    context = Get-IncidentContextSummary -Child $contextChild
    provenance = [ordered]@{
      status = Get-IncidentComponentStatus -Child $provenanceChild
      globalName = [string](Get-IncidentProperty -Object (Get-IncidentPayload -Child $provenanceChild) -Name 'globalName')
      clientArtifactExists = (Get-IncidentProperty -Object (Get-IncidentPayload -Child $provenanceChild) -Name 'clientArtifactExists') -eq $true
      integratedIntoCurrentProfile = (Get-IncidentProperty -Object (Get-IncidentPayload -Child $provenanceChild) -Name 'integratedIntoCurrentProfile') -eq $true
      profileIntegration = Get-IncidentProperty -Object (Get-IncidentPayload -Child $provenanceChild) -Name 'profileIntegration'
    }
    pointer = if ($null -eq $pointerChild) { [ordered]@{ status = 'NOT_REQUESTED'; pathProvided = $false } } else {
      $pointerPayload = Get-IncidentPayload -Child $pointerChild
      [ordered]@{
        status = Get-IncidentComponentStatus -Child $pointerChild
        pathProvided = $true
        sourceKind = [string](Get-IncidentProperty -Object $pointerPayload -Name 'sourceKind')
        evidenceObserved = (Get-IncidentProperty -Object $pointerPayload -Name 'evidenceObserved') -eq $true
        confidence = [string](Get-IncidentProperty -Object $pointerPayload -Name 'confidence')
        observation = Get-IncidentProperty -Object $pointerPayload -Name 'observation'
        causalAttribution = [string](Get-IncidentProperty -Object $pointerPayload -Name 'causalAttribution')
        manualReviewRequired = (Get-IncidentProperty -Object $pointerPayload -Name 'manualReviewRequired') -eq $true
      }
    }
    correlation = [ordered]@{
      status = Get-IncidentCorrelationComponentStatus -Report $correlationReport -Contract $correlationContract
      contractValid = (Get-IncidentProperty -Object $correlationContract -Name 'valid') -eq $true
      correlationStatus = [string](Get-IncidentProperty -Object $correlationReport -Name 'status')
      incidentId = Get-IncidentProperty -Object $correlationReport -Name 'incidentId'
      incidentCount = [int](Get-IncidentProperty -Object $correlationReport -Name 'incidentCount')
      issueCodes = @(Get-IncidentProperty -Object $correlationReport -Name 'issueCodes')
      requiredLayers = @(Get-IncidentProperty -Object $correlationReport -Name 'requiredLayers')
      privacy = Get-IncidentProperty -Object $correlationReport -Name 'privacy'
    }
    trace = if ($null -eq $traceValue) { [ordered]@{ status = 'NOT_REQUESTED'; sessionProvided = $false } } else {
      [ordered]@{
        status = Get-IncidentComponentStatus -Child $traceChild
        contractValid = (Get-IncidentProperty -Object (Get-IncidentProperty -Object $traceValue -Name 'contract') -Name 'valid') -eq $true
        trace = Get-IncidentProperty -Object $traceValue -Name 'trace'
      }
    }
  }
  $manifestSummary = Get-IncidentManifestSummary -DshHomeRoot $dshHomeRoot
  $guardSummary = Get-IncidentGuardSummary -StateRootPath $stateRootPath
  $componentStatuses = @($components.GetEnumerator() | ForEach-Object {
      [string](Get-IncidentProperty -Object $_.Value -Name 'status')
    } | Where-Object { $_ -ne 'NOT_REQUESTED' })
  $failedComponents = @($componentStatuses | Where-Object { $_ -eq 'FAIL' }).Count
  $unavailableComponents = @($componentStatuses | Where-Object { $_ -eq 'UNAVAILABLE' }).Count
  $partialComponents = @($componentStatuses | Where-Object { $_ -eq 'PARTIAL' }).Count
  $incidentResult = if ($failedComponents -gt 0) {
    'FAIL'
  } elseif ($componentStatuses.Count -eq 0 -or $unavailableComponents -eq $componentStatuses.Count) {
    'UNAVAILABLE'
  } elseif ($unavailableComponents -gt 0 -or $partialComponents -gt 0) {
    'PARTIAL'
  } else {
    'COMPLETE'
  }
  $report = [ordered]@{
    schemaVersion = 1
    kind = 'dsh-debug-incident'
    id = [guid]::NewGuid().ToString('N')
    generatedAt = (Get-Date).ToUniversalTime().ToString('o')
    result = $incidentResult
    readOnly = $false
    collection = [ordered]@{
      readOnlyCollection = $true
      writesLocalReport = $true
      networkPayloadSent = $false
      modelPromptSent = $false
      toolExecuted = $false
    }
    componentStatusCounts = [ordered]@{
      complete = @($componentStatuses | Where-Object { $_ -eq 'PASS' }).Count
      partial = $partialComponents
      unavailable = $unavailableComponents
      failed = $failedComponents
    }
    profile = $Profile
    host = $HostName
    port = $Port
    sessionProvided = -not [string]::IsNullOrWhiteSpace($SessionId)
    workspaceProvided = -not [string]::IsNullOrWhiteSpace($Workspace)
    pointerEvidenceProvided = -not [string]::IsNullOrWhiteSpace($PointerPath)
    profileManifest = $manifestSummary
    guard = $guardSummary
    correlation = $correlationReport
    components = $components
    componentHashes = [ordered]@{}
    outputPath = $OutputPath
    privacy = [ordered]@{
      rawToolArgumentsStored = $false
      toolResultBodiesStored = $false
      rawSessionContentStored = $false
      envContentsStored = $false
      credentialsStored = $false
      networkPayloadSent = $false
      note = 'Incident capture summarizes bounded diagnostics and writes only this local report. It never sends a model prompt or executes a Tool.'
    }
  }
  foreach ($name in @($components.Keys)) {
    $componentJson = $components[$name] | ConvertTo-Json -Depth 30 -Compress
    $report.componentHashes[$name] = Get-IncidentHash -Text $componentJson
  }
  $report | ConvertTo-Json -Depth 40 | Set-Content -LiteralPath $OutputPath -Encoding UTF8
  $report | ConvertTo-Json -Depth 40
  exit 0
} catch {
  [ordered]@{
    result = 'FAIL'
    kind = 'dsh-debug-incident'
    error = $_.Exception.Message
    readOnly = $false
    collection = [ordered]@{
      readOnlyCollection = $true
      writesLocalReport = $false
      networkPayloadSent = $false
      modelPromptSent = $false
      toolExecuted = $false
    }
  } | ConvertTo-Json -Depth 12
  exit 1
} finally {
  if ($null -eq $previousDshHome) { Remove-Item Env:DSH_HOME -ErrorAction SilentlyContinue } else { $env:DSH_HOME = $previousDshHome }
}
