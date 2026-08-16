[CmdletBinding()]
param(
  [string]$Profile = 'debug',
  [int]$Port = 3081,
  [string]$BaseUrl = '',
  [string]$StateRoot = '',
  [string]$DshHome = '',
  [string]$RuntimeRoot = '',
  [string]$SessionId = '',
  [int]$MaxMessages = 100,
  [string]$ExpectedModel = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$LauncherRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$guardModulePath = Join-Path $LauncherRoot 'DSH-Guard.psm1'
Import-Module $guardModulePath -Force
Import-Module (Join-Path $LauncherRoot 'DSH-ResourcePressure.psm1') -Force
Import-Module (Join-Path $LauncherRoot 'DSH-State.psm1') -Force

function Sanitize-Text {
  param([AllowNull()][string]$Value)
  if ($null -eq $Value) { return $null }
  $result = $Value -replace '(?i)[A-Z]:\\[^\s;,)]+', '<path>'
  $result = $result -replace '(?i)https?://[^\s]+', '<url>'
  if ($result.Length -gt 600) { $result = $result.Substring(0, 600) }
  return $result
}

function Read-DefaultPreset {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
  $text = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
  $match = [regex]::Match($text, '(?m)^\s*defaultPreset:\s*([A-Za-z0-9._-]+)\s*$')
  if ($match.Success) { return $match.Groups[1].Value }
  return $null
}

function Read-RowState {
  param(
    [Parameter(Mandatory = $true)][string]$Text,
    [Parameter(Mandatory = $true)][string]$RowId,
    [string]$Source = 'patch'
  )
  $escaped = [regex]::Escape($RowId)
  $matches = [regex]::Matches($Text, "(?ms)^\s*- id:\s+$escaped\s*\r?$.*?(?=^\s*- id:|\z)")
  if ($matches.Count -eq 0) {
    return [PSCustomObject]@{ id = $RowId; present = $false; declarations = @(); effectiveOnWindows = $null; source = $Source }
  }
  $declarations = @()
  foreach ($match in $matches) {
    $block = $match.Value
    $disabledMatch = [regex]::Match($block, '(?m)^\s+disabled:\s*(.+?)\s*$')
    $rawDisabled = if ($disabledMatch.Success) { $disabledMatch.Groups[1].Value.Trim() } else { $null }
    $effective = $null
    if ($rawDisabled -eq 'true') { $effective = $true }
    elseif ($rawDisabled -eq 'false') { $effective = $false }
    elseif ($rawDisabled -match 'process\.platform\s*===\s*[''\"]win32[''\"]') { $effective = $true }
    elseif ($rawDisabled -match 'process\.platform\s*!==\s*[''\"]win32[''\"]') { $effective = $false }
    $declarations += [PSCustomObject]@{
      source = $Source
      disabled = $rawDisabled
      effectiveOnWindows = $effective
    }
  }
  return [PSCustomObject]@{
    id = $RowId
    present = $true
    declarations = @($declarations)
    effectiveOnWindows = @($declarations | Where-Object { $null -ne $_.effectiveOnWindows } | Select-Object -Last 1 | ForEach-Object { $_.effectiveOnWindows })
    source = $Source
  }
}

function Merge-RowStates {
  param(
    [Parameter(Mandatory = $true)][string]$RowId,
    [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Sources
  )
  $states = @()
  foreach ($source in @($Sources)) {
    $state = Read-RowState -Text $source.text -RowId $RowId -Source $source.source
    if ($state.present) { $states += $state }
  }
  return [PSCustomObject]@{
    id = $RowId
    present = $states.Count -gt 0
    declarations = @($states | ForEach-Object { $_.declarations })
    effectiveOnWindows = @($states | Where-Object { $null -ne $_.effectiveOnWindows } | Select-Object -Last 1 | ForEach-Object { $_.effectiveOnWindows })
    source = 'bundle cordis.patch.yml declarations'
  }
}

function Get-DiagnosticsRuntimeRoots {
  param([string]$ExplicitRuntimeRoot)
  $candidates = [System.Collections.Generic.List[string]]::new()
  if (-not [string]::IsNullOrWhiteSpace($ExplicitRuntimeRoot)) {
    $candidates.Add($ExplicitRuntimeRoot)
  }
  $packageRoot = Split-Path -Parent $LauncherRoot
  $projectsRoot = Split-Path -Parent $packageRoot
  foreach ($candidate in @(
      (Join-Path $LauncherRoot 'runtime'),
      (Join-Path $packageRoot 'runtime'),
      (Join-Path $packageRoot 'runtime')
    )) {
    $candidates.Add($candidate)
  }
  $seen = @{}
  $resolved = [System.Collections.Generic.List[string]]::new()
  foreach ($candidate in $candidates) {
    if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
    try { $fullPath = [IO.Path]::GetFullPath($candidate) } catch { continue }
    $key = $fullPath.TrimEnd('\').ToLowerInvariant()
    if ($seen.ContainsKey($key)) { continue }
    $seen[$key] = $true
    $resolved.Add($fullPath)
  }
  return @($resolved)
}

function Read-BundlePatchSources {
  param(
    [Parameter(Mandatory = $true)]$Manifest,
    [Parameter(Mandatory = $true)][string]$DshHome,
    [Parameter(Mandatory = $true)][string]$Profile,
    [AllowEmptyCollection()][string[]]$RuntimeRoots = @()
  )
  $sources = @()
  $profileModules = Join-Path $DshHome "profiles\$Profile\node_modules"
  foreach ($bundle in @($Manifest.dsh.profile.bundles)) {
    if ([string]::IsNullOrWhiteSpace([string]$bundle)) { continue }
    $profilePatch = Join-Path (Join-Path $profileModules ([string]$bundle -replace '/', '\')) 'cordis.patch.yml'
    $patchPath = if (Test-Path -LiteralPath $profilePatch -PathType Leaf) { $profilePatch } else { $null }
    if ($null -eq $patchPath) {
      foreach ($runtimeRoot in @($RuntimeRoots)) {
        if ([string]::IsNullOrWhiteSpace($runtimeRoot)) { continue }
        $runtimePatch = Join-Path (Join-Path $runtimeRoot "node_modules\$([string]$bundle -replace '/', '\')") 'cordis.patch.yml'
        if (Test-Path -LiteralPath $runtimePatch -PathType Leaf) {
          $patchPath = $runtimePatch
          break
        }
      }
    }
    if ($null -ne $patchPath) {
      $sources += [PSCustomObject]@{
        source = ([string]$bundle + '/cordis.patch.yml')
        text = Get-Content -LiteralPath $patchPath -Raw -Encoding UTF8
      }
    }
  }
  return @($sources)
}

function Get-DependencyShape {
  param([Parameter(Mandatory = $true)]$Manifest)
  $result = @()
  foreach ($name in Get-DshManifestDependencyNames -Manifest $Manifest) {
    $spec = Get-DshManifestPackageSpec -Manifest $Manifest -Name $name
    $kind = if ([string]$spec -match '^(?i:link:)') { 'link' } elseif ([string]$spec -match '^(?i:file:)') { 'file' } else { 'registry' }
    $result += [PSCustomObject]@{ name = $name; specKind = $kind }
  }
  return @($result)
}

function Get-SafeProcessRecord {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
  try {
    $record = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    return [PSCustomObject]@{
      pid = [int]$record.pid
      startedAt = [string]$record.startedAt
      url = [string]$record.url
      profile = [string]$record.profile
      host = [string]$record.host
      port = [int]$record.port
      runtime = [string]$record.runtime
      crashGuard = $record.crashGuard -eq $true
      processExists = $null -ne (Get-Process -Id ([int]$record.pid) -ErrorAction SilentlyContinue)
      workspacePresent = -not [string]::IsNullOrWhiteSpace([string]$record.workspace)
    }
  } catch {
    return [PSCustomObject]@{ error = (Sanitize-Text $_.Exception.Message) }
  }
}

function Get-SafeCallId {
  param([AllowNull()][string]$Value)
  if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
  if ($Value.Length -le 80) { return $Value }
  return $Value.Substring(0, 77) + '...'
}

function Get-ToolArgumentObservation {
  param([AllowNull()]$Arguments)
  if ($null -eq $Arguments) {
    return [PSCustomObject]@{ observed = $false; keys = @(); sandboxPermission = $null }
  }
  $keys = @($Arguments.PSObject.Properties | ForEach-Object { [string]$_.Name } | Sort-Object -Unique)
  $permissionProperty = $Arguments.PSObject.Properties['sandbox_permissions']
  if ($null -eq $permissionProperty) { $permissionProperty = $Arguments.PSObject.Properties['sandboxPermissions'] }
  $permission = $null
  if ($null -ne $permissionProperty) {
    $raw = [string]$permissionProperty.Value
    $permission = switch ($raw) {
      'read-only' { 'read-only' }
      'workspace-write' { 'workspace-write' }
      'danger-full-access' { 'danger-full-access' }
      'ask' { 'ask' }
      default { if ([string]::IsNullOrWhiteSpace($raw)) { 'empty' } else { 'unrecognized' } }
    }
  }
  return [PSCustomObject]@{ observed = $true; keys = $keys; sandboxPermission = $permission }
}

function Get-DshSessionObservation {
  param(
    [Parameter(Mandatory = $true)][string]$BaseUrl,
    [Parameter(Mandatory = $true)][string]$Id,
    [int]$Limit = 100
  )
  $history = Invoke-DshGuardApi -BaseUrl $BaseUrl -Method 'session.history' -Arguments @{
    sessionId = $Id
    maxMessages = $Limit
  } -TimeoutSec 8
  $events = @($history.events | ForEach-Object { $_.event })
  $counts = @($events | Group-Object type | Sort-Object Name | ForEach-Object {
    [PSCustomObject]@{ type = [string]$_.Name; count = [int]$_.Count }
  })
  $calls = @{}
  $results = @{}
  $toolCalls = @()
  $toolResults = @()
  $dispatchErrors = @()
  $turnErrors = @()
  $modelContexts = @()
  $permissionObservations = @()

  foreach ($event in $events) {
    $type = [string]$event.type
    if ($type -eq 'request/context') {
      $modelContexts += [PSCustomObject]@{
        seq = [int]$event.seq
        provider = [string]$event.data.provider
        model = [string]$event.data.model
      }
      continue
    }
    if ($type -eq 'tool/call') {
      $callId = [string]$event.data.callId
      if (-not [string]::IsNullOrWhiteSpace($callId)) { $calls[$callId] = $true }
      $argumentProperty = $event.data.PSObject.Properties['arguments']
      $argumentObservation = if ($null -eq $argumentProperty) { Get-ToolArgumentObservation -Arguments $null } else { Get-ToolArgumentObservation -Arguments $argumentProperty.Value }
      if ($null -ne $argumentObservation.sandboxPermission) {
        $permissionObservations += [PSCustomObject]@{
          seq = [int]$event.seq
          name = [string]$event.data.name
          permission = [string]$argumentObservation.sandboxPermission
        }
      }
      $toolCalls += [PSCustomObject]@{
        seq = [int]$event.seq
        turn = [int]$event.data.turn
        step = [int]$event.data.step
        name = [string]$event.data.name
        callId = Get-SafeCallId -Value $callId
        argumentsObserved = $argumentObservation.observed
        argumentKeysObserved = $argumentObservation.keys
        sandboxPermissionObserved = $argumentObservation.sandboxPermission
      }
      continue
    }
    if ($type -eq 'tool/result') {
      $message = $event.data.message
      $sourceCallId = [string]$message.source.callId
      if (-not [string]::IsNullOrWhiteSpace($sourceCallId)) { $results[$sourceCallId] = $true }
      $resultBlocks = @($message.content | Where-Object { $_.type -eq 'tool-result' })
      $isError = @($resultBlocks | Where-Object { $_.isError -eq $true }).Count -gt 0
      $toolResults += [PSCustomObject]@{
        seq = [int]$event.seq
        turn = [int]$event.data.turn
        step = [int]$event.data.step
        callId = Get-SafeCallId -Value $sourceCallId
        isError = $isError
        errorObjectObserved = $null -ne $event.data.error
      }
      continue
    }
    if ($type -eq 'tool/code-dispatch' -and $event.data.isError -eq $true) {
      $dispatchErrors += [PSCustomObject]@{
        seq = [int]$event.seq
        name = [string]$event.data.name
        error = $true
      }
      continue
    }
    if ($type -eq 'turn/end' -and [string]$event.data.reason.kind -eq 'error') {
      $turnErrors += [PSCustomObject]@{
        seq = [int]$event.seq
        turn = [int]$event.data.turn
        reason = 'error'
      }
    }
  }

  $pending = @($calls.Keys | Where-Object { -not $results.ContainsKey($_) } | ForEach-Object {
    [PSCustomObject]@{ callId = Get-SafeCallId -Value ([string]$_) }
  })
  $shellPermissionObservations = @($permissionObservations | Where-Object { $_.name -match '(?i)(bash|pwsh|shell|terminal)' })
  $permissionCounts = @($permissionObservations | Group-Object permission | Sort-Object Name | ForEach-Object {
    [PSCustomObject]@{ permission = [string]$_.Name; count = [int]$_.Count }
  })
  $callCount = $toolCalls.Count
  $resultCount = $toolResults.Count
  $errorResultCount = @($toolResults | Where-Object { $_.isError }).Count
  return [ordered]@{
    status = 'observed'
    sessionId = $Id
    eventCount = $events.Count
    hasMore = $history.hasMore -eq $true
    eventCounts = $counts
    modelContexts = $modelContexts
    toolCalls = $toolCalls
    toolResults = $toolResults
    toolCallStats = [ordered]@{
      callCount = $callCount
      resultCount = $resultCount
      errorResultCount = $errorResultCount
      dispatchErrorCount = $dispatchErrors.Count
      turnErrorCount = $turnErrors.Count
      pendingCount = $pending.Count
      completionRatio = if ($callCount -eq 0) { $null } else { [Math]::Round($resultCount / $callCount, 3) }
    }
    permissionObservation = [ordered]@{
      observed = $permissionObservations.Count -gt 0
      counts = $permissionCounts
      shellCalls = $shellPermissionObservations
      allObservedShellCallsRequestedDangerFullAccess = if ($shellPermissionObservations.Count -eq 0) { $null } else { @($shellPermissionObservations | Where-Object { $_.permission -ne 'danger-full-access' }).Count -eq 0 }
      note = 'Only the sandbox permission enum and argument key names are retained. This does not prove that a request was approved, that the tool ran, or why the model selected the permission.'
    }
    codeDispatchErrors = $dispatchErrors
    turnErrors = $turnErrors
    pendingToolCalls = $pending
    interpretation = [ordered]@{
      toolCall = 'tool/call proves a call event was recorded; it does not by itself prove execution failed.'
      toolResult = 'tool/result with isError=true is a Tool result error; errorObjectObserved is only an error-envelope observation.'
      pending = 'A call with no matching result is incomplete in this page; it may be in a later page or interrupted.'
      turnError = 'turn/end reason.kind=error marks a whole Turn failure, not necessarily a plugin failure.'
    }
  }
}

if (-not [string]::IsNullOrWhiteSpace($DshHome)) {
  $dshHome = [IO.Path]::GetFullPath($DshHome)
} elseif ([string]::IsNullOrWhiteSpace($env:DSH_HOME)) {
  $dshHome = Join-Path $env:USERPROFILE '.dsh'
} else {
  $dshHome = $env:DSH_HOME
}
if ([string]::IsNullOrWhiteSpace($BaseUrl)) { $BaseUrl = "http://127.0.0.1:$Port/" }
if ([string]::IsNullOrWhiteSpace($DshHome)) { $DshHome = Resolve-DshDebugHome }
if ([string]::IsNullOrWhiteSpace($StateRoot)) { $StateRoot = Resolve-DshDebugStateRoot -DshHome $DshHome -Profile $Profile -Port $Port }
$runtimeRootsChecked = @(Get-DiagnosticsRuntimeRoots -ExplicitRuntimeRoot $RuntimeRoot)
$resourcePressure = Get-DshResourcePressure

$manifestPath = Join-Path $dshHome "profiles\$Profile\package.json"
$cordisPath = Join-Path $dshHome "profiles\$Profile\cordis.yml"
$settingsPath = Join-Path $dshHome 'settings.yaml'
$manifest = $null
$patchSources = @()
$inventory = @()
$hostValue = $null
$apiErrors = @()

try { $manifest = Read-DshProfileManifest -Path $manifestPath } catch { $apiErrors += [PSCustomObject]@{ stage = 'manifest'; message = (Sanitize-Text $_.Exception.Message) } }

if ($null -ne $manifest) {
  $patchSources = @(Read-BundlePatchSources -Manifest $manifest -DshHome $dshHome -Profile $Profile -RuntimeRoots $runtimeRootsChecked)
}
if ($patchSources.Count -eq 0 -and (Test-Path -LiteralPath $cordisPath -PathType Leaf)) {
  $patchSources = @([PSCustomObject]@{
    source = 'profile/cordis.yml'
    text = Get-Content -LiteralPath $cordisPath -Raw -Encoding UTF8
  })
}
$bashTool = Merge-RowStates -RowId 'tool-bash' -Sources $patchSources
$pwshTool = Merge-RowStates -RowId 'tool-pwsh' -Sources $patchSources
$bashSandbox = Merge-RowStates -RowId 'bash-sandbox' -Sources $patchSources
$pwshSandbox = Merge-RowStates -RowId 'pwsh-sandbox' -Sources $patchSources

try { $inventory = @(Get-DshPluginInventory -BaseUrl $BaseUrl -TimeoutSec 4) } catch { $apiErrors += [PSCustomObject]@{ stage = 'pluginInventory/list'; message = (Sanitize-Text $_.Exception.Message) } }
try { $hostValue = Invoke-DshGuardApi -BaseUrl $BaseUrl -Method 'host.describe' -Arguments @{} -TimeoutSec 4 } catch { $apiErrors += [PSCustomObject]@{ stage = 'host.describe'; message = (Sanitize-Text $_.Exception.Message) } }

$settingsDefault = Read-DefaultPreset -Path $settingsPath
$envPermissionMode = if ([string]::IsNullOrWhiteSpace($env:DSH_PERMISSION_MODE)) { $null } else { [string]$env:DSH_PERMISSION_MODE }
$permissionSemantics = switch ($settingsDefault) {
  'workspace-write' { [ordered]@{ sandbox = 'workspace-write'; approval = 'ask'; evidence = 'settings.yaml defaultPreset' } }
  'danger-full-access' { [ordered]@{ sandbox = 'danger-full-access'; approval = 'never'; evidence = 'settings.yaml defaultPreset'; warning = 'This is the widest built-in preset; a model should not pre-request it before a real sandbox denial.' } }
  default { [ordered]@{ sandbox = $null; approval = $null; evidence = if ($null -eq $settingsDefault) { 'not-observed' } else { 'unknown-preset' } } }
}
$statePath = Join-Path $StateRoot 'dsh-web.pid.json'
$guardStatePath = Join-Path $StateRoot 'guard-state.json'
$processRecord = Get-SafeProcessRecord -Path $statePath
$guardState = $null
if (Test-Path -LiteralPath $guardStatePath -PathType Leaf) {
  try { $guardState = Get-Content -LiteralPath $guardStatePath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $apiErrors += [PSCustomObject]@{ stage = 'guard-state'; message = (Sanitize-Text $_.Exception.Message) } }
}

$provider = if ($null -ne $hostValue) { [string]$hostValue.provider } else { $null }
$model = if ($null -ne $hostValue) { [string]$hostValue.model } else { $null }
$failedEntries = @($inventory | Where-Object { $_.fiberPhase -eq 'failed' } | ForEach-Object {
  [PSCustomObject]@{ entryId = [string]$_.entryId; moduleName = [string]$_.moduleName; fiberPhase = [string]$_.fiberPhase; enabled = $_.enabled -eq $true }
})
$shellRuntimeRows = @($inventory | Where-Object {
  $_.entryId -match '(?i)(bash|pwsh|shell)' -or $_.moduleName -match '(?i)(bash|pwsh|shell)'
} | ForEach-Object {
  [PSCustomObject]@{ entryId = [string]$_.entryId; moduleName = [string]$_.moduleName; enabled = $_.enabled -eq $true; fiberPhase = [string]$_.fiberPhase }
})
$sessionObservation = [ordered]@{
  status = 'not-requested'
  reason = 'Pass -SessionId to read a bounded session.history page. No session content is read by default.'
}
if (-not [string]::IsNullOrWhiteSpace($SessionId)) {
  try {
    $sessionObservation = Get-DshSessionObservation -BaseUrl $BaseUrl -Id $SessionId -Limit $MaxMessages
  } catch {
    $sessionObservation = [ordered]@{
      status = 'unavailable'
      sessionId = $SessionId
      error = (Sanitize-Text $_.Exception.Message)
      reason = 'session.history could not be read; this is not evidence that the session had no Tool Calls.'
    }
  }
}
$sessionModels = @()
if ($sessionObservation -is [System.Collections.IDictionary] -and $sessionObservation.Contains('modelContexts')) {
  $sessionModels = @($sessionObservation['modelContexts'])
}
$sessionModelNames = @($sessionModels | ForEach-Object {
  if ($null -ne $_ -and $null -ne $_.PSObject.Properties['model']) { [string]$_.model }
})
$observedModels = @($model) + $sessionModelNames |
  Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
  Sort-Object -Unique
$modelExpectation = $null
if (-not [string]::IsNullOrWhiteSpace($ExpectedModel)) {
  $modelExpectation = [ordered]@{
    expected = $ExpectedModel
    observed = $observedModels
    matched = @($observedModels | Where-Object { $_ -ceq $ExpectedModel }).Count -gt 0
    evidence = if ($sessionObservation.status -eq 'observed') { 'host.describe + session.history request/context' } else { 'host.describe only' }
  }
}

$report = [ordered]@{
  result = if (@($apiErrors | Where-Object { $_.stage -in @('manifest', 'guard-state') }).Count -gt 0) {
    'FAIL'
  } elseif ($apiErrors.Count -gt 0 -or $sessionObservation.status -eq 'unavailable' -or [string]$resourcePressure.status -in @('critical', 'warning', 'unavailable')) {
    'PARTIAL'
  } else {
    'PASS'
  }
  schemaVersion = 2
  generatedAt = (Get-Date).ToUniversalTime().ToString('o')
  profile = $Profile
  url = $BaseUrl
  dshVersion = if ($null -ne $hostValue) { [string]$hostValue.version } else { $null }
  modelRoute = [ordered]@{
    provider = $provider
    model = $model
    evidence = if ($null -ne $hostValue) { 'host.describe' } else { 'not-observed' }
    sessionContexts = $sessionModels
    expectation = $modelExpectation
    note = 'host.describe is Host configuration evidence; session.history request/context is the stronger per-session model evidence. Neither proves that a model successfully completed a Tool Call.'
  }
  permission = [ordered]@{
    settingsDefaultPreset = $settingsDefault
    environmentMode = $envPermissionMode
    semantics = $permissionSemantics
    meaning = 'default permission affects future sessions; a model should not request danger-full-access before a real sandbox denial'
  }
  shellStaticContract = [ordered]@{
    source = 'profile/cordis.yml'
    bashTool = $bashTool
    bashSandbox = $bashSandbox
    pwshTool = $pwshTool
    pwshSandbox = $pwshSandbox
    note = 'This is bundle static declaration only. On Windows, the official profile normally gates Bash rows and mounts PowerShell rows; the row state is not proof of a real Tool Call.'
  }
  shellRuntimeContract = [ordered]@{
    hostInventory = $shellRuntimeRows
    agentPresetEffectiveRoster = [ordered]@{
      status = 'not-observed'
      reason = 'Host inventory is not the same as the active model-facing agent preset roster; supply a session and inspect its session.history/request context.'
    }
    note = 'The Web Host may keep tool rows disabled while an agent preset mounts the effective tool. Do not infer Bash availability from a static row or from a sandbox_permissions field name.'
  }
  profileComposition = if ($null -ne $manifest) { [ordered]@{ bundles = @($manifest.dsh.profile.bundles); dependencies = @(Get-DependencyShape -Manifest $manifest) } } else { $null }
  runtimeRootsChecked = $runtimeRootsChecked
  runtimeEvidence = [ordered]@{
    status = switch ([string]$resourcePressure.status) {
      'healthy' { 'usable' }
      'warning' { 'degraded' }
      'critical' { 'degraded' }
      default { 'unavailable' }
    }
    resourcePressure = $resourcePressure
    note = 'Resource pressure is an environment observation. A warning or critical state weakens live failure attribution; it does not prove a plugin fault.'
  }
  pluginInventory = [ordered]@{ observed = $inventory.Count -gt 0; count = $inventory.Count; failed = $failedEntries; shellRows = $shellRuntimeRows }
  guard = [ordered]@{ enabledInLastProcess = if ($null -ne $processRecord) { $processRecord.crashGuard } else { $false }; quarantineCount = if ($null -ne $guardState) { @($guardState.quarantined).Count } else { 0 }; statePresent = $null -ne $guardState }
  process = $processRecord
  toolCallObservation = [ordered]@{
    status = $sessionObservation.status
    session = $sessionObservation
    reason = if ($sessionObservation.status -eq 'not-requested') { 'No session id was supplied; no Tool Call claim is made.' } else { 'Bounded, metadata-only session.history observation.' }
    privacy = 'Tool arguments, outputs, credentials, cookies, authorization headers, and full cwd are intentionally omitted.'
  }
  errors = $apiErrors
}

$report | ConvertTo-Json -Depth 12
