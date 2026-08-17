Set-StrictMode -Version Latest

$script:LastProfileManifest = $null
$script:LastGuardPatchPath = $null

function New-DshGuardState {
  param([Parameter(Mandatory = $true)][string]$Profile)
  return [PSCustomObject]@{
    version = 1
    profile = $Profile
    failures = @()
    quarantined = @()
    lastRun = $null
  }
}

function Read-DshGuardState {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$Profile
  )
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    return New-DshGuardState -Profile $Profile
  }
  try {
    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    $parsed = $raw | ConvertFrom-Json
    $state = New-DshGuardState -Profile $Profile
    if ($null -ne $parsed.failures) { $state.failures = @($parsed.failures) }
    if ($null -ne $parsed.quarantined) { $state.quarantined = @($parsed.quarantined) }
    if ($null -ne $parsed.lastRun) { $state.lastRun = $parsed.lastRun }
    return $state
  } catch {
    throw "guard state is not readable: $Path; back it up and remove it before retrying"
  }
}

function Write-DshGuardState {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)]$State
  )
  $parent = Split-Path -Parent $Path
  if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
  }
  $State | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Read-DshProfileManifest {
  param([Parameter(Mandatory = $true)][string]$Path)
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    throw "profile manifest does not exist: $Path"
  }
  $manifest = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
  $script:LastProfileManifest = $manifest
  return $manifest
}

function Get-DshManifestPackageSpec {
  param(
    [Parameter(Mandatory = $true)]$Manifest,
    [Parameter(Mandatory = $true)][string]$Name
  )
  foreach ($sectionName in @('dependencies', 'devDependencies', 'optionalDependencies')) {
    $sectionProperty = $Manifest.PSObject.Properties[$sectionName]
    if ($null -eq $sectionProperty -or $null -eq $sectionProperty.Value) { continue }
    $section = $sectionProperty.Value
    $property = $section.PSObject.Properties[$Name]
    if ($null -ne $property) { return [string]$property.Value }
  }
  return $null
}

function Get-DshManifestDependencyNames {
  param([Parameter(Mandatory = $true)]$Manifest)
  $names = @()
  foreach ($sectionName in @('dependencies', 'devDependencies', 'optionalDependencies')) {
    $sectionProperty = $Manifest.PSObject.Properties[$sectionName]
    if ($null -eq $sectionProperty -or $null -eq $sectionProperty.Value) { continue }
    $names += @($sectionProperty.Value.PSObject.Properties | ForEach-Object { [string]$_.Name })
  }
  return @($names | Sort-Object -Unique)
}

function Resolve-DshPatchEntryId {
  param(
    [Parameter(Mandatory = $true)]$Entry,
    [Parameter(Mandatory = $true)]$Manifest
  )
  $inventoryEntryId = [string]$Entry.entryId
  $moduleName = [string]$Entry.moduleName
  $dependencyNames = @(Get-DshManifestDependencyNames -Manifest $Manifest)
  $patchEntryId = $null
  $mapping = 'unresolved'

  # The host inventory exposes Cordis Loader ids (often include:<row-id>),
  # while dsh --dump-config patches the composed row id without that wrapper.
  # Only accept a mapping that can be justified by the current Profile
  # manifest. Never guess from an arbitrary transitive package name.
  if (-not [string]::IsNullOrWhiteSpace($inventoryEntryId) -and
      @($dependencyNames | Where-Object { $_ -ceq $inventoryEntryId }).Count -eq 1) {
    $patchEntryId = $inventoryEntryId
    $mapping = 'exact'
  }

  if ($null -eq $patchEntryId -and $inventoryEntryId -match '^(?i:include):(.+)$') {
    $stripped = $Matches[1]
    if (@($dependencyNames | Where-Object { $_ -ceq $stripped }).Count -eq 1) {
      $patchEntryId = $stripped
      $mapping = 'stripped-include'
    }
  }

  if ($null -eq $patchEntryId -and -not [string]::IsNullOrWhiteSpace($moduleName)) {
    if (@($dependencyNames | Where-Object { $_ -ceq $moduleName }).Count -eq 1) {
      $patchEntryId = $moduleName
      $mapping = 'module-name'
    }
  }

  return [PSCustomObject]@{
    inventoryEntryId = if ([string]::IsNullOrWhiteSpace($inventoryEntryId)) { $null } else { $inventoryEntryId }
    patchEntryId = $patchEntryId
    moduleName = if ([string]::IsNullOrWhiteSpace($moduleName)) { $null } else { $moduleName }
    mapping = $mapping
    resolved = $null -ne $patchEntryId
  }
}

function Test-DshGuardCandidate {
  param(
    [Parameter(Mandatory = $true)][string]$ModuleName,
    [Parameter(Mandatory = $true)]$Manifest
  )
  if ([string]::IsNullOrWhiteSpace($ModuleName)) { return $false }

  # Never mutate a core package automatically. A core failure needs a
  # version/configuration diagnosis rather than a broad profile mutation.
  if ($ModuleName -match '^@deepseek-ai/' -or
      $ModuleName -in @('dsh-base', 'dsh-web-app', 'react', 'react-dom', 'zod')) {
    return $false
  }

  $spec = Get-DshManifestPackageSpec -Manifest $Manifest -Name $ModuleName
  if ($null -eq $spec) { return $false }

  # Local links/files are the user's own extension surface. Named DSH plugin
  # packages are also candidates; arbitrary transitive dependencies are not.
  return ($spec -match '^(?i:link:|file:)') -or
    ($ModuleName -match '(?i)(^|[-/])dsh-plugin([-/.]|$)') -or
    ($ModuleName -match '(?i)(^|[-/])plugin([-/.]|$)')
}

function Get-DshGuardCandidates {
  param(
    [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Entries,
    [Parameter(Mandatory = $true)]$Manifest
  )
  $result = @()
  foreach ($entry in @($Entries)) {
    if ([string]$entry.fiberPhase -ne 'failed') { continue }
    # A disabled row is already under user or guard control. Do not count it
    # as a new runtime failure or repeatedly rewrite its quarantine state.
    if ($entry.PSObject.Properties['enabled'] -and $entry.enabled -eq $false) { continue }
    $moduleName = [string]$entry.moduleName
    if (-not (Test-DshGuardCandidate -ModuleName $moduleName -Manifest $Manifest)) { continue }
    $resolution = Resolve-DshPatchEntryId -Entry $entry -Manifest $Manifest
    if (-not $resolution.resolved) { continue }
    $result += [PSCustomObject]@{
      # entryId is the reversible Profile patch id. Keep the raw host id for
      # auditability instead of accidentally writing include:<id> to a patch.
      entryId = [string]$resolution.patchEntryId
      inventoryEntryId = $resolution.inventoryEntryId
      patchEntryId = [string]$resolution.patchEntryId
      moduleName = $moduleName
      mapping = [string]$resolution.mapping
      fiberPhase = 'failed'
      reason = 'host-plugin-inventory:fiber-failed'
      attribution = 'observed'
    }
  }
  return @($result | Sort-Object moduleName, entryId -Unique)
}

function Get-DshStartupGuardCandidates {
  param(
    [Parameter(Mandatory = $true)]$Manifest,
    [string]$ErrorText = ''
  )
  $startupMatches = @()
  foreach ($moduleName in Get-DshManifestDependencyNames -Manifest $Manifest) {
    if (-not (Test-DshGuardCandidate -ModuleName $moduleName -Manifest $Manifest)) { continue }
    if ([string]::IsNullOrWhiteSpace($ErrorText)) { continue }
    $escaped = [regex]::Escape($moduleName)
      if ($ErrorText -match $escaped) {
      $resolution = Resolve-DshPatchEntryId -Entry ([PSCustomObject]@{
          entryId = $moduleName
          moduleName = $moduleName
        }) -Manifest $Manifest
      if (-not $resolution.resolved) { continue }
      $startupMatches += [PSCustomObject]@{
        entryId = [string]$resolution.patchEntryId
        inventoryEntryId = $resolution.inventoryEntryId
        patchEntryId = [string]$resolution.patchEntryId
        moduleName = $moduleName
        mapping = [string]$resolution.mapping
        fiberPhase = 'failed'
        reason = 'startup-failure:module-name-in-error-log'
        attribution = 'log-name-match'
      }
    }
  }
  return @($startupMatches | Sort-Object moduleName -Unique)
}

function Get-DshSingleStartupGuardCandidate {
  param(
    [Parameter(Mandatory = $true)]$Manifest,
    [string]$ErrorText = ''
  )
  $eligible = @(
    Get-DshManifestDependencyNames -Manifest $Manifest |
      Where-Object { Test-DshGuardCandidate -ModuleName $_ -Manifest $Manifest }
  )
  if ($eligible.Count -ne 1) { return $null }
  if ([string]::IsNullOrWhiteSpace($ErrorText)) { return $null }
  if ($ErrorText -notmatch '(?i)(error|exception|failed|crash|exit|timeout|fatal)') { return $null }
  $moduleName = [string]$eligible[0]
  $resolution = Resolve-DshPatchEntryId -Entry ([PSCustomObject]@{
      entryId = $moduleName
      moduleName = $moduleName
    }) -Manifest $Manifest
  if (-not $resolution.resolved) { return $null }
  return [PSCustomObject]@{
    entryId = [string]$resolution.patchEntryId
    inventoryEntryId = $resolution.inventoryEntryId
    patchEntryId = [string]$resolution.patchEntryId
    moduleName = $moduleName
    mapping = [string]$resolution.mapping
    fiberPhase = 'failed'
    reason = 'startup-failure:single-safe-candidate-fallback'
    attribution = 'heuristic-single-candidate'
  }
}

function Add-DshGuardFailure {
  param(
    [Parameter(Mandatory = $true)]$State,
    [Parameter(Mandatory = $true)]$Candidate
  )
  $now = (Get-Date).ToUniversalTime().ToString('o')
  $key = if (-not [string]::IsNullOrWhiteSpace([string]$Candidate.entryId)) { [string]$Candidate.entryId } else { [string]$Candidate.moduleName }
  $existing = @($State.failures | Where-Object {
      ([string]$_.entryId -eq $key) -or ([string]$_.moduleName -eq [string]$Candidate.moduleName)
    } | Select-Object -First 1)
  if ($existing.Count -eq 0) {
    $State.failures = @($State.failures) + @([PSCustomObject]@{
      entryId = $key
      inventoryEntryId = [string]$Candidate.inventoryEntryId
      patchEntryId = if (-not [string]::IsNullOrWhiteSpace([string]$Candidate.patchEntryId)) { [string]$Candidate.patchEntryId } else { $key }
      moduleName = [string]$Candidate.moduleName
      count = 1
      lastAt = $now
      lastReason = [string]$Candidate.reason
      attribution = [string]$Candidate.attribution
      mapping = [string]$Candidate.mapping
    })
  } else {
    $existing[0].count = [int]$existing[0].count + 1
    $existing[0].lastAt = $now
    $existing[0].lastReason = [string]$Candidate.reason
    $existing[0].attribution = [string]$Candidate.attribution
  }
  return $State
}

function Add-DshGuardQuarantine {
  param(
    [Parameter(Mandatory = $true)]$State,
    [Parameter(Mandatory = $true)]$Candidate
  )
  $key = if (-not [string]::IsNullOrWhiteSpace([string]$Candidate.entryId)) { [string]$Candidate.entryId } else { [string]$Candidate.moduleName }
  $existing = @($State.quarantined | Where-Object {
      ([string]$_.entryId -eq $key) -or ([string]$_.moduleName -eq [string]$Candidate.moduleName)
    } | Select-Object -First 1)
  if ($existing.Count -eq 0) {
    $State.quarantined = @($State.quarantined) + @([PSCustomObject]@{
      entryId = $key
      inventoryEntryId = [string]$Candidate.inventoryEntryId
      patchEntryId = if (-not [string]::IsNullOrWhiteSpace([string]$Candidate.patchEntryId)) { [string]$Candidate.patchEntryId } else { $key }
      moduleName = [string]$Candidate.moduleName
      reason = [string]$Candidate.reason
      attribution = [string]$Candidate.attribution
      mapping = [string]$Candidate.mapping
      quarantinedAt = (Get-Date).ToUniversalTime().ToString('o')
    })
  }
  return $State
}

function Get-DshGuardPatchEntries {
  param([Parameter(Mandatory = $true)]$State)
  return @($State.quarantined | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.entryId) })
}

function Write-DshGuardPatch {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [object[]]$Entries = @()
  )
  $script:LastGuardPatchPath = $Path
  $parent = Split-Path -Parent $Path
  if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
  }
  $lines = @(
    '# Generated by dsh-plugin-debug standalone crash guard.'
    '# Remove an entry from guard-state.json and delete this file to re-enable it.'
  )
  $written = 0
  foreach ($entry in @($Entries | Sort-Object entryId -Unique)) {
    $entryId = [string]$entry.entryId
    if ([string]::IsNullOrWhiteSpace($entryId)) { continue }
    $entryId = $entryId.Replace("'", "''")
    $lines += "- id: '$entryId'"
    $moduleName = [string]$entry.moduleName
    if (-not [string]::IsNullOrWhiteSpace($moduleName)) {
      $lines += "  name: '$($moduleName.Replace("'", "''"))'"
    }
    $lines += '  disabled: true'
    $written += 1
  }
  if ($written -eq 0) { $lines += '[]' }
  $lines | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Get-DshGuardStartupErrorText {
  if ([string]::IsNullOrWhiteSpace([string]$script:LastGuardPatchPath)) { return '' }
  $stateRoot = Split-Path -Parent $script:LastGuardPatchPath
  $stderrPath = Join-Path (Join-Path $stateRoot 'logs') 'dsh.stderr.log'
  if (-not (Test-Path -LiteralPath $stderrPath -PathType Leaf)) { return '' }
  try {
    $text = ((Get-Content -LiteralPath $stderrPath -Tail 240 -ErrorAction Stop) -join "`n")
    if ($text.Length -gt 24000) { return $text.Substring($text.Length - 24000) }
    return $text
  } catch {
    return ''
  }
}

function Get-DshDisconnectedPluginInventory {
  $manifest = $script:LastProfileManifest
  if ($null -eq $manifest) { return @() }
  $errorText = Get-DshGuardStartupErrorText
  if ([string]::IsNullOrWhiteSpace($errorText)) { return @() }

  $candidates = @(Get-DshStartupGuardCandidates -Manifest $manifest -ErrorText $errorText)
  if ($candidates.Count -eq 0) {
    $fallback = Get-DshSingleStartupGuardCandidate -Manifest $manifest -ErrorText $errorText
    if ($null -ne $fallback) { $candidates = @($fallback) }
  }
  return @($candidates | ForEach-Object {
      [PSCustomObject]@{
        entryId = "include:$($_.moduleName)"
        moduleName = [string]$_.moduleName
        fiberPhase = 'failed'
        enabled = $true
      }
  })
}

function Resolve-DshGuardApiUri {
  param(
    [Parameter(Mandatory = $true)][string]$BaseUrl,
    [Parameter(Mandatory = $true)][string]$Method
  )
  $baseUri = $null
  if (-not [Uri]::TryCreate($BaseUrl, [UriKind]::Absolute, [ref]$baseUri)) {
    throw 'DSH API BaseUrl must be an absolute HTTP(S) URL'
  }
  if ($baseUri.Scheme -notin @('http', 'https')) {
    throw 'DSH API BaseUrl must use http or https'
  }
  if (-not [string]::IsNullOrWhiteSpace($baseUri.UserInfo)) {
    throw 'DSH API BaseUrl must not contain userinfo or embedded credentials'
  }
  if (-not [string]::IsNullOrWhiteSpace($baseUri.Query) -or -not [string]::IsNullOrWhiteSpace($baseUri.Fragment)) {
    throw 'DSH API BaseUrl must not contain a query or fragment'
  }
  if ($Method -notmatch '^[A-Za-z][A-Za-z0-9._/-]{0,100}$' -or $Method.Contains('..') -or $Method.StartsWith('/') -or $Method.EndsWith('/')) {
    throw "invalid DSH API method: $Method"
  }

  $allowedHosts = @()
  if (-not [string]::IsNullOrWhiteSpace($env:DSH_DEBUG_API_ALLOWED_HOSTS)) {
    $allowedHosts = @($env:DSH_DEBUG_API_ALLOWED_HOSTS -split ',' | ForEach-Object { $_.Trim().ToLowerInvariant() } | Where-Object { $_ })
  }
  $host = $baseUri.DnsSafeHost.ToLowerInvariant()
  if (-not $baseUri.IsLoopback -and $allowedHosts -notcontains $host) {
    throw "DSH API BaseUrl host '$host' is not loopback; set DSH_DEBUG_API_ALLOWED_HOSTS explicitly to allow a trusted host"
  }
  return [Uri]::new("$($BaseUrl.TrimEnd('/'))/api/$Method")
}

# The rc.6 host API and the Typert plugin remotes share the same
# client-request envelope, but they do not share the same business-payload
# shape.  Host API methods receive their arguments directly as `payload`,
# while Typert remotes (for example pluginInventory/list) receive
# `payload.args`.  Keep the distinction explicit so a diagnostic call cannot
# silently turn into a host-side bad-request.
$script:DshDirectPayloadMethods = @(
  'session.list',
  'session.search',
  'session.create',
  'session.history',
  'session.models',
  'session.selectModel',
  'session.rename',
  'session.fork',
  'session.prompt',
  'session.attachment',
  'session.updateQueue',
  'session.cancel',
  'subagent.list',
  'subagent.history',
  'subagent.prompt',
  'subagent.interrupt',
  'host.describe',
  'host.pickDirectory',
  'host.listDirectory',
  'host.createDirectory',
  'host.openPath',
  'workspace.list',
  'workspace.create',
  'workspace.rename',
  'workspace.delete',
  'workspace.insertBefore',
  'workspace.insertSessionBefore',
  'workspace.archiveSession',
  'skill.list',
  'agentPreset.list',
  'agentPreset.select',
  'agentPreset.read',
  'agentPreset.copy',
  'agentPreset.openDocument',
  'agentPreset.remove',
  'goal.create',
  'goal.edit',
  'goal.pause',
  'goal.resume',
  'goal.complete',
  'goal.clear',
  'settings.describe',
  'settings.openDocument',
  'settings.update',
  'settings.replace',
  'settings.mutate',
  'credentials.describe',
  'credentials.set',
  'credentials.unset',
  'llm.providers',
  'llm.models',
  'llm.discoverModels'
)

function Invoke-DshGuardApi {
  param(
    [Parameter(Mandatory = $true)][string]$BaseUrl,
    [Parameter(Mandatory = $true)][string]$Method,
    [hashtable]$Arguments = @{},
    [int]$TimeoutSec = 5,
    [ValidateSet('auto', 'direct', 'args')][string]$PayloadStyle = 'auto'
  )
  $uri = Resolve-DshGuardApiUri -BaseUrl $BaseUrl -Method $Method
  $useDirectPayload = if ($PayloadStyle -eq 'direct') {
    $true
  } elseif ($PayloadStyle -eq 'args') {
    $false
  } else {
    $script:DshDirectPayloadMethods -contains $Method
  }
  $payload = if ($useDirectPayload) { $Arguments } else { @{ args = $Arguments } }
  $body = [ordered]@{
    type = 'client-request'
    rpcId = "dsh-guard-$([guid]::NewGuid().ToString('N'))"
    method = $Method
    payload = $payload
  } | ConvertTo-Json -Depth 12 -Compress
  $response = Invoke-RestMethod -UseBasicParsing -Uri $uri -Method Post -ContentType 'application/json' -Body $body -TimeoutSec $TimeoutSec
  if ($null -eq $response.result) { throw "DSH API response has no result: $Method" }
  if ($response.result.ok -ne $true) {
    $code = [string]$response.result.error.code
    $message = [string]$response.result.error.message
    throw "DSH API failed: $Method; code=$code; message=$message"
  }
  return $response.result.value
}

function Get-DshPluginInventory {
  param(
    [Parameter(Mandatory = $true)][string]$BaseUrl,
    [int]$TimeoutSec = 5
  )
  try {
    $value = Invoke-DshGuardApi -BaseUrl $BaseUrl -Method 'pluginInventory/list' -Arguments @{} -TimeoutSec $TimeoutSec
    return @($value.entries)
  } catch {
    $disconnectedEntries = @(Get-DshDisconnectedPluginInventory)
    if ($disconnectedEntries.Count -gt 0) { return $disconnectedEntries }
    throw
  }
}

Export-ModuleMember -Function @(
  'New-DshGuardState',
  'Read-DshGuardState',
  'Write-DshGuardState',
  'Read-DshProfileManifest',
  'Get-DshManifestPackageSpec',
  'Get-DshManifestDependencyNames',
  'Resolve-DshPatchEntryId',
  'Test-DshGuardCandidate',
  'Get-DshGuardCandidates',
  'Get-DshStartupGuardCandidates',
  'Get-DshSingleStartupGuardCandidate',
  'Add-DshGuardFailure',
  'Add-DshGuardQuarantine',
  'Get-DshGuardPatchEntries',
  'Write-DshGuardPatch',
  'Invoke-DshGuardApi',
  'Get-DshPluginInventory'
)
