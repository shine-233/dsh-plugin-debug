[CmdletBinding()]
param([string]$RepositoryRoot = '')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) { Split-Path -Parent (Split-Path -Parent $PSCommandPath) } else { $RepositoryRoot }
$root = [IO.Path]::GetFullPath($root)
$packageRoot = Join-Path $root 'packages\dsh-plugin-debug'

function Assert-Publication {
  param([bool]$Condition, [string]$Message)
  if (-not $Condition) { throw $Message }
}

function Get-JsonPropertyValue {
  param(
    [AllowNull()][object]$InputObject,
    [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Name
  )
  if ($null -eq $InputObject) { return $null }
  if ($InputObject -is [System.Collections.IDictionary] -and $InputObject.Contains($Name)) {
    return $InputObject[$Name]
  }
  $property = $InputObject.PSObject.Properties[$Name]
  if ($null -eq $property) { return $null }
  return $property.Value
}

function Test-JsonPropertyPresent {
  param(
    [AllowNull()][object]$InputObject,
    [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Name
  )
  if ($null -eq $InputObject) { return $false }
  if ($InputObject -is [System.Collections.IDictionary]) { return $InputObject.Contains($Name) }
  return $null -ne $InputObject.PSObject.Properties[$Name]
}

function ConvertTo-PublicationMap {
  param([AllowNull()][object]$Value)
  if ($null -eq $Value) { return $null }
  if ($Value -is [System.Collections.IDictionary]) {
    $map = @{}
    foreach ($key in $Value.Keys) { $map[[string]$key] = ConvertTo-PublicationMap -Value $Value[$key] }
    return $map
  }
  if ($Value -is [string] -or $Value -is [ValueType]) { return $Value }
  if ($Value -is [System.Collections.IEnumerable]) {
    $items = @()
    foreach ($item in $Value) { $items += ,(ConvertTo-PublicationMap -Value $item) }
    return ,$items
  }
  $properties = @($Value.PSObject.Properties)
  if ($properties.Count -eq 0) { return $Value }
  $map = @{}
  foreach ($property in $properties) { $map[[string]$property.Name] = ConvertTo-PublicationMap -Value $property.Value }
  return $map
}

function Read-PublicationPackageLock {
  param([Parameter(Mandatory = $true)][string]$Path)
  $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
  $convert = Get-Command ConvertFrom-Json -ErrorAction Stop
  if ($convert.Parameters.ContainsKey('AsHashtable')) {
    return ($raw | ConvertFrom-Json -AsHashtable)
  }
  # Windows PowerShell 5.1 cannot parse an empty JSON property name with its
  # ConvertFrom-Json cmdlet. The inbox .NET JSON serializer can, so use it only
  # for this lockfile and project the result into ordinary maps.
  Add-Type -AssemblyName System.Web.Extensions
  $serializer = New-Object System.Web.Script.Serialization.JavaScriptSerializer
  return ConvertTo-PublicationMap -Value ($serializer.DeserializeObject($raw))
}

Assert-Publication (Test-Path -LiteralPath $packageRoot -PathType Container) 'missing single package: packages/dsh-plugin-debug'
Assert-Publication (-not (Test-Path -LiteralPath (Join-Path $root 'packages\dsh-plugin-provenance') -PathType Container)) 'legacy provenance package directory is present'
Assert-Publication (-not (Test-Path -LiteralPath (Join-Path $root 'tools\dsh-one-click') -PathType Container)) 'separate one-click component is present'
$storeDirs = @(Get-ChildItem -LiteralPath $root -Recurse -Force -Directory -Filter 'dsh-plugin-store' -ErrorAction SilentlyContinue)
Assert-Publication ($storeDirs.Count -eq 0) 'removed plugin-store directory is present'

foreach ($name in @('node_modules', 'coverage', 'logs', 'state', '.dsh', '.codex', 'sessions')) {
  $residue = @(Get-ChildItem -LiteralPath $root -Recurse -Force -Directory -Filter $name -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -notmatch '(?i)[\\/]\.git(?:[\\/]|$)' })
  Assert-Publication ($residue.Count -eq 0) "publication candidate contains forbidden directory: $name"
}
$nestedGit = @(Get-ChildItem -LiteralPath $root -Force -Directory | Where-Object { $_.Name -ne '.git' } | ForEach-Object {
  Get-ChildItem -LiteralPath $_.FullName -Recurse -Force -Directory -Filter '.git' -ErrorAction SilentlyContinue
})
Assert-Publication ($nestedGit.Count -eq 0) 'publication candidate contains a nested .git directory'

$forbiddenFiles = @(Get-ChildItem -LiteralPath $root -Recurse -Force -File | Where-Object {
  $_.Name -like '.env*' -or $_.Extension -in @('.key', '.pem', '.pfx', '.p12', '.jks', '.keystore', '.sqlite', '.sqlite3', '.db')
})
Assert-Publication ($forbiddenFiles.Count -eq 0) 'publication candidate contains a credential or local-state file'

$manifestPath = Join-Path $root 'RELEASE-MANIFEST.json'
$packageManifestPath = Join-Path $packageRoot 'package.json'
$packageLockPath = Join-Path $packageRoot 'package-lock.json'
$bundleManifestPath = Join-Path $packageRoot 'bundle-manifest.json'
$runtimeLockPath = Join-Path $packageRoot 'tools\runtime\package-lock.json'
foreach ($path in @($manifestPath, $packageManifestPath, $packageLockPath, $bundleManifestPath, $runtimeLockPath)) {
  Assert-Publication (Test-Path -LiteralPath $path -PathType Leaf) "missing JSON artifact: $path"
}
$manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
$packageManifest = Get-Content -LiteralPath $packageManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
$packageLock = Read-PublicationPackageLock -Path $packageLockPath
$bundleManifest = Get-Content -LiteralPath $bundleManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
$verification = Get-JsonPropertyValue -InputObject $manifest -Name 'verification'
$publication = Get-JsonPropertyValue -InputObject $manifest -Name 'publication'
Assert-Publication (Test-JsonPropertyPresent -InputObject $verification -Name 'publicationVerifierPassedAt') 'RELEASE-MANIFEST.json verification.publicationVerifierPassedAt is missing'
Assert-Publication (Test-JsonPropertyPresent -InputObject $verification -Name 'freshCloneVerifiedAt') 'RELEASE-MANIFEST.json verification.freshCloneVerifiedAt is missing'
$publicationVerifierPassedAt = Get-JsonPropertyValue -InputObject $verification -Name 'publicationVerifierPassedAt'
$freshCloneVerifiedAt = Get-JsonPropertyValue -InputObject $verification -Name 'freshCloneVerifiedAt'
foreach ($timestamp in @(
    [PSCustomObject]@{ Name = 'verification.publicationVerifierPassedAt'; Value = $publicationVerifierPassedAt },
    [PSCustomObject]@{ Name = 'verification.freshCloneVerifiedAt'; Value = $freshCloneVerifiedAt }
  )) {
  if ($null -eq $timestamp.Value -or [string]::IsNullOrWhiteSpace([string]$timestamp.Value)) { continue }
  # Windows PowerShell 5.1's ConvertFrom-Json materializes an ISO-8601 value
  # ending in `Z` as a DateTime(Kind=Utc).  Preserve that explicit kind instead
  # of converting it to a local-time string and accidentally rejecting a valid
  # UTC publication record.
  if ($timestamp.Value -is [DateTime]) {
    Assert-Publication (([DateTime]$timestamp.Value).Kind -eq [DateTimeKind]::Utc) "$($timestamp.Name) must be recorded in UTC"
    continue
  }
  if ($timestamp.Value -is [DateTimeOffset]) {
    Assert-Publication (([DateTimeOffset]$timestamp.Value).Offset -eq [TimeSpan]::Zero) "$($timestamp.Name) must be recorded in UTC"
    continue
  }
  $parsedTimestamp = [DateTimeOffset]::MinValue
  Assert-Publication ([DateTimeOffset]::TryParse([string]$timestamp.Value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$parsedTimestamp)) "$($timestamp.Name) is not a valid timestamp"
  Assert-Publication ($parsedTimestamp.Offset -eq [TimeSpan]::Zero) "$($timestamp.Name) must be recorded in UTC"
}
$publicationStatus = [string](Get-JsonPropertyValue -InputObject $manifest -Name 'status')
$pushPerformed = [bool](Get-JsonPropertyValue -InputObject $publication -Name 'pushPerformed')
$publishedCommit = [string](Get-JsonPropertyValue -InputObject $publication -Name 'publishedCommit')
if ($publicationStatus -ceq 'published') {
  Assert-Publication ($pushPerformed -and $publishedCommit -match '^[0-9a-f]{40}$') 'published release must record pushPerformed and a full publishedCommit'
  Assert-Publication (-not [string]::IsNullOrWhiteSpace([string]$publicationVerifierPassedAt) -and -not [string]::IsNullOrWhiteSpace([string]$freshCloneVerifiedAt)) 'published release must record both verification timestamps'
} else {
  Assert-Publication ($publicationStatus -ceq 'candidate') 'RELEASE-MANIFEST.json status must be candidate before all publication gates pass'
}
$packageName = [string]$packageManifest.name
$packageVersion = [string]$packageManifest.version
Assert-Publication ($packageName -ceq 'dsh-plugin-debug') 'package runtime ID is not dsh-plugin-debug'
Assert-Publication ($packageName -match '^[a-z0-9][a-z0-9._-]*$') "package name is not a legal unscoped npm name: $packageName"
Assert-Publication ($packageVersion -match '^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$') "package version is not valid SemVer: $packageVersion"
$repository = $packageManifest.repository
$repositoryUrl = [string]$repository.url
$repositoryUri = $null
$repositoryUrlValid = [Uri]::TryCreate($repositoryUrl, [UriKind]::Absolute, [ref]$repositoryUri)
Assert-Publication ($null -ne $repository -and [string]$repository.type -ceq 'git') 'package repository.type must be git'
Assert-Publication ($repositoryUrlValid -and $repositoryUri.Scheme -ceq 'https' -and $repositoryUri.Host -ceq 'github.com' -and $repositoryUri.AbsolutePath.Trim('/') -ne '') 'package repository.url must be an absolute GitHub HTTPS URL'
Assert-Publication ([string]$repository.directory -ceq 'packages/dsh-plugin-debug') 'package repository.directory must point to packages/dsh-plugin-debug'
$packageLockPackages = Get-JsonPropertyValue -InputObject $packageLock -Name 'packages'
$packageLockRoot = Get-JsonPropertyValue -InputObject $packageLockPackages -Name ''
$packageLockName = Get-JsonPropertyValue -InputObject $packageLock -Name 'name'
$packageLockVersion = Get-JsonPropertyValue -InputObject $packageLock -Name 'version'
$packageLockRootName = Get-JsonPropertyValue -InputObject $packageLockRoot -Name 'name'
$packageLockRootVersion = Get-JsonPropertyValue -InputObject $packageLockRoot -Name 'version'
Assert-Publication ([string]$packageLockName -ceq $packageName) 'package-lock.json top-level name does not match package.json'
Assert-Publication ([string]$packageLockVersion -ceq $packageVersion) 'package-lock.json top-level version does not match package.json'
Assert-Publication ($null -ne $packageLockRoot -and [string]$packageLockRootName -ceq $packageName) 'package-lock.json root package name does not match package.json'
Assert-Publication ($null -ne $packageLockRoot -and [string]$packageLockRootVersion -ceq $packageVersion) 'package-lock.json root package version does not match package.json'
Assert-Publication ([string]$bundleManifest.package -ceq $packageName) 'bundle-manifest.json package does not match package.json'
Assert-Publication ([string]$bundleManifest.version -ceq $packageVersion) 'bundle-manifest.json version does not match package.json'
$hotswapExport = Get-JsonPropertyValue -InputObject (Get-JsonPropertyValue -InputObject $packageManifest -Name 'exports') -Name './hotswap-check'
Assert-Publication ($null -ne $hotswapExport -and [string](Get-JsonPropertyValue -InputObject $hotswapExport -Name 'default') -ceq './lib/hotswap-check.js') 'package.json exports does not expose ./hotswap-check through lib/hotswap-check.js'
$hotswapFeature = Get-JsonPropertyValue -InputObject (Get-JsonPropertyValue -InputObject $bundleManifest -Name 'features') -Name 'pluginHotswapCapabilityCheck'
Assert-Publication ($null -ne $hotswapFeature -and [bool](Get-JsonPropertyValue -InputObject $hotswapFeature -Name 'readOnly') -and -not [bool](Get-JsonPropertyValue -InputObject $hotswapFeature -Name 'actualHotSwap')) 'bundle-manifest.json does not keep plugin_hotswap_check report-only'
$manifestComponents = @($manifest.components)
Assert-Publication ($manifestComponents.Count -gt 0) 'release manifest has no components'
$primaryComponent = $manifestComponents[0]
Assert-Publication ([string]$primaryComponent.id -ceq $packageName) 'RELEASE-MANIFEST.json components[0] is not dsh-plugin-debug'
Assert-Publication ([string]$primaryComponent.path -ceq 'packages/dsh-plugin-debug') 'RELEASE-MANIFEST.json components[0] path does not point to the package'
Assert-Publication ([string]$primaryComponent.version -ceq $packageVersion) 'RELEASE-MANIFEST.json components[0] version does not match package.json'
Assert-Publication (@($packageManifest.files) -contains 'tools') 'package files list does not include combined Host tools'
foreach ($entry in @('Start-DSH-Debug.ps1', 'Start-DSH-Debug.cmd', 'Start-DSH-Debug.vbs', 'Start-DSH-Combined.ps1', 'Start-DSH-Combined.cmd', 'Start-DSH-Combined.vbs')) {
  Assert-Publication (@($packageManifest.files) -contains $entry) "package files list omits public launcher: $entry"
}
Assert-Publication (-not (@($packageManifest.files) -contains 'Start-DSH-Provenance.ps1')) 'package files list still exposes the retired provenance launcher'
Assert-Publication (Test-Path -LiteralPath (Join-Path $packageRoot 'tools\Test-DSHProvenanceIntegration.ps1') -PathType Leaf) 'single-package integration test is missing'
Assert-Publication (@($manifest.components | ForEach-Object { $_.path }) -contains 'packages/dsh-plugin-debug') 'release manifest does not declare the single package'
Assert-Publication (-not (@($manifest.components | ForEach-Object { $_.id }) -contains 'dsh-plugin-store')) 'release manifest declares removed plugin-store as a component'
Assert-Publication ($null -ne $manifest.removedComponents -and (@($manifest.removedComponents | ForEach-Object { $_.id }) -contains 'dsh-plugin-store')) 'release manifest lacks the recorded plugin-store removal'

$requiredFunctionalFiles = @(
  'lib/index.js',
  'lib/client.js',
  'lib/hotswap-check.js',
  'lib/agent-report.js',
  'lib/repository-check.js',
  'lib/tool-adapter.js',
  'lib/task-guardian.js',
  'tools/DSH-PowerShell.ps1',
  'tools/DSH-Preflight.ps1',
  'tools/Test-DSHPreflight.ps1',
  'tools/DSH-DependencyGraph.ps1',
  'tools/Test-DSHDependencyGraph.ps1',
  'tools/DSH-Bisect.ps1',
  'tools/DSH-DiagnosticsDiff.ps1',
  'tools/DSH-TraceLoop.ps1',
  'tools/Test-DSHTraceLoop.ps1',
  'tools/DSH-TraceRecursion.ps1',
  'tools/Test-DSHTraceRecursion.ps1',
  'tools/Get-DSHGuardianStatus.ps1',
  'tools/Test-DSHGuardianStatus.ps1',
  'tools/runtime/package-lock.json'
)
$hotswapSourcePath = Join-Path $packageRoot 'src\hotswap-check.js'
$hotswapGeneratedPath = Join-Path $packageRoot 'lib\hotswap-check.js'
Assert-Publication (Test-Path -LiteralPath $hotswapSourcePath -PathType Leaf) 'hotswap source module is missing'
Assert-Publication ((Get-FileHash -LiteralPath $hotswapSourcePath -Algorithm SHA256).Hash -ceq (Get-FileHash -LiteralPath $hotswapGeneratedPath -Algorithm SHA256).Hash) 'generated hotswap module differs from its source module'
$agentReportSourcePath = Join-Path $packageRoot 'src\agent-report.js'
$agentReportGeneratedPath = Join-Path $packageRoot 'lib\agent-report.js'
Assert-Publication (Test-Path -LiteralPath $agentReportSourcePath -PathType Leaf) 'agent report source module is missing'
Assert-Publication ((Get-FileHash -LiteralPath $agentReportSourcePath -Algorithm SHA256).Hash -ceq (Get-FileHash -LiteralPath $agentReportGeneratedPath -Algorithm SHA256).Hash) 'generated agent report module differs from its source module'
$packageFileSpecs = @($packageManifest.files | ForEach-Object { ([string]$_).Replace('\', '/').TrimEnd('/') })
foreach ($requiredFile in $requiredFunctionalFiles) {
  $requiredDiskPath = Join-Path $packageRoot ($requiredFile -replace '/', '\')
  Assert-Publication (Test-Path -LiteralPath $requiredDiskPath -PathType Leaf) "required functionality file is missing: $requiredFile"
  $coveredByPackageFiles = $false
  foreach ($fileSpec in $packageFileSpecs) {
    if ($fileSpec -eq $requiredFile -or $fileSpec -eq 'tools' -or $requiredFile.StartsWith("$fileSpec/", [StringComparison]::OrdinalIgnoreCase)) {
      $coveredByPackageFiles = $true
      break
    }
  }
  Assert-Publication $coveredByPackageFiles "package.json files does not include required functionality file: $requiredFile"
}

$metadataOnlyTraceFixtures = @(
  'tools/fixtures/trace-recursion.json',
  'tools/fixtures/trace-loop.json',
  'tools/fixtures/tool-call-trace.json',
  'tools/fixtures/tool-call-baseline.json',
  'tools/fixtures/tool-call-incomplete-page.json'
)
$forbiddenTraceFixturePatterns = @(
  '(?i)"sessionId"\s*:',
  '(?i)"agentId"\s*:',
  '(?i)"token"\s*:',
  '(?i)"command"\s*:',
  '(?i)"path"\s*:',
  '(?i)"text"\s*:'
)
foreach ($relativeFixture in $metadataOnlyTraceFixtures) {
  $fixturePath = Join-Path $packageRoot ($relativeFixture -replace '/', '\')
  Assert-Publication (Test-Path -LiteralPath $fixturePath -PathType Leaf) "metadata-only Trace fixture is missing: $relativeFixture"
  $fixtureText = Get-Content -LiteralPath $fixturePath -Raw -Encoding UTF8
  foreach ($pattern in $forbiddenTraceFixturePatterns) {
    Assert-Publication ($fixtureText -notmatch $pattern) "metadata-only Trace fixture contains a forbidden raw field ($pattern): $relativeFixture"
  }
}

Assert-Publication ($null -ne (Get-Command node -ErrorAction SilentlyContinue)) 'node is required to parse package-lock.json'
& node -e 'JSON.parse(require(String.fromCharCode(102,115)).readFileSync(process.argv[1], String.fromCharCode(117,116,102,56)));' -- $runtimeLockPath
Assert-Publication ($LASTEXITCODE -eq 0) 'package-lock.json is not valid JSON'

$packJsonText = ''
Push-Location $packageRoot
try {
  $packJsonText = (& npm pack --dry-run --json --ignore-scripts 2>&1 | Out-String).Trim()
  $packExit = $LASTEXITCODE
} finally {
  Pop-Location
}
Assert-Publication ($packExit -eq 0) "npm pack --dry-run failed: $packJsonText"
try {
  $packReport = @($packJsonText | ConvertFrom-Json -ErrorAction Stop)[0]
} catch {
  throw "npm pack --dry-run did not return JSON: $packJsonText"
}
$packFileCount = @($packReport.files).Count
Assert-Publication ($packFileCount -gt 0) 'npm pack --dry-run returned no package files'
Assert-Publication ([int]$manifest.verification.packageFileCount -eq $packFileCount) "release manifest packageFileCount $($manifest.verification.packageFileCount) does not match npm pack count $packFileCount"
$packedPaths = @($packReport.files | ForEach-Object { ([string]$_.path).Replace('\', '/') })
foreach ($requiredFile in $requiredFunctionalFiles) {
  Assert-Publication ($packedPaths -contains $requiredFile) "npm pack does not include required functionality file: $requiredFile"
}
$forbiddenPackedPatterns = @(
  '(?i)(^|/)node_modules(/|$)',
  '(?i)(^|/)(state|logs|coverage)(/|$)',
  '(?i)(^|/)\.env(?:$|\.)',
  '(?i)\.(key|pem|pfx|p12|jks|keystore|sqlite|sqlite3|db)$'
)
foreach ($packedPath in $packedPaths) {
  foreach ($pattern in $forbiddenPackedPatterns) {
    Assert-Publication ($packedPath -notmatch $pattern) "npm pack includes a forbidden path ($pattern): $packedPath"
  }
}
$expectedPackedLibFiles = @(
  'lib/agent-report.js',
  'lib/client.js',
  'lib/hotswap-check.js',
  'lib/index.js',
  'lib/repository-check.js',
  'lib/task-guardian.js',
  'lib/tool-adapter.js'
)
$packedLibFiles = @($packedPaths | Where-Object { $_ -like 'lib/*' })
$missingPackedLibFiles = @($expectedPackedLibFiles | Where-Object { $packedLibFiles -notcontains $_ })
$unexpectedPackedLibFiles = @($packedLibFiles | Where-Object { $expectedPackedLibFiles -notcontains $_ })
Assert-Publication ($missingPackedLibFiles.Count -eq 0) "npm pack omits expected lib artifacts: $($missingPackedLibFiles -join ', ')"
Assert-Publication ($unexpectedPackedLibFiles.Count -eq 0) "npm pack includes unexpected lib artifacts: $($unexpectedPackedLibFiles -join ', ')"
$exports = Get-JsonPropertyValue -InputObject $packageManifest -Name 'exports'
foreach ($exportProperty in $exports.PSObject.Properties) {
  $exportValue = $exportProperty.Value
  $exportTarget = if ($exportValue -is [string]) {
    [string]$exportValue
  } else {
    [string](Get-JsonPropertyValue -InputObject $exportValue -Name 'default')
  }
  if ([string]::IsNullOrWhiteSpace($exportTarget) -or -not $exportTarget.StartsWith('./', [StringComparison]::Ordinal)) { continue }
  $exportPath = $exportTarget.Substring(2).Replace('\', '/')
  Assert-Publication ($packedPaths -contains $exportPath) "npm pack does not include export target: $($exportProperty.Name) -> $exportTarget"
}
$bundleFileProperties = (Get-JsonPropertyValue -InputObject $bundleManifest -Name 'files').PSObject.Properties
foreach ($bundleFileProperty in $bundleFileProperties) {
  Assert-Publication ($packedPaths -contains ([string]$bundleFileProperty.Name).Replace('\', '/')) "npm pack does not include bundle manifest file: $($bundleFileProperty.Name)"
}

$slash = [char]92
$unixSlash = [char]47
$absolutePathPattern = 'C:' + $slash + $slash + 'Users' + $slash + $slash + '[^' + $slash + $slash + ']+' + $slash + $slash + '(Documents|AppData)|' + $unixSlash + 'Users' + $unixSlash + '[^' + $unixSlash + ']+' + '|' + $unixSlash + 'home' + $unixSlash + '[^' + $unixSlash + ']+'
$credentialPattern = '(?i)(sk-' + '[A-Za-z0-9]{20,}|ghp_' + '[A-Za-z0-9]{20,}|github_pat_' + '[A-Za-z0-9_]{20,})'
$space = [char]32
$privateKeyPattern = 'BEGIN' + $space + '(RSA|EC|OPENSSH|DSA)' + $space + 'PRIVATE' + $space + 'KEY'
$textFiles = @(Get-ChildItem -LiteralPath $root -Recurse -Force -File | Where-Object {
  $_.FullName -notmatch '\\node_modules\\|\\.git\\|\\logs\\|\\state\\' -and $_.Extension -in @('.md', '.json', '.yml', '.yaml', '.ps1', '.psm1', '.cmd', '.vbs')
})
foreach ($file in $textFiles) {
  $content = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8
  Assert-Publication ($content -notmatch $absolutePathPattern) "developer-specific absolute path remains: $($file.FullName)"
  Assert-Publication ($content -notmatch $credentialPattern) "credential-like token remains: $($file.FullName)"
  Assert-Publication ($content -notmatch $privateKeyPattern) "private-key marker remains: $($file.FullName)"
}

$legacyActivePatterns = @('dsh-plugin-provenance', 'provenance-only', 'Start-DSH-Provenance')
# The migration manifest is an audit record and must name retired inputs; it is
# deliberately excluded from the active-runtime identity scan.
$migrationManifestPath = Join-Path $root 'MIGRATION-MANIFEST.md'
$sourceFiles = @(Get-ChildItem -LiteralPath $root -Recurse -Force -File | Where-Object {
  $_.FullName -ne $PSCommandPath -and $_.FullName -ne $migrationManifestPath -and $_.FullName -notmatch '\\node_modules\\|\\.git\\|\\logs\\|\\state\\' -and $_.Extension -in @('.md', '.json', '.yml', '.yaml', '.ps1', '.psm1', '.cmd', '.vbs', '.js', '.cjs', '.mjs')
})
foreach ($file in $sourceFiles) {
  $content = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8
  foreach ($pattern in $legacyActivePatterns) {
    Assert-Publication ($content -notmatch [regex]::Escape($pattern)) "retired active identity remains in publication source: $pattern ($($file.FullName))"
  }
}

[ordered]@{
  result = 'PASS'
  root = $root
  package = 'packages/dsh-plugin-debug'
  packageFileCount = $packFileCount
  store = 'removed'
  forbiddenDirectories = 'absent'
  sensitiveArtifacts = 'absent'
  json = 'parseable'
} | ConvertTo-Json -Depth 4
