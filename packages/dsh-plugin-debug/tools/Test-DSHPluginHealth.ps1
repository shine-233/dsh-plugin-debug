[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path

function Assert-Health {
  param([bool]$Condition, [string]$Message)
  if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
}

$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('dsh-plugin-health-' + [guid]::NewGuid().ToString('N'))
$dshHome = Join-Path $fixtureRoot 'home'
$profile = 'health-fixture'
$profileRoot = Join-Path $dshHome "profiles\$profile"
$modulesRoot = Join-Path $profileRoot 'node_modules'
$runtimeRoot = Join-Path $fixtureRoot 'runtime'
$runtimeModulesRoot = Join-Path $runtimeRoot 'node_modules'
$healthScript = Join-Path $root 'Get-DSH-PluginHealth.ps1'

try {
  New-Item -ItemType Directory -Path $modulesRoot -Force | Out-Null
  $manifest = [ordered]@{
    name = $profile
    dependencies = [ordered]@{
      'dsh-health-a' = 'link:dsh-health-a'
      'dsh-health-b' = 'link:dsh-health-b'
      'dsh-health-runtime' = 'link:dsh-health-runtime'
    }
    dsh = [ordered]@{ profile = [ordered]@{ bundles = @('dsh-health-a', 'dsh-health-b', 'dsh-health-runtime', 'dsh-health-missing') } }
  }
  $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
  [IO.File]::WriteAllText((Join-Path $profileRoot 'package.json'), ($manifest | ConvertTo-Json -Depth 10), $utf8NoBom)
  foreach ($name in @('dsh-health-a', 'dsh-health-b')) {
    $packageRoot = Join-Path $modulesRoot $name
    New-Item -ItemType Directory -Path $packageRoot -Force | Out-Null
    $package = [ordered]@{
      name = $name
      version = '0.0.1'
      dsh = [ordered]@{ bundle = [ordered]@{ patch = './cordis.patch.yml' } }
      scripts = [ordered]@{ prepare = 'node build.js' }
    }
    [IO.File]::WriteAllText((Join-Path $packageRoot 'package.json'), ($package | ConvertTo-Json -Depth 10), $utf8NoBom)
    $patchText = if ($name -eq 'dsh-health-a') { "- id: shared-third-party`n- id: only-a`n" } else { "- id: shared-third-party`n" }
    [IO.File]::WriteAllText((Join-Path $packageRoot 'cordis.patch.yml'), $patchText, $utf8NoBom)
  }
  $runtimePackageRoot = Join-Path $runtimeModulesRoot 'dsh-health-runtime'
  New-Item -ItemType Directory -Path $runtimePackageRoot -Force | Out-Null
  $runtimePackage = [ordered]@{
    name = 'dsh-health-runtime'
    version = '0.0.1'
    dsh = [ordered]@{ bundle = [ordered]@{ patch = './cordis.patch.yml' } }
  }
  [IO.File]::WriteAllText((Join-Path $runtimePackageRoot 'package.json'), ($runtimePackage | ConvertTo-Json -Depth 10), $utf8NoBom)
  [IO.File]::WriteAllText((Join-Path $runtimePackageRoot 'cordis.patch.yml'), "- id: runtime-only`n", $utf8NoBom)

  $raw = (& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $healthScript -Profile $profile -DshHome $dshHome -RuntimeRoot $runtimeRoot -SkipApi | Out-String)
  $report = $raw | ConvertFrom-Json
  Assert-Health ($report.summary.errorCount -eq 1) 'missing bundle should be an error'
  Assert-Health (@($report.findings | Where-Object { $_.code -eq 'patch.duplicate-id' }).Count -eq 1) 'third-party duplicate patch id should be reported'
  Assert-Health (@($report.findings | Where-Object { $_.code -eq 'build.install-hook' }).Count -eq 2) 'install-time build hooks should be reported'
  Assert-Health ($report.summary.healthy -eq $false) 'a missing bundle should make the report unhealthy'
  Assert-Health (@($report.static.bundles | Where-Object { $_.id -eq 'dsh-health-runtime' }).Count -eq 1) 'explicit runtime root bundle was not resolved'
  Assert-Health (@($report.static.runtimeRootsChecked | Where-Object { $_ -eq [IO.Path]::GetFullPath($runtimeRoot) }).Count -eq 1) 'health report did not record the explicit runtime root'

  [PSCustomObject]@{
    result = 'PASS'
    errors = $report.summary.errorCount
    warnings = $report.summary.warningCount
    duplicatePatchFinding = $true
    installHookFindings = 2
  }
} finally {
  if (Test-Path -LiteralPath $fixtureRoot -PathType Container) {
    Remove-Item -LiteralPath $fixtureRoot -Recurse -Force
  }
}
