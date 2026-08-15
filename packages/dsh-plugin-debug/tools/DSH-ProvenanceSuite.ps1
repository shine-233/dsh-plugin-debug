[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [ValidateSet('context-doctor', 'security-audit', 'session-health', 'fail-log', 'provenance', 'pointer-evidence')]
  [string]$Action,
  [string]$DshHome = '',
  [string]$Profile = 'web',
  [string]$StateRoot = '',
  [string]$InputPath = '',
  [string]$Root = '',
  [int]$Port = 3080,
  [string]$HostName = '127.0.0.1',
  [string]$Label = 'tool-failure',
  [switch]$IncludeWorkspace,
  [switch]$IncludeUserConfig
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$suiteRoot = Split-Path -Parent $MyInvocation.MyCommand.Path

function Resolve-DshHome {
  param([string]$Value)
  if ([string]::IsNullOrWhiteSpace($Value)) {
    $Value = if ([string]::IsNullOrWhiteSpace($env:DSH_HOME)) { Join-Path $env:USERPROFILE '.dsh' } else { $env:DSH_HOME }
  }
  return [IO.Path]::GetFullPath($Value)
}

function Resolve-StateRoot {
  param([string]$Value)
  if ([string]::IsNullOrWhiteSpace($Value)) {
    return Join-Path $suiteRoot 'state\suite'
  }
  return [IO.Path]::GetFullPath($Value)
}

function Get-ProvenancePropertyValue {
  param([AllowNull()]$Object, [Parameter(Mandatory = $true)][string]$Name)
  if ($null -eq $Object) { return $null }
  if ($Object -is [System.Collections.IDictionary] -and $Object.Contains($Name)) { return $Object[$Name] }
  $property = $Object.PSObject.Properties[$Name]
  if ($null -eq $property) { return $null }
  return $property.Value
}

function Get-ProvenanceSha256 {
  param([Parameter(Mandatory = $true)][string]$Path)
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
  $sha = [Security.Cryptography.SHA256]::Create()
  try {
    return ([BitConverter]::ToString($sha.ComputeHash([IO.File]::ReadAllBytes($Path)))).Replace('-', '').ToLowerInvariant()
  } finally {
    $sha.Dispose()
  }
}

function Get-ProvenanceProfileState {
  param(
    [Parameter(Mandatory = $true)][string]$DshHomeRoot,
    [Parameter(Mandatory = $true)][string]$ProfileName
  )

  $profileRoot = Join-Path $DshHomeRoot "profiles\$ProfileName"
  $manifestPath = Join-Path $profileRoot 'package.json'
  $installedRoot = Join-Path $profileRoot 'node_modules\dsh-plugin-debug'
  $installedManifestPath = Join-Path $installedRoot 'package.json'
  $manifestExists = Test-Path -LiteralPath $manifestPath -PathType Leaf
  $base = [ordered]@{
    profile = $ProfileName
    manifest = Get-SafeText -Value $manifestPath -MaxLength 300
    manifestExists = $manifestExists
    dependencyDeclared = $false
    dependencySpecKind = $null
    bundleListed = $false
    installedPackage = Get-SafeText -Value $installedManifestPath -MaxLength 300
    installedPackageExists = Test-Path -LiteralPath $installedManifestPath -PathType Leaf
    installedPackageVersion = $null
    installedFiles = [ordered]@{
      package = Test-Path -LiteralPath $installedManifestPath -PathType Leaf
      bundleManifest = Test-Path -LiteralPath (Join-Path $installedRoot 'bundle-manifest.json') -PathType Leaf
      patch = Test-Path -LiteralPath (Join-Path $installedRoot 'cordis.patch.yml') -PathType Leaf
      client = Test-Path -LiteralPath (Join-Path $installedRoot 'lib\client.js') -PathType Leaf
      host = Test-Path -LiteralPath (Join-Path $installedRoot 'lib\index.js') -PathType Leaf
    }
    independentBundle = $true
    status = 'not-installed'
  }
  if (-not $manifestExists) { return $base }

  try {
    $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $dependencies = Get-ProvenancePropertyValue -Object $manifest -Name 'dependencies'
    $dependency = Get-ProvenancePropertyValue -Object $dependencies -Name 'dsh-plugin-debug'
    $dsh = Get-ProvenancePropertyValue -Object $manifest -Name 'dsh'
    $profileValue = Get-ProvenancePropertyValue -Object $dsh -Name 'profile'
    $bundles = @(Get-ProvenancePropertyValue -Object $profileValue -Name 'bundles')
    $base.dependencyDeclared = $null -ne $dependency
    $base.dependencySpecKind = if ([string]$dependency -match '^(?i:link:)') { 'local-link' } elseif ([string]$dependency -match '^(?i:file:)') { 'local-file' } elseif ($null -ne $dependency) { 'registry-or-other' } else { $null }
    $base.bundleListed = $bundles -contains 'dsh-plugin-debug'
    if ($base.installedPackageExists) {
      try {
        $installedManifest = Get-Content -LiteralPath $installedManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $base.installedPackageVersion = [string](Get-ProvenancePropertyValue -Object $installedManifest -Name 'version')
      } catch {
        $base.installedPackageVersion = $null
      }
    }
    $filesComplete = @($base.installedFiles.Values | Where-Object { $_ -ne $true }).Count -eq 0
    $base.status = if ($base.dependencyDeclared -and $base.bundleListed -and $filesComplete) { 'installed' } elseif ($base.dependencyDeclared -or $base.bundleListed -or $base.installedPackageExists) { 'incomplete' } else { 'not-installed' }
    return $base
  } catch {
    $base.status = 'unreadable'
    $base.error = 'profile manifest could not be parsed'
    return $base
  }
}

function Invoke-ProvenanceContract {
  param(
    [Parameter(Mandatory = $true)][string]$DshHomeRoot,
    [Parameter(Mandatory = $true)][string]$ProfileName
  )
  $packageRoot = Split-Path -Parent $suiteRoot
  $clientPath = Join-Path $packageRoot 'lib\client.js'
  $bundleManifestPath = Join-Path $packageRoot 'bundle-manifest.json'
  $requiredMethods = @('enable', 'disable', 'setEnabled', 'getCurrent', 'getPointerEvidence', 'getBridgeSnapshot', 'inspect', 'scan', 'getClientErrors', 'clearClientErrors')
  $requiredMarkers = @(
    '__DSH_PLUGIN_DEBUG__',
    '__DSH_PLUGIN_PROVENANCE__',
    'const POINTER_EVENT = `${PLUGIN_ID}:pointer`',
    'pointerEvent: POINTER_EVENT',
    'data-dsh-debug-bridge',
    'data-dsh-provenance-api',
    'data-dsh-provenance-bridge',
    'getPointerEvidence()',
    'scan() {',
    'inspect(target,'
  )
  $missing = [System.Collections.Generic.List[string]]::new()
  $exists = Test-Path -LiteralPath $clientPath -PathType Leaf
  $text = if ($exists) { Get-Content -LiteralPath $clientPath -Raw -Encoding UTF8 } else { '' }
  foreach ($marker in $requiredMarkers) {
    if ($text.IndexOf($marker, [StringComparison]::Ordinal) -lt 0) { $missing.Add($marker) }
  }
  $bundleManifest = $null
  $bundleManifestValid = $false
  if (Test-Path -LiteralPath $bundleManifestPath -PathType Leaf) {
    try {
      $bundleManifest = Get-Content -LiteralPath $bundleManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
      $bundleManifestValid = [int]$bundleManifest.schemaVersion -eq 1 -and
        [string]$bundleManifest.package -ceq 'dsh-plugin-debug' -and
        $bundleManifest.independentRuntime -eq $true -and
        $bundleManifest.features.pointerProvenance.embedded -eq $true
    } catch {
      $bundleManifestValid = $false
    }
  }
  if (-not $bundleManifestValid) { $missing.Add('bundle-manifest.json:embedded-pointer-contract') }
  $hash = if ($exists) { Get-ProvenanceSha256 -Path $clientPath } else { $null }
  $bundleManifestHash = if (Test-Path -LiteralPath $bundleManifestPath -PathType Leaf) {
    Get-ProvenanceSha256 -Path $bundleManifestPath
  } else { $null }
  $pass = $exists -and $missing.Count -eq 0
  $profileState = Get-ProvenanceProfileState -DshHomeRoot $DshHomeRoot -ProfileName $ProfileName
  [ordered]@{
    result = if ($pass) { 'PASS' } else { 'FAIL' }
    action = 'provenance'
    readOnly = $true
    pluginId = 'dsh-plugin-debug'
    globalName = '__DSH_PLUGIN_DEBUG__'
    legacyGlobalName = '__DSH_PLUGIN_PROVENANCE__'
    bridgeSelector = 'meta[data-dsh-debug-bridge="1"]'
    legacyBridgeSelector = 'meta[data-dsh-provenance-bridge="1"]'
    apiVersion = 1
    pointerEvent = 'dsh-plugin-debug:pointer'
    globalExpando = 'best-effort; frozen DSH page realms use bridgeSelector'
    clientArtifact = Get-SafeText -Value $clientPath -MaxLength 300
    clientArtifactExists = $exists
    clientArtifactSha256 = $hash
    bundleManifest = Get-SafeText -Value $bundleManifestPath -MaxLength 300
    bundleManifestExists = Test-Path -LiteralPath $bundleManifestPath -PathType Leaf
    bundleManifestValid = $bundleManifestValid
    bundleManifestSha256 = $bundleManifestHash
    requiredMethods = $requiredMethods
    missingMarkers = @($missing)
    profileIntegration = $profileState
    integratedIntoCurrentProfile = $profileState.status -eq 'installed'
    requiresLiveBrowser = $true
    livePointerObservation = 'not-run-by-host-contract'
    privacy = [ordered]@{
      readsCookies = $false
      readsTokens = $false
      sendsNetworkPayload = $false
      capturesScreenshot = $false
      capturesToolArguments = $false
    }
  }
}

function Get-SafePointerSource {
  param([AllowNull()]$Value)
  if ($null -eq $Value) { return $null }
  [ordered]@{
    plugin = Get-SafeText -Value ([string](Get-ProvenancePropertyValue -Object $Value -Name 'plugin')) -MaxLength 240
    module = Get-SafeText -Value ([string](Get-ProvenancePropertyValue -Object $Value -Name 'module')) -MaxLength 240
  }
}

function Get-SafePointerObservation {
  param([AllowNull()]$Value)
  if ($null -eq $Value) { return $null }
  $ancestorCountValue = 0
  $ancestorCountRaw = [string](Get-ProvenancePropertyValue -Object $Value -Name 'ancestorCount')
  $ancestorCount = if ([int]::TryParse($ancestorCountRaw, [ref]$ancestorCountValue)) { [int]$ancestorCountValue } else { $null }
  $sources = @(Get-ProvenancePropertyValue -Object $Value -Name 'sources') | Where-Object { $null -ne $_ } | Select-Object -First 4 | ForEach-Object {
    Get-SafePointerSource -Value $_
  }
  [ordered]@{
    plugin = Get-SafeText -Value ([string](Get-ProvenancePropertyValue -Object $Value -Name 'plugin')) -MaxLength 240
    module = Get-SafeText -Value ([string](Get-ProvenancePropertyValue -Object $Value -Name 'module')) -MaxLength 240
    slot = Get-SafeText -Value ([string](Get-ProvenancePropertyValue -Object $Value -Name 'slot')) -MaxLength 240
    evidence = Get-SafeText -Value ([string](Get-ProvenancePropertyValue -Object $Value -Name 'evidence')) -MaxLength 240
    confidence = Get-SafeText -Value ([string](Get-ProvenancePropertyValue -Object $Value -Name 'confidence')) -MaxLength 40
    node = Get-SafeText -Value ([string](Get-ProvenancePropertyValue -Object $Value -Name 'node')) -MaxLength 120
    className = Get-SafeText -Value ([string](Get-ProvenancePropertyValue -Object $Value -Name 'className')) -MaxLength 120
    ancestorCount = $ancestorCount
    ancestorLimitReached = (Get-ProvenancePropertyValue -Object $Value -Name 'ancestorLimitReached') -eq $true
    sourceSearchIncomplete = (Get-ProvenancePropertyValue -Object $Value -Name 'sourceSearchIncomplete') -eq $true
    observationId = Get-SafeText -Value ([string](Get-ProvenancePropertyValue -Object $Value -Name 'observationId')) -MaxLength 120
    pageObservationId = Get-SafeText -Value ([string](Get-ProvenancePropertyValue -Object $Value -Name 'pageObservationId')) -MaxLength 120
    observedAt = Get-SafeText -Value ([string](Get-ProvenancePropertyValue -Object $Value -Name 'observedAt')) -MaxLength 80
    sources = @($sources)
  }
}

function Invoke-PointerEvidence {
  param(
    [Parameter(Mandatory = $true)][string]$InputPath
  )
  if (-not (Test-Path -LiteralPath $InputPath -PathType Leaf)) { throw "pointer evidence input does not exist: $InputPath" }
  $source = Get-Content -LiteralPath $InputPath -Raw -Encoding UTF8 | ConvertFrom-Json
  $pointer = Get-ProvenancePropertyValue -Object $source -Name 'pointer'
  $sourceKind = 'client-diagnostics-report'
  if ($null -eq $pointer) {
    $pointer = $source
    $sourceKind = if ($null -ne (Get-ProvenancePropertyValue -Object $source -Name 'bridge')) { 'pointer-evidence-snapshot' } else { 'bridge-snapshot-or-pointer-record' }
  }
  $current = Get-ProvenancePropertyValue -Object $pointer -Name 'current'
  if ($null -eq $current) {
    $bridge = Get-ProvenancePropertyValue -Object $pointer -Name 'bridge'
    $current = Get-ProvenancePropertyValue -Object $bridge -Name 'current'
  }
  $observation = Get-SafePointerObservation -Value $current
  $enabled = (Get-ProvenancePropertyValue -Object $pointer -Name 'enabled') -eq $true
  $schemaVersion = Get-ProvenancePropertyValue -Object $pointer -Name 'schemaVersion'
  $hasObservation = $null -ne $observation -and @($observation.GetEnumerator() | Where-Object { $_.Key -in @('plugin', 'module', 'slot') -and -not [string]::IsNullOrWhiteSpace([string]$_.Value) }).Count -gt 0
  [ordered]@{
    result = if ($hasObservation) { 'PASS' } else { 'PARTIAL' }
    action = 'pointer-evidence'
    readOnly = $true
    source = Get-SafeText -Value ([IO.Path]::GetFullPath($InputPath)) -MaxLength 300
    sourceKind = $sourceKind
    schemaVersion = $schemaVersion
    pluginId = Get-SafeText -Value ([string](Get-ProvenancePropertyValue -Object $source -Name 'pluginId')) -MaxLength 120
    enabled = $enabled
    pageObservationId = Get-SafeText -Value ([string](Get-ProvenancePropertyValue -Object $pointer -Name 'pageObservationId')) -MaxLength 120
    observation = $observation
    evidenceObserved = $hasObservation
    confidence = if ($null -eq $observation) { 'none' } else { [string]$observation.confidence }
    causalAttribution = 'not-supported'
    manualReviewRequired = $true
    privacy = [ordered]@{
      rawInputStored = $false
      pageTextStored = $false
      screenshotStored = $false
      cookiesStored = $false
      tokensStored = $false
      toolArgumentsStored = $false
      networkPayloadSent = $false
    }
  }
}

function Get-SafeText {
  param([AllowNull()][string]$Value, [int]$MaxLength = 500)
  if ($null -eq $Value) { return $null }
  $result = $Value
  $result = $result -replace '(?i)(authorization|cookie|set-cookie|api[_-]?key|access[_-]?token|refresh[_-]?token|password|secret)\s*[:=]\s*[^\s,;]+', '$1=<redacted>'
  $result = $result -replace '(?i)bearer\s+[A-Za-z0-9._~+/=-]+', 'Bearer <redacted>'
  $result = $result -replace '(?i)[A-Z]:\\[^\s;,)]+', '<path>'
  $result = $result -replace '(?i)https?://[^\s]+', '<url>'
  if ($result.Length -gt $MaxLength) { return $result.Substring(0, $MaxLength) + '...' }
  return $result
}

function Write-Utf8NoBom {
  param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$Text)
  $parent = Split-Path -Parent $Path
  if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
  }
  [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false))
}

function Write-JsonFile {
  param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)]$Value)
  Write-Utf8NoBom -Path $Path -Text ($Value | ConvertTo-Json -Depth 20)
}

function Get-ApproxTokens {
  param([long]$Bytes)
  return [int][Math]::Ceiling([double]$Bytes / 4.0)
}

function Test-SafeRegularFile {
  param([Parameter(Mandatory = $true)][string]$Path)
  try {
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    return $item.PSIsContainer -eq $false -and (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0)
  } catch { return $false }
}

function Get-SafeFiles {
  param([Parameter(Mandatory = $true)][string[]]$Roots)
  $allowedNames = @('AGENTS.md', 'CONTEXT.md', 'SKILL.md', 'package.json', 'plugin.json')
  $files = [System.Collections.Generic.List[object]]::new()
  foreach ($candidateRoot in $Roots) {
    if ([string]::IsNullOrWhiteSpace($candidateRoot)) { continue }
    if (-not (Test-Path -LiteralPath $candidateRoot -PathType Container)) { continue }
    $resolvedRoot = [IO.Path]::GetFullPath($candidateRoot)
    $items = Get-ChildItem -LiteralPath $resolvedRoot -File -Recurse -Force -ErrorAction SilentlyContinue |
      Where-Object {
        $_.FullName -notmatch '(?i)[\\/]node_modules[\\/]|[\\/]runtime[\\/]node_modules[\\/]|[\\/]\.git[\\/]|[\\/]\.dsh[\\/]' -and
        $_.FullName -notmatch '(?i)[\\/]\.env($|\.)|\.pem$|\.key$|id_rsa' -and
        ($allowedNames -contains $_.Name -or $_.Name -match '(?i)^cordis(\.|$).*\.ya?ml$|\.schema\.json$|\.skill\.md$')
      }
    foreach ($item in @($items)) {
      if (Test-SafeRegularFile -Path $item.FullName) { $files.Add($item) }
    }
  }
  return @($files | Sort-Object FullName -Unique)
}

function Invoke-ContextDoctor {
  param([string]$WorkspaceRoot, [string]$DshHomeRoot)
  $roots = [System.Collections.Generic.List[string]]::new()
  if (-not [string]::IsNullOrWhiteSpace($WorkspaceRoot)) { $roots.Add([IO.Path]::GetFullPath($WorkspaceRoot)) }
  if ($IncludeUserConfig) {
    $roots.Add((Join-Path $env:USERPROFILE '.codex'))
    $roots.Add((Join-Path $env:USERPROFILE '.agents'))
  }
  $roots.Add((Join-Path $DshHomeRoot "profiles\$Profile"))
  $files = @(Get-SafeFiles -Roots $roots.ToArray())
  $hashGroups = @{}
  $nameGroups = @{}
  $entries = @()
  foreach ($file in $files) {
    $hash = Get-ProvenanceSha256 -Path $file.FullName
    $relative = $file.FullName
    foreach ($rootItem in $roots) {
      $rootFull = [IO.Path]::GetFullPath($rootItem).TrimEnd('\')
      if ($relative.StartsWith($rootFull + '\', [StringComparison]::OrdinalIgnoreCase)) {
        $relative = $relative.Substring($rootFull.Length + 1)
        break
      }
    }
    $text = ''
    try { $text = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 } catch { $text = '' }
    $entry = [PSCustomObject]@{
      path = Get-SafeText -Value $file.FullName -MaxLength 300
      relativePath = $relative
      bytes = [long]$file.Length
      approxTokens = Get-ApproxTokens -Bytes $file.Length
      sha256 = $hash
      lineCount = if ($text.Length -eq 0) { 0 } else { @($text -split "`r?`n").Count }
    }
    $entries += $entry
    if (-not $hashGroups.ContainsKey($hash)) { $hashGroups[$hash] = @() }
    $hashGroups[$hash] += $entry.path
    if (-not $nameGroups.ContainsKey($file.Name.ToLowerInvariant())) { $nameGroups[$file.Name.ToLowerInvariant()] = @() }
    $nameGroups[$file.Name.ToLowerInvariant()] += $entry.path
  }
  $duplicates = @($hashGroups.GetEnumerator() | Where-Object { $_.Value.Count -gt 1 } | ForEach-Object {
    [PSCustomObject]@{ sha256 = $_.Key; count = $_.Value.Count; paths = @($_.Value) }
  })
  $sameName = @($nameGroups.GetEnumerator() | Where-Object { $_.Value.Count -gt 1 } | ForEach-Object {
    [PSCustomObject]@{ name = $_.Key; count = $_.Value.Count; paths = @($_.Value); severity = 'review' }
  })
  [ordered]@{
    result = 'PASS'
    action = 'context-doctor'
    readOnly = $true
    estimate = 'approximate: UTF-8 bytes divided by four; not a model tokenizer measurement'
    roots = @($roots | ForEach-Object { Get-SafeText -Value $_ -MaxLength 300 })
    files = $entries
    totalFiles = $entries.Count
    totalBytes = [long](($entries | Measure-Object -Property bytes -Sum).Sum)
    approxTokens = [int](($entries | Measure-Object -Property approxTokens -Sum).Sum)
    duplicateContent = $duplicates
    sameNameAcrossRoots = $sameName
    conflicts = @($sameName | Where-Object { $_.name -in @('agents.md', 'context.md', 'skill.md') })
    boundaries = [ordered]@{
      noFileContentsExported = $true
      noEnvContentsRead = $true
      duplicateIsNotProofOfConflict = $true
    }
  }
}

function Read-OptionalJson {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
  try { return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $null }
}

function Invoke-SecurityAudit {
  param([string]$DshHomeRoot)
  $profileRoot = Join-Path $DshHomeRoot "profiles\$Profile"
  $manifestPath = Join-Path $profileRoot 'package.json'
  $patchPath = Join-Path $profileRoot 'cordis.patch.yml'
  $manifest = Read-OptionalJson -Path $manifestPath
  $risks = [System.Collections.Generic.List[object]]::new()
  if ($null -eq $manifest) {
    $risks.Add([PSCustomObject]@{ severity = 'warning'; code = 'profile.missing'; message = 'Profile package.json was not found or could not be parsed.' })
  } else {
    foreach ($sectionName in @('dependencies', 'optionalDependencies', 'devDependencies')) {
      $section = $manifest.PSObject.Properties[$sectionName]
      if ($null -eq $section -or $null -eq $section.Value) { continue }
      foreach ($prop in @($section.Value.PSObject.Properties)) {
        $spec = [string]$prop.Value
        if ($spec -match '^(?i:link:|file:)') {
          $risks.Add([PSCustomObject]@{ severity = 'review'; code = 'dependency.local-source'; message = "Bundle $($prop.Name) uses a local link/file source." })
        }
      }
    }
  }
  if (Test-Path -LiteralPath (Join-Path $DshHomeRoot '.env') -PathType Leaf) {
    $risks.Add([PSCustomObject]@{ severity = 'sensitive'; code = 'config.env-present'; message = '.env exists; contents were not read or exported.' })
  }
  if (Test-Path -LiteralPath $patchPath -PathType Leaf) {
    $patchText = Get-Content -LiteralPath $patchPath -Raw -Encoding UTF8
    if ($patchText -match '(?i)disabled:\s*false') {
      $risks.Add([PSCustomObject]@{ severity = 'review'; code = 'patch.explicit-enable'; message = 'Profile patch contains explicit enabled entries; inspect ownership before changing it.' })
    }
    if ($patchText -match '(?i)https?://|curl\s+|Invoke-WebRequest') {
      $risks.Add([PSCustomObject]@{ severity = 'warning'; code = 'patch.network-string'; message = 'Profile patch contains a network-looking string; no request was made.' })
    }
  }
  try {
    $listeners = @(Get-NetTCPConnection -State Listen -ErrorAction Stop | Where-Object { $_.OwningProcess -in @(Get-Process -Name node -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id) })
    foreach ($listener in $listeners) {
      $address = [string]$listener.LocalAddress
      $severity = if ($address -in @('127.0.0.1', '::1')) { 'info' } else { 'warning' }
      $risks.Add([PSCustomObject]@{ severity = $severity; code = 'runtime.listener'; message = "Node listener $address`:$($listener.LocalPort) observed; process identity is not proof of DSH ownership." })
    }
  } catch {
    $risks.Add([PSCustomObject]@{ severity = 'info'; code = 'runtime.listener-unavailable'; message = 'Could not inspect TCP listeners on this Windows account.' })
  }
  [ordered]@{
    result = 'PASS'
    action = 'security-audit'
    readOnly = $true
    dshHome = Get-SafeText -Value $DshHomeRoot -MaxLength 300
    profile = $Profile
    profileManifestObserved = $null -ne $manifest
    envContentRead = $false
    secretValuesExported = $false
    risks = @($risks)
  }
}

function Get-FileFrameHealth {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [string]$DiscoveryRoot = '',
    [ValidateSet('default-root', 'explicit-file', 'explicit-root')][string]$InputMode = 'default-root'
  )
  $safeDiscoveryRoot = if ([string]::IsNullOrWhiteSpace($DiscoveryRoot)) { $null } else { Get-SafeText $DiscoveryRoot 300 }
  $item = Get-Item -LiteralPath $Path -Force
  if ($item.Length -eq 0) {
    return [PSCustomObject]@{ path = Get-SafeText $Path 300; discoveryRoot = $safeDiscoveryRoot; inputMode = $InputMode; format = 'empty'; status = 'empty'; frames = 0; malformedFrames = 0; note = 'zero-byte file' }
  }
  $bytes = [IO.File]::ReadAllBytes($Path)
  if ($bytes.Length -ge 4 -and $bytes[0] -eq 0x28 -and $bytes[1] -eq 0xB5 -and $bytes[2] -eq 0x2F -and $bytes[3] -eq 0xFD) {
    return [PSCustomObject]@{ path = Get-SafeText $Path 300; discoveryRoot = $safeDiscoveryRoot; inputMode = $InputMode; format = 'zstd'; status = 'not-decoded'; frames = $null; malformedFrames = $null; note = 'zstd magic observed; install/use a trusted decoder separately for frame-level proof' }
  }
  $text = $null
  try { $text = [Text.Encoding]::UTF8.GetString($bytes) } catch { $text = $null }
  if ($null -eq $text -or $text.IndexOf([char]0) -ge 0) {
    return [PSCustomObject]@{ path = Get-SafeText $Path 300; discoveryRoot = $safeDiscoveryRoot; inputMode = $InputMode; format = 'binary'; status = 'not-decoded'; frames = $null; malformedFrames = $null; note = 'binary session format was not decoded; not classified as corrupt' }
  }
  $lines = @($text -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
  $malformed = 0
  $lastMalformed = $false
  foreach ($line in $lines) {
    try { $null = $line | ConvertFrom-Json } catch { $malformed += 1; $lastMalformed = ($line -eq $lines[-1]) }
  }
  $status = if ($malformed -eq 0) { 'healthy' } elseif ($lastMalformed -and $malformed -eq 1) { 'torn-tail' } else { 'corrupt-frame' }
  return [PSCustomObject]@{
    path = Get-SafeText $Path 300
    discoveryRoot = $safeDiscoveryRoot
    inputMode = $InputMode
    format = 'jsonl-like'
    status = $status
    frames = $lines.Count
    malformedFrames = $malformed
    note = 'validated frame syntax only; semantic session replay was not attempted'
  }
}

function Invoke-SessionHealth {
  param([string]$DshHomeRoot)
  $roots = @()
  $inputMode = 'default-root'
  if (-not [string]::IsNullOrWhiteSpace($InputPath)) {
    $roots = @($InputPath)
    $inputMode = 'explicit-root'
  } else {
    $roots = @(
      (Join-Path $DshHomeRoot 'sessions'),
      (Join-Path $DshHomeRoot "profiles\$Profile\sessions")
    )
  }
  $files = @{}
  foreach ($candidateRoot in $roots) {
    if (Test-Path -LiteralPath $candidateRoot -PathType Leaf) {
      $resolvedFile = [IO.Path]::GetFullPath($candidateRoot)
      $key = $resolvedFile.ToLowerInvariant()
      if (-not $files.ContainsKey($key)) {
        $files[$key] = [PSCustomObject]@{ path = $resolvedFile; discoveryRoot = $null; inputMode = 'explicit-file' }
      }
      continue
    }
    if (-not (Test-Path -LiteralPath $candidateRoot -PathType Container)) { continue }
    $found = Get-ChildItem -LiteralPath $candidateRoot -File -Recurse -Force -ErrorAction SilentlyContinue |
      Where-Object { $_.FullName -notmatch '(?i)[\\/]node_modules[\\/]|[\\/]\.git[\\/]|[\\/]\.env($|\.)' -and $_.Extension -match '(?i)^\.(jsonl|ndjson|session|zst)$' } |
      Select-Object -First 5000 -ExpandProperty FullName
    foreach ($path in @($found)) {
      if (-not (Test-SafeRegularFile -Path $path)) { continue }
      $resolvedFile = [IO.Path]::GetFullPath($path)
      $key = $resolvedFile.ToLowerInvariant()
      if (-not $files.ContainsKey($key)) {
        $files[$key] = [PSCustomObject]@{ path = $resolvedFile; discoveryRoot = [IO.Path]::GetFullPath($candidateRoot); inputMode = $inputMode }
      }
    }
  }
  $observations = @($files.Values | Sort-Object path | ForEach-Object {
    Get-FileFrameHealth -Path $_.path -DiscoveryRoot ([string]$_.discoveryRoot) -InputMode $_.inputMode
  })
  [ordered]@{
    result = 'PASS'
    action = 'session-health'
    readOnly = $true
    filesScanned = $observations.Count
    observations = $observations
    discovery = [ordered]@{
      mode = $inputMode
      rootsChecked = @($roots | ForEach-Object { try { [IO.Path]::GetFullPath($_) } catch { $_ } })
      defaultExtensions = @('.jsonl', '.ndjson', '.session', '.zst')
      profileRootScanned = $false
    }
    boundaries = [ordered]@{
      zstdFramesDecoded = $false
      semanticReplay = $false
      rawSessionContentExported = $false
      notDecodedIsNotCorrupt = $true
    }
  }
}

function Get-FailureCandidates {
  param([Parameter(Mandatory = $true)][string]$Text)
  $lines = @($Text -split "`r?`n")
  $failureLines = [System.Collections.Generic.List[string]]::new()
  foreach ($line in $lines) {
    if ($line -match '(?i)(error|exception|failed|failure|timeout|timed out|denied|rejected|not found|dispatch|tool/result)') {
      $safe = Get-SafeText -Value $line -MaxLength 600
      if (-not [string]::IsNullOrWhiteSpace($safe)) { $failureLines.Add($safe) }
    }
  }
  if ($failureLines.Count -eq 0 -and -not [string]::IsNullOrWhiteSpace($Text)) {
    $failureLines.Add((Get-SafeText -Value $Text -MaxLength 600))
  }
  return @($failureLines)
}

function Invoke-FailLog {
  param([string]$StateRootPath)
  if ([string]::IsNullOrWhiteSpace($InputPath)) { throw '-InputPath is required for fail-log' }
  if (-not (Test-Path -LiteralPath $InputPath -PathType Leaf)) { throw "input does not exist: $InputPath" }
  $inputText = Get-Content -LiteralPath $InputPath -Raw -Encoding UTF8
  $candidates = @(Get-FailureCandidates -Text $inputText)
  $aggregatePath = Join-Path $StateRootPath 'failures.json'
  $aggregate = @{}
  if (Test-Path -LiteralPath $aggregatePath -PathType Leaf) {
    try {
      $existing = Get-Content -LiteralPath $aggregatePath -Raw -Encoding UTF8 | ConvertFrom-Json
      foreach ($prop in @($existing.PSObject.Properties)) { $aggregate[$prop.Name] = $prop.Value }
    } catch { $aggregate = @{} }
  }
  $newRecords = @()
  foreach ($candidate in $candidates) {
    $normalized = ($candidate -replace '\b\d+\b', '<n>' -replace '\s+', ' ').Trim().ToLowerInvariant()
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $key = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($normalized)))).Replace('-', '').ToLowerInvariant() } finally { $sha.Dispose() }
    $now = (Get-Date).ToUniversalTime().ToString('o')
    if ($aggregate.ContainsKey($key)) {
      $record = $aggregate[$key]
      $record.count = [int]$record.count + 1
      $record.lastSeen = $now
    } else {
      $record = [PSCustomObject]@{ key = $key; label = $Label; count = 1; firstSeen = $now; lastSeen = $now; sample = $candidate }
      $aggregate[$key] = $record
    }
    $newRecords += $record
  }
  Write-JsonFile -Path $aggregatePath -Value $aggregate
  [ordered]@{
    result = 'PASS'
    action = 'fail-log'
    readOnly = $false
    input = Get-SafeText -Value ([IO.Path]::GetFullPath($InputPath)) -MaxLength 300
    storedPath = Get-SafeText -Value $aggregatePath -MaxLength 300
    candidates = $candidates.Count
    uniqueRecords = $aggregate.Count
    records = $newRecords
    rawInputStored = $false
    toolArgumentsStored = $false
    toolResultsStored = $false
  }
}

try {
  $dshHomeRoot = Resolve-DshHome -Value $DshHome
  $stateRootPath = Resolve-StateRoot -Value $StateRoot
  if (-not [string]::IsNullOrWhiteSpace($Root)) { $workspaceRoot = [IO.Path]::GetFullPath($Root) } else { $workspaceRoot = (Get-Location).Path }
  $result = switch ($Action) {
    'context-doctor' { Invoke-ContextDoctor -WorkspaceRoot $workspaceRoot -DshHomeRoot $dshHomeRoot }
    'security-audit' { Invoke-SecurityAudit -DshHomeRoot $dshHomeRoot }
    'session-health' { Invoke-SessionHealth -DshHomeRoot $dshHomeRoot }
    'fail-log' { Invoke-FailLog -StateRootPath $stateRootPath }
    'provenance' { Invoke-ProvenanceContract -DshHomeRoot $dshHomeRoot -ProfileName $Profile }
    'pointer-evidence' { Invoke-PointerEvidence -InputPath $InputPath }
  }
  $result | ConvertTo-Json -Depth 20
  exit 0
} catch {
  [ordered]@{ result = 'FAIL'; action = $Action; error = Get-SafeText -Value $_.Exception.Message -MaxLength 600 } | ConvertTo-Json -Depth 12
  exit 1
}
