[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$toolRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$packageRoot = Split-Path -Parent $toolRoot
$graphScript = Join-Path $toolRoot 'DSH-DependencyGraph.ps1'
$debugEntry = Join-Path $packageRoot 'Debug-DSH.ps1'
$provenanceEntry = Join-Path $packageRoot 'DSH-Provenance.ps1'
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('dsh-dependency-graph-' + [guid]::NewGuid().ToString('N'))

function Assert-DshDependencyGraph {
  param([Parameter(Mandatory = $true)][bool]$Condition, [Parameter(Mandatory = $true)][string]$Message)
  if (-not $Condition) { throw $Message }
}

function Invoke-DshDependencyGraphJson {
  param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string[]]$Arguments)
  $previousErrorAction = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $raw = & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $Path @Arguments 2>&1
  } finally {
    $ErrorActionPreference = $previousErrorAction
  }
  $exitCode = $LASTEXITCODE
  $text = ($raw | Out-String).Trim()
  $value = $null
  try { $value = $text | ConvertFrom-Json } catch { }
  return [PSCustomObject]@{ exitCode = $exitCode; text = $text; value = $value }
}

function Write-DshDependencyManifest {
  param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)]$Value)
  $Value | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $Path -Encoding UTF8
}

try {
  New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
  $goodInputPath = Join-Path $tempRoot 'good.json'
  $badInputPath = Join-Path $tempRoot 'bad.json'
  Write-DshDependencyManifest -Path $goodInputPath -Value ([ordered]@{
    manifest = [ordered]@{
      name = 'fixture-profile'
      version = '1.0.0'
      dependencies = [ordered]@{ 'good-a' = '1.0.0'; '@deepseek-ai/dsh-tools' = '0.1.0-rc.6' }
    }
    packages = [ordered]@{
      'good-a' = [ordered]@{ name = 'good-a'; version = '1.0.0' }
      '@deepseek-ai/dsh-tools' = [ordered]@{ name = '@deepseek-ai/dsh-tools'; version = '0.1.0-rc.6' }
    }
  })
  Write-DshDependencyManifest -Path $badInputPath -Value ([ordered]@{
    manifest = [ordered]@{
      name = 'fixture-profile-bad'
      version = '1.0.0'
      dependencies = [ordered]@{ 'cycle-a' = '1.0.0'; 'missing-package' = '1.0.0' }
    }
    packages = [ordered]@{
      'cycle-a' = [ordered]@{ name = 'cycle-a'; version = '1.0.0'; dependencies = [ordered]@{ 'cycle-b' = '1.0.0' } }
      'cycle-b' = [ordered]@{ name = 'cycle-b'; version = '1.0.0'; dependencies = [ordered]@{ 'cycle-a' = '1.0.0' } }
      'orphan-package' = [ordered]@{ name = 'orphan-package'; version = '1.0.0' }
    }
  })

  $goodHashBefore = (Get-FileHash -LiteralPath $goodInputPath -Algorithm SHA256).Hash
  $good = Invoke-DshDependencyGraphJson -Path $graphScript -Arguments @('-InputPath', $goodInputPath)
  $goodHashAfter = (Get-FileHash -LiteralPath $goodInputPath -Algorithm SHA256).Hash
  Assert-DshDependencyGraph ($good.exitCode -eq 0 -and $good.value.result -eq 'PASS') "good dependency graph did not pass: $($good.text)"
  Assert-DshDependencyGraph ($good.value.summary.nodeCount -eq 3 -and $good.value.summary.missingCount -eq 0 -and $good.value.summary.protectedCoreCount -eq 1) 'good dependency graph summary was incorrect'
  Assert-DshDependencyGraph ($good.value.offline -eq $true -and $good.value.networkAccessed -eq $false -and $good.value.readOnly -eq $true -and $good.value.safety.commandsExecuted -eq $false -and $good.value.safety.pluginsExecuted -eq $false) 'dependency graph crossed its offline/read-only boundary'
  Assert-DshDependencyGraph ($goodHashBefore -eq $goodHashAfter -and $good.text -notmatch [regex]::Escape($tempRoot)) 'dependency graph mutated or exposed an absolute path'

  $bad = Invoke-DshDependencyGraphJson -Path $graphScript -Arguments @('-InputPath', $badInputPath)
  Assert-DshDependencyGraph ($bad.exitCode -eq 1 -and $bad.value.result -eq 'FAIL') 'bad dependency graph did not fail closed on dependency findings'
  Assert-DshDependencyGraph ($bad.value.issueCodes -contains 'MISSING_DEPENDENCY' -and $bad.value.issueCodes -contains 'DEPENDENCY_CYCLE' -and $bad.value.issueCodes -contains 'UNREFERENCED_LOCAL_PACKAGE') 'dependency graph issue codes were incomplete'
  Assert-DshDependencyGraph ([int]$bad.value.summary.missingCount -eq 1 -and [int]$bad.value.summary.cycleCount -ge 1 -and [int]$bad.value.summary.unreferencedCount -eq 1) 'dependency graph missed a missing package, cycle, or orphan'
  Assert-DshDependencyGraph (@($bad.value.cycles).Count -ge 1 -and @($bad.value.missing | Where-Object { $_.to -eq 'missing-package' }).Count -eq 1) 'dependency graph evidence was incomplete'

  $debug = Invoke-DshDependencyGraphJson -Path $debugEntry -Arguments @('-Action', 'plugin-dependency-graph', '-InputPath', $goodInputPath)
  Assert-DshDependencyGraph ($debug.exitCode -eq 0 -and $debug.value.kind -eq 'dsh-plugin-dependency-graph' -and $debug.value.result -eq 'PASS') 'Debug-DSH dependency graph forwarding failed'
  $provenance = Invoke-DshDependencyGraphJson -Path $provenanceEntry -Arguments @('-Action', 'plugin-dependency-graph', '-InputPath', $goodInputPath)
  Assert-DshDependencyGraph ($provenance.exitCode -eq 0 -and $provenance.value.kind -eq 'dsh-plugin-dependency-graph' -and $provenance.value.result -eq 'PASS') 'DSH-Provenance dependency graph forwarding failed'

  [ordered]@{
    result = 'PASS'
    kind = 'dsh-plugin-dependency-graph-test'
    offline = $true
    networkAccessed = $false
    metadataOnly = $true
    goodNodes = [int]$good.value.summary.nodeCount
    badCycles = [int]$bad.value.summary.cycleCount
    badMissing = [int]$bad.value.summary.missingCount
    forwarding = [ordered]@{ debug = $debug.value.result; provenance = $provenance.value.result }
  } | ConvertTo-Json -Depth 15
  exit 0
} catch {
  [ordered]@{ result = 'FAIL'; kind = 'dsh-plugin-dependency-graph-test'; offline = $true; networkAccessed = $false; error = $_.Exception.Message } | ConvertTo-Json -Depth 12
  exit 1
} finally {
  if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
}
