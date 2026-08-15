[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$toolRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$packageRoot = Split-Path -Parent $toolRoot
$preflightScript = Join-Path $toolRoot 'DSH-Preflight.ps1'
$debugEntry = Join-Path $packageRoot 'Debug-DSH.ps1'
$provenanceEntry = Join-Path $packageRoot 'DSH-Provenance.ps1'
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('dsh-preflight-' + [guid]::NewGuid().ToString('N'))

function Assert-DshPreflight {
  param([Parameter(Mandatory = $true)][bool]$Condition, [Parameter(Mandatory = $true)][string]$Message)
  if (-not $Condition) { throw $Message }
}

function Invoke-DshPreflightJson {
  param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string[]]$Arguments)
  $raw = & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $Path @Arguments 2>&1
  $exitCode = $LASTEXITCODE
  $text = ($raw | Out-String).Trim()
  $value = $null
  try { $value = $text | ConvertFrom-Json } catch { }
  return [PSCustomObject]@{ exitCode = $exitCode; text = $text; value = $value }
}

try {
  New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
  $goodRoot = Join-Path $tempRoot 'good'
  $badRoot = Join-Path $tempRoot 'bad'
  $dynamicRoot = Join-Path $tempRoot 'dynamic'
  New-Item -ItemType Directory -Path $goodRoot,$badRoot,$dynamicRoot -Force | Out-Null

  @'
export const inject = ['tools', 'timer']
// ctx.settings in this comment and "ctx.fake" in this string are not usage.
export function apply(ctx) {
  ctx.tools.register()
  ctx.setTimeout(() => {}, 10)
  ctx.get('settings')
  sctx.settings()
}
'@ | Set-Content -LiteralPath (Join-Path $goodRoot 'index.js') -Encoding UTF8
  @'
export const inject = ['tools']
export function apply(ctx) {
  ctx.tools.register()
  ctx.settings.read()
  ctx.setInterval(() => {}, 10)
}
'@ | Set-Content -LiteralPath (Join-Path $badRoot 'index.js') -Encoding UTF8
  @'
export const inject = ['tools']
export function apply(ctx) {
  const service = 'settings'
  return ctx[service]
}
'@ | Set-Content -LiteralPath (Join-Path $dynamicRoot 'index.js') -Encoding UTF8

  $good = Invoke-DshPreflightJson -Path $preflightScript -Arguments @('-InputPath', $goodRoot)
  Assert-DshPreflight ($good.exitCode -eq 0 -and $good.value.result -eq 'PASS') "good preflight did not pass: $($good.text)"
  Assert-DshPreflight ($good.value.declaredInject -contains 'timer' -and $good.value.missingServices.Count -eq 0) 'good preflight lost declared services or reported a false missing service'
  Assert-DshPreflight ($good.value.offline -eq $true -and $good.value.networkAccessed -eq $false -and $good.value.readOnly -eq $true -and $good.value.executesPluginCode -eq $false) 'good preflight crossed its safety boundary'

  $bad = Invoke-DshPreflightJson -Path $preflightScript -Arguments @('-InputPath', $badRoot)
  Assert-DshPreflight ($bad.exitCode -eq 1 -and $bad.value.result -eq 'FAIL') 'missing inject preflight did not fail closed'
  Assert-DshPreflight ($bad.value.missingServices -contains 'settings' -and $bad.value.missingServices -contains 'timer') 'missing service set was incomplete'
  Assert-DshPreflight ($bad.text -notmatch [regex]::Escape($badRoot) -and $bad.text -notmatch 'ctx\.settings\.read') 'preflight output leaked absolute paths or source content'
  Assert-DshPreflight ($bad.value.autoDisabled -eq $false -and $bad.value.writesReport -eq $false) 'preflight unexpectedly mutated or wrote by default'

  $dynamic = Invoke-DshPreflightJson -Path $preflightScript -Arguments @('-InputPath', $dynamicRoot)
  Assert-DshPreflight ($dynamic.exitCode -eq 0 -and $dynamic.value.result -eq 'MANUAL_REVIEW' -and $dynamic.value.issueCodes -contains 'DYNAMIC_CONTEXT_ACCESS') 'dynamic context access did not require manual review'
  Assert-DshPreflight ($dynamic.text -notmatch '\bctx\s*\[') 'manual review output exposed dynamic source syntax'

  $debug = Invoke-DshPreflightJson -Path $debugEntry -Arguments @('-Action', 'plugin-preflight', '-InputPath', $badRoot)
  Assert-DshPreflight ($debug.exitCode -eq 1 -and $debug.value.kind -eq 'dsh-plugin-preflight' -and $debug.value.result -eq 'FAIL') 'Debug-DSH preflight forwarding failed'
  $provenance = Invoke-DshPreflightJson -Path $provenanceEntry -Arguments @('-Action', 'plugin-preflight', '-InputPath', $goodRoot)
  Assert-DshPreflight ($provenance.exitCode -eq 0 -and $provenance.value.kind -eq 'dsh-plugin-preflight' -and $provenance.value.result -eq 'PASS') 'DSH-Provenance preflight forwarding failed'

  [ordered]@{
    result = 'PASS'
    kind = 'dsh-plugin-preflight-test'
    offline = $true
    networkAccessed = $false
    metadataOnly = $true
    goodResult = $good.value.result
    missingServices = @($bad.value.missingServices)
    dynamicResult = $dynamic.value.result
    forwarding = [ordered]@{ debug = $debug.value.result; provenance = $provenance.value.result }
  } | ConvertTo-Json -Depth 15
  exit 0
} catch {
  [ordered]@{ result = 'FAIL'; kind = 'dsh-plugin-preflight-test'; offline = $true; networkAccessed = $false; error = $_.Exception.Message } | ConvertTo-Json -Depth 12
  exit 1
} finally {
  if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
}
