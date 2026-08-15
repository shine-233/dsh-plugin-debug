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
$bundleManifestPath = Join-Path $packageRoot 'bundle-manifest.json'
$runtimeLockPath = Join-Path $packageRoot 'tools\runtime\package-lock.json'
foreach ($path in @($manifestPath, $packageManifestPath, $bundleManifestPath, $runtimeLockPath)) {
  Assert-Publication (Test-Path -LiteralPath $path -PathType Leaf) "missing JSON artifact: $path"
}
$manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
$packageManifest = Get-Content -LiteralPath $packageManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
Get-Content -LiteralPath $bundleManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json | Out-Null
Assert-Publication ([string]($packageManifest.name) -ceq 'dsh-plugin-debug') 'package runtime ID is not dsh-plugin-debug'
Assert-Publication (@($packageManifest.files) -contains 'tools') 'package files list does not include combined Host tools'
foreach ($entry in @('Start-DSH-Debug.ps1', 'Start-DSH-Debug.cmd', 'Start-DSH-Debug.vbs', 'Start-DSH-Combined.ps1', 'Start-DSH-Combined.cmd', 'Start-DSH-Combined.vbs')) {
  Assert-Publication (@($packageManifest.files) -contains $entry) "package files list omits public launcher: $entry"
}
Assert-Publication (-not (@($packageManifest.files) -contains 'Start-DSH-Provenance.ps1')) 'package files list still exposes the retired provenance launcher'
Assert-Publication (Test-Path -LiteralPath (Join-Path $packageRoot 'tools\Test-DSHProvenanceIntegration.ps1') -PathType Leaf) 'single-package integration test is missing'
Assert-Publication (@($manifest.components | ForEach-Object { $_.path }) -contains 'packages/dsh-plugin-debug') 'release manifest does not declare the single package'
Assert-Publication (-not (@($manifest.components | ForEach-Object { $_.id }) -contains 'dsh-plugin-store')) 'release manifest declares removed plugin-store as a component'
Assert-Publication ($null -ne $manifest.removedComponents -and (@($manifest.removedComponents | ForEach-Object { $_.id }) -contains 'dsh-plugin-store')) 'release manifest lacks the recorded plugin-store removal'

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
