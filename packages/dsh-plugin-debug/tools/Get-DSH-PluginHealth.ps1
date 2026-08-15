[CmdletBinding()]
param(
  [string]$Profile = 'debug',
  [string]$DshHome = '',
  [string]$BaseUrl = '',
  [int]$Port = 3081,
  [string]$RuntimeRoot = '',
  [switch]$SkipApi
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $root 'DSH-Guard.psm1') -Force

function Add-HealthFinding {
  param(
    [Parameter(Mandatory = $true)][AllowEmptyCollection()][System.Collections.Generic.List[object]]$Findings,
    [Parameter(Mandatory = $true)][ValidateSet('error', 'warning', 'info')][string]$Severity,
    [Parameter(Mandatory = $true)][string]$Code,
    [Parameter(Mandatory = $true)][string]$Message,
    [string]$Evidence = ''
  )
  $Findings.Add([PSCustomObject]@{
    severity = $Severity
    code = $Code
    message = $Message
    evidence = if ([string]::IsNullOrWhiteSpace($Evidence)) { $null } else { $Evidence }
  })
}

function Resolve-HealthHome {
  param([string]$DshHome)
  if ([string]::IsNullOrWhiteSpace($DshHome)) {
    $DshHome = if ([string]::IsNullOrWhiteSpace($env:DSH_HOME)) { Join-Path $env:USERPROFILE '.dsh' } else { $env:DSH_HOME }
  }
  return [IO.Path]::GetFullPath($DshHome)
}

function Read-HealthJson {
  param([Parameter(Mandatory = $true)][string]$Path)
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
  try { return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json }
  catch { throw "invalid JSON: $Path; $($_.Exception.Message)" }
}

function Get-HealthRuntimeRoots {
  param([string]$ExplicitRuntimeRoot)
  $candidates = [System.Collections.Generic.List[string]]::new()
  if (-not [string]::IsNullOrWhiteSpace($ExplicitRuntimeRoot)) {
    $candidates.Add($ExplicitRuntimeRoot)
  }

  $packageRoot = Split-Path -Parent $root
  $projectsRoot = Split-Path -Parent $packageRoot
  foreach ($candidate in @(
      (Join-Path $root 'runtime'),
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

function Get-HealthPackageRoot {
  param(
    [Parameter(Mandatory = $true)][string]$DshHome,
    [Parameter(Mandatory = $true)][string]$Bundle,
    [AllowEmptyCollection()][string[]]$RuntimeRoots = @()
  )
  $relative = $Bundle.Replace('/', '\')
  $candidates = [System.Collections.Generic.List[string]]::new()
  $candidates.Add((Join-Path $DshHome "profiles\$Profile\node_modules\$relative"))
  foreach ($runtimeRoot in @($RuntimeRoots)) {
    if (-not [string]::IsNullOrWhiteSpace($runtimeRoot)) {
      $candidates.Add((Join-Path $runtimeRoot "node_modules\$relative"))
    }
  }
  foreach ($candidate in @($candidates)) {
    if (Test-Path -LiteralPath $candidate -PathType Container) { return [IO.Path]::GetFullPath($candidate) }
  }
  return $null
}

function Get-HealthPatchIds {
  param([Parameter(Mandatory = $true)][string]$Text)
  $ids = @()
  foreach ($match in [regex]::Matches($Text, '(?m)^\s*-\s+id:\s*["'']?([^"''\s]+)')) {
    $ids += [string]$match.Groups[1].Value
  }
  return @($ids)
}

try {
  $findings = [System.Collections.Generic.List[object]]::new()
  $dshHomeResolved = Resolve-HealthHome -DshHome $DshHome
  $runtimeRootsChecked = @(Get-HealthRuntimeRoots -ExplicitRuntimeRoot $RuntimeRoot)
  $manifestPath = Join-Path $dshHomeResolved "profiles\$Profile\package.json"
  $manifest = $null
  try {
    $manifest = Read-HealthJson -Path $manifestPath
    if ($null -eq $manifest) {
      Add-HealthFinding -Findings $findings -Severity error -Code 'manifest.missing' -Message 'Profile package.json does not exist.' -Evidence $manifestPath
    }
  } catch {
    Add-HealthFinding -Findings $findings -Severity error -Code 'manifest.invalid-json' -Message 'Profile package.json cannot be parsed.' -Evidence $_.Exception.Message
  }

  $bundleRows = @()
  $patchIdOwners = @{}
  $bundleNames = @()
  if ($null -ne $manifest) {
    $bundles = @($manifest.dsh.profile.bundles)
    if ($bundles.Count -eq 0) {
      Add-HealthFinding -Findings $findings -Severity warning -Code 'profile.no-bundles' -Message 'Profile declares no DSH bundles.' -Evidence $manifestPath
    }
    foreach ($bundle in $bundles) {
      $bundleName = [string]$bundle
      if ([string]::IsNullOrWhiteSpace($bundleName)) { continue }
      if ($bundleNames -contains $bundleName) {
        Add-HealthFinding -Findings $findings -Severity error -Code 'profile.duplicate-bundle' -Message "Profile lists bundle more than once: $bundleName" -Evidence $manifestPath
      }
      $bundleNames += $bundleName
      $packageRoot = Get-HealthPackageRoot -DshHome $dshHomeResolved -Bundle $bundleName -RuntimeRoots $runtimeRootsChecked
      if ($null -eq $packageRoot) {
        Add-HealthFinding -Findings $findings -Severity error -Code 'bundle.missing' -Message "Bundle cannot be resolved: $bundleName" -Evidence ("profile node_modules and runtime roots were checked: " + ($runtimeRootsChecked -join '; '))
        continue
      }
      $packagePath = Join-Path $packageRoot 'package.json'
      $package = $null
      try { $package = Read-HealthJson -Path $packagePath }
      catch { Add-HealthFinding -Findings $findings -Severity error -Code 'bundle.package-invalid' -Message "Bundle package.json cannot be parsed: $bundleName" -Evidence $_.Exception.Message; continue }
      $patchRelative = $null
      if ($null -ne $package.dsh -and $null -ne $package.dsh.bundle) { $patchRelative = [string]$package.dsh.bundle.patch }
      if ([string]::IsNullOrWhiteSpace($patchRelative)) {
        Add-HealthFinding -Findings $findings -Severity info -Code 'bundle.no-patch-manifest' -Message "Bundle does not declare dsh.bundle.patch: $bundleName" -Evidence $packagePath
        continue
      }
      $patchPath = Join-Path $packageRoot $patchRelative
      if (-not (Test-Path -LiteralPath $patchPath -PathType Leaf)) {
        Add-HealthFinding -Findings $findings -Severity error -Code 'bundle.patch-missing' -Message "Bundle patch file is missing: $bundleName" -Evidence $patchPath
        continue
      }
      $patchText = Get-Content -LiteralPath $patchPath -Raw -Encoding UTF8
      $ids = @(Get-HealthPatchIds -Text $patchText)
      foreach ($id in $ids) {
        if ($patchIdOwners.ContainsKey($id)) {
          $previous = [string]$patchIdOwners[$id]
          $sharedCoreId = $previous -match '(^|; )@deepseek-ai/' -and $bundleName -match '^@deepseek-ai/'
          $duplicateSeverity = if ($sharedCoreId) { 'info' } else { 'warning' }
          $duplicateCode = if ($sharedCoreId) { 'patch.shared-core-id' } else { 'patch.duplicate-id' }
          $duplicateMessage = if ($sharedCoreId) { "Core bundles share a patch id; this may be intentional and is not treated as a confirmed conflict: $id" } else { "Patch id is declared by multiple bundles: $id" }
          Add-HealthFinding -Findings $findings -Severity $duplicateSeverity -Code $duplicateCode -Message $duplicateMessage -Evidence "$previous; $bundleName"
        } else {
          $patchIdOwners[$id] = $bundleName
        }
      }
      $scripts = @()
      $scriptsProperty = $package.PSObject.Properties['scripts']
      if ($null -ne $scriptsProperty -and $null -ne $scriptsProperty.Value) { $scripts = @($scriptsProperty.Value.PSObject.Properties.Name) }
      if ($scripts -contains 'prepare' -or $scripts -contains 'prepublishOnly') {
        Add-HealthFinding -Findings $findings -Severity warning -Code 'build.install-hook' -Message "Bundle has an install-time build hook; a source install may execute it: $bundleName" -Evidence (($scripts | Where-Object { $_ -in @('prepare', 'prepublishOnly') }) -join ', ')
      }
      $bundleRows += [PSCustomObject]@{
        id = $bundleName
        packageRoot = $packageRoot
        packageName = [string]$package.name
        patch = $patchPath
        patchIds = $ids
        installHooks = @($scripts | Where-Object { $_ -in @('prepare', 'prepublishOnly') })
      }
    }
  }

  $inventory = @()
  $apiError = $null
  if (-not $SkipApi) {
    if ([string]::IsNullOrWhiteSpace($BaseUrl)) { $BaseUrl = "http://127.0.0.1:$Port/" }
    try { $inventory = @(Get-DshPluginInventory -BaseUrl $BaseUrl -TimeoutSec 4) }
    catch { $apiError = $_.Exception.Message; Add-HealthFinding -Findings $findings -Severity info -Code 'runtime.inventory-unavailable' -Message 'Runtime inventory was not available; static checks still completed.' -Evidence $apiError }
  }
  foreach ($entry in @($inventory | Where-Object { $_.fiberPhase -eq 'failed' })) {
    Add-HealthFinding -Findings $findings -Severity error -Code 'runtime.failed-plugin' -Message "Runtime reports a failed plugin/module: $([string]$entry.moduleName)" -Evidence "entryId=$([string]$entry.entryId); fiberPhase=$([string]$entry.fiberPhase)"
  }
  $duplicateRuntimeNames = @($inventory | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.moduleName) } | Group-Object moduleName | Where-Object { $_.Count -gt 1 })
  foreach ($group in $duplicateRuntimeNames) {
    Add-HealthFinding -Findings $findings -Severity warning -Code 'runtime.duplicate-module' -Message "Runtime inventory contains duplicate module names: $($group.Name)" -Evidence "count=$($group.Count)"
  }

  $errorCount = @($findings | Where-Object { $_.severity -eq 'error' }).Count
  $warningCount = @($findings | Where-Object { $_.severity -eq 'warning' }).Count
  $infoCount = @($findings | Where-Object { $_.severity -eq 'info' }).Count
  $result = if ($errorCount -gt 0) { 'FAIL' } elseif ($warningCount -gt 0 -or $infoCount -gt 0) { 'PARTIAL' } else { 'PASS' }
  [ordered]@{
    result = $result
    schemaVersion = 1
    generatedAt = (Get-Date).ToUniversalTime().ToString('o')
    profile = $Profile
    dshHome = $dshHomeResolved
    manifest = $manifestPath
    summary = [ordered]@{ errorCount = $errorCount; warningCount = $warningCount; infoCount = $infoCount; healthy = $errorCount -eq 0 }
    static = [ordered]@{ bundles = $bundleRows; uniquePatchIds = @($patchIdOwners.Keys | Sort-Object); runtimeRootsChecked = $runtimeRootsChecked; apiSkipped = [bool]$SkipApi }
    runtime = [ordered]@{ inventoryObserved = $inventory.Count -gt 0; inventoryCount = $inventory.Count; apiError = $apiError }
    apiObserved = -not [bool]$SkipApi -and $null -eq $apiError
    findings = @($findings)
    privacy = 'Read-only report. It does not read .env contents, Tool arguments/results, cookies, tokens, or authorization headers.'
  } | ConvertTo-Json -Depth 20
  exit $(if ($result -eq 'FAIL') { 1 } else { 0 })
} catch {
  [ordered]@{ result = 'FAIL'; error = $_.Exception.Message } | ConvertTo-Json -Depth 12
  exit 1
}
