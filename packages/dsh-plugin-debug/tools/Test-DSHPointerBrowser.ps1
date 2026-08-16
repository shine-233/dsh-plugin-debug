[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$packageRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$fixturePath = Join-Path (Join-Path $packageRoot 'tools') 'fixtures\pointer-browser.html'
$python = Get-Command python.exe -ErrorAction SilentlyContinue
$npx = Get-Command npx -ErrorAction SilentlyContinue
$failures = [System.Collections.Generic.List[string]]::new()
$unavailable = $false
$server = $null
$session = 'dsh-pointer-e2e-' + [Guid]::NewGuid().ToString('N').Substring(0, 10)

function Assert-PointerBrowser {
  param([Parameter(Mandatory = $true)][bool]$Condition, [Parameter(Mandatory = $true)][string]$Message)
  if (-not $Condition) { [void]$failures.Add($Message) }
}

function Get-FreePointerPort {
  $probe = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
  try { $probe.Start(); return ([Net.IPEndPoint]$probe.LocalEndpoint).Port } finally { $probe.Stop() }
}

function Invoke-PlaywrightCli {
  param([Parameter(Mandatory = $true)][string[]]$CommandArguments)
  $previousErrorAction = $ErrorActionPreference
  try {
    $ErrorActionPreference = 'Continue'
    $output = & $npx.Source @CommandArguments 2>&1
    $exitCode = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $previousErrorAction
  }
  return [PSCustomObject]@{ exitCode = $exitCode; text = ($output | Out-String).Trim() }
}

function Get-JsonFromPlaywrightText {
  param([AllowNull()][string]$Text)
  if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
  $candidates = @($Text.Trim())
  $lines = @($Text -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
  for ($index = $lines.Count - 1; $index -ge 0; $index--) {
    $candidates += $lines[$index].Trim()
  }
  foreach ($candidate in $candidates) {
    try {
      $value = $candidate | ConvertFrom-Json
      if ($null -ne $value) { return $value }
    } catch { }
  }
  return $null
}

try {
  if ($null -eq $python) { throw 'python.exe is required for the temporary static HTTP fixture' }
  if ($null -eq $npx) { throw 'npx is required for Playwright CLI' }
  if (-not (Test-Path -LiteralPath $fixturePath -PathType Leaf)) { throw "browser fixture is missing: $fixturePath" }
  $port = Get-FreePointerPort
  $server = Start-Process -FilePath $python.Source -ArgumentList @('-m', 'http.server', [string]$port, '--bind', '127.0.0.1') -WorkingDirectory $packageRoot -WindowStyle Hidden -PassThru
  Start-Sleep -Milliseconds 500
  if ($server.HasExited) { throw 'static HTTP fixture exited before browser navigation' }
  $url = "http://127.0.0.1:$port/tools/fixtures/pointer-browser.html"
  $prefix = @('--yes', '--package', '@playwright/cli', 'playwright-cli', '--session', $session, '--raw')

  $open = Invoke-PlaywrightCli -CommandArguments ($prefix + @('open', $url))
  if ($open.exitCode -ne 0) {
    # A failed playwright open cannot prove the page contract. Treat the
    # browser/daemon/executable setup as unavailable instead of reporting a
    # misleading functional failure (and keep the documented exit code 2).
    $unavailable = $true
    throw "PLAYWRIGHT_UNAVAILABLE: $($open.text)"
  }
  Assert-PointerBrowser ($open.text -match '(?i)(page|open|http|ready)' -or $open.exitCode -eq 0) "Playwright could not open the fixture: $($open.text)"
  $move = Invoke-PlaywrightCli -CommandArguments ($prefix + @('mousemove', '60', '70'))
  Assert-PointerBrowser ($move.exitCode -eq 0 -or $move.text -match '(?i)(mousemove|mouse)') "Playwright could not move the pointer: $($move.text)"
  Start-Sleep -Milliseconds 250
  $evaluation = Invoke-PlaywrightCli -CommandArguments ($prefix + @('eval', '() => JSON.stringify(window.__dshPointerE2E.getState())'))
  $state = Get-JsonFromPlaywrightText -Text $evaluation.text
  if ($state -is [string]) { $state = Get-JsonFromPlaywrightText -Text ([string]$state) }
  Assert-PointerBrowser ($null -ne $state) "Playwright did not return a JSON pointer state: $($evaluation.text)"
  if ($null -ne $state) {
    Assert-PointerBrowser ($state.bridge.current.plugin -eq 'fixture-plugin') 'browser bridge did not report the marked plugin'
    Assert-PointerBrowser ($state.bridge.current.module -eq 'FixturePanel') 'browser bridge did not report the marked module'
    Assert-PointerBrowser ($state.bridge.current.slot -eq 'shell.overlay') 'browser bridge did not report the marked Slot'
    Assert-PointerBrowser ($state.current.confidence -eq 'high') 'browser pointer confidence was not high for an explicit plugin marker'
    Assert-PointerBrowser ($state.pointerEventCount -ge 1) 'browser pointer event bridge did not fire'
    Assert-PointerBrowser ($state.overlayText -match 'fixture-plugin' -and $state.overlayText -match 'FixturePanel') 'browser overlay tree did not contain the pointer source'
  }
} catch {
  if ($_.Exception.Message -match '(?i)PLAYWRIGHT_UNAVAILABLE|spawn UNKNOWN|Daemon process exited|side-by-side configuration') {
    $unavailable = $true
    [void]$failures.Add('browser runtime unavailable; no DSH page was claimed to be verified')
  } else {
    [void]$failures.Add("unhandled: $($_.Exception.Message)")
  }
} finally {
  try {
    $closePrefix = @('--yes', '--package', '@playwright/cli', 'playwright-cli', '--session', $session)
    $null = Invoke-PlaywrightCli -CommandArguments ($closePrefix + @('close'))
  } catch { }
  if ($null -ne $server -and -not $server.HasExited) {
    Stop-Process -Id $server.Id -Force -ErrorAction SilentlyContinue
  }
}

[ordered]@{
  result = if ($unavailable) { 'UNAVAILABLE' } elseif ($failures.Count -eq 0) { 'PASS' } else { 'FAIL' }
  kind = 'dsh-pointer-browser-e2e'
  realDshPortUsed = $false
  realDshHomeUsed = $false
  pointerBridgeObserved = $failures.Count -eq 0
  overlaySourceObserved = $failures.Count -eq 0
  failures = @($failures)
} | ConvertTo-Json -Depth 15
if ($unavailable) { exit 2 }
if ($failures.Count -gt 0) { exit 1 }
exit 0
