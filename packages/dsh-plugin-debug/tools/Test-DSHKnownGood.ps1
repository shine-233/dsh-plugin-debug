[CmdletBinding()]
param(
  [switch]$Server,
  [int]$ServerPort = 0,
  [string]$ReadyPath = '',
  [string]$StopPath = '',
  [switch]$KeepTemp
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'DSH-PowerShell.ps1')

function Read-KnownGoodHttpRequest {
  param([Parameter(Mandatory = $true)][Net.Sockets.TcpClient]$Client)

  $stream = $Client.GetStream()
  $stream.ReadTimeout = 5000
  $received = [System.Collections.Generic.List[byte]]::new()
  $buffer = New-Object byte[] 4096
  $headerEnd = -1
  while ($headerEnd -lt 0 -and $received.Count -lt 65536) {
    $count = $stream.Read($buffer, 0, $buffer.Length)
    if ($count -le 0) { break }
    for ($index = 0; $index -lt $count; $index++) { [void]$received.Add($buffer[$index]) }
    $headerText = [Text.Encoding]::ASCII.GetString($received.ToArray())
    $headerEnd = $headerText.IndexOf("`r`n`r`n", [StringComparison]::Ordinal)
  }
  if ($headerEnd -lt 0) { throw 'known-good fixture received an incomplete HTTP header' }

  $headerBlock = [Text.Encoding]::ASCII.GetString($received.ToArray(), 0, $headerEnd)
  $lines = @($headerBlock -split "`r`n")
  $requestParts = @($lines[0] -split ' ', 3)
  $contentLength = 0
  foreach ($line in @($lines | Select-Object -Skip 1)) {
    $separator = $line.IndexOf(':')
    if ($separator -gt 0 -and $line.Substring(0, $separator).Trim() -ieq 'Content-Length') {
      $parsedLength = 0
      if ([int]::TryParse($line.Substring($separator + 1).Trim(), [ref]$parsedLength) -and $parsedLength -ge 0) {
        $contentLength = $parsedLength
      }
    }
  }
  $bodyStart = $headerEnd + 4
  $requiredBytes = $bodyStart + $contentLength
  while ($received.Count -lt $requiredBytes) {
    $count = $stream.Read($buffer, 0, $buffer.Length)
    if ($count -le 0) { break }
    for ($index = 0; $index -lt $count; $index++) { [void]$received.Add($buffer[$index]) }
  }
  $body = if ($contentLength -gt 0 -and $received.Count -ge $requiredBytes) {
    [Text.Encoding]::UTF8.GetString($received.ToArray(), $bodyStart, $contentLength)
  } else { '' }

  [PSCustomObject]@{
    Method = if ($requestParts.Count -gt 0) { [string]$requestParts[0] } else { '' }
    Path = if ($requestParts.Count -gt 1) { [string]$requestParts[1] } else { '' }
    Body = $body
  }
}

function Write-KnownGoodResponse {
  param(
    [Parameter(Mandatory = $true)][Net.Sockets.TcpClient]$Client,
    [Parameter(Mandatory = $true)][string]$Text,
    [string]$ContentType = 'text/html; charset=utf-8',
    [int]$StatusCode = 200,
    [string]$StatusText = 'OK'
  )
  $bodyBytes = [Text.Encoding]::UTF8.GetBytes($Text)
  $headerText = "HTTP/1.1 $StatusCode $StatusText`r`nContent-Type: $ContentType`r`nContent-Length: $($bodyBytes.Length)`r`nConnection: close`r`n`r`n"
  $headerBytes = [Text.Encoding]::ASCII.GetBytes($headerText)
  $stream = $Client.GetStream()
  try {
    $stream.Write($headerBytes, 0, $headerBytes.Length)
    $stream.Write($bodyBytes, 0, $bodyBytes.Length)
    $stream.Flush()
  } finally {
    $Client.Close()
  }
}

function Start-KnownGoodServer {
  param(
    [Parameter(Mandatory = $true)][int]$Port,
    [Parameter(Mandatory = $true)][string]$ReadyFile,
    [Parameter(Mandatory = $true)][string]$StopFile
  )
  # Use a raw loopback TCP listener so this fixture does not require a
  # machine-level HTTP.sys URL ACL. It is intentionally only a tiny local
  # HTTP server for the test contract; it is not production HTTP code.
  $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, $Port)
  try {
    $listener.Start()
    [ordered]@{ result = 'READY'; port = $Port } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $ReadyFile -Encoding UTF8
    while (-not (Test-Path -LiteralPath $StopFile -PathType Leaf)) {
      if (-not $listener.Pending()) {
        Start-Sleep -Milliseconds 50
        continue
      }
      $client = $listener.AcceptTcpClient()
      try {
        $request = Read-KnownGoodHttpRequest -Client $client
        if ($request.Method -eq 'GET') {
          Write-KnownGoodResponse -Client $client -Text '<html><body>DSH fixture ready</body></html>'
        } else {
          $payload = @{ result = @{ ok = $true; value = @{ entries = @(@{ entryId = 'fixture-plugin'; moduleName = 'fixture-plugin'; enabled = $false; fiberPhase = 'failed' }) } } } | ConvertTo-Json -Depth 12 -Compress
          Write-KnownGoodResponse -Client $client -Text $payload -ContentType 'application/json; charset=utf-8'
        }
      } catch {
        try { Write-KnownGoodResponse -Client $client -Text '{"error":"bad fixture request"}' -ContentType 'application/json; charset=utf-8' -StatusCode 400 -StatusText 'Bad Request' } catch { }
      } finally {
        $client.Close()
      }
    }
  } finally {
    $listener.Stop()
  }
}

if ($Server) {
  Start-KnownGoodServer -Port $ServerPort -ReadyFile $ReadyPath -StopFile $StopPath
  exit 0
}

$toolRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $toolRoot 'DSH-KnownGood.psm1') -Force
$failures = [System.Collections.Generic.List[string]]::new()
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('dsh-known-good-' + [Guid]::NewGuid().ToString('N'))
$dshHome = Join-Path $tempRoot 'dsh-home'
$profileRoot = Join-Path (Join-Path $dshHome 'profiles') 'fixture'
$checkpointRoot = Join-Path $tempRoot 'checkpoints'
$stateRoot = Join-Path $tempRoot 'state'
$workspace = Join-Path $tempRoot 'workspace'
$guardStatePath = Join-Path $stateRoot 'guard-state.json'
$guardPatchPath = Join-Path $stateRoot 'guard.patch.yml'
$readyPath = Join-Path $tempRoot 'ready.json'
$stopPath = Join-Path $tempRoot 'stop'
$serverProcess = $null
$baseUrl = $null
$step = 'init'

function Assert-KnownGood {
  param([Parameter(Mandatory = $true)][bool]$Condition, [Parameter(Mandatory = $true)][string]$Message)
  if (-not $Condition) { [void]$failures.Add($Message) }
}

function Write-KnownGoodText {
  param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$Text)
  $parent = Split-Path -Parent $Path
  New-Item -ItemType Directory -Path $parent -Force | Out-Null
  [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false))
}

function Get-FreeKnownGoodPort {
  $probe = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
  try { $probe.Start(); return ([Net.IPEndPoint]$probe.LocalEndpoint).Port } finally { $probe.Stop() }
}

try {
  $step = 'create fixture directories'
  New-Item -ItemType Directory -Path $profileRoot -Force | Out-Null
  New-Item -ItemType Directory -Path $stateRoot -Force | Out-Null
  New-Item -ItemType Directory -Path $workspace -Force | Out-Null
  $step = 'write profile files'
  Write-KnownGoodText -Path (Join-Path $profileRoot 'package.json') -Text (@{
    name = 'fixture-profile'
    version = '0.0.0'
    dependencies = @{ 'dsh-plugin-fixture' = 'file:..\..\fixture' }
    dsh = @{ profile = @{ bundles = @('dsh-plugin-fixture') } }
  } | ConvertTo-Json -Depth 10)
  Write-KnownGoodText -Path (Join-Path $profileRoot 'cordis.yml') -Text "- id: fixture`n"
  Write-KnownGoodText -Path (Join-Path $profileRoot 'cordis.patch.yml') -Text "- id: fixture`n"
  Write-KnownGoodText -Path (Join-Path $profileRoot 'pnpm-workspace.yaml') -Text "packages: []`n"
  Write-KnownGoodText -Path (Join-Path $dshHome 'settings.yaml') -Text "defaultPreset: workspace-write`n"
  Write-KnownGoodText -Path $guardStatePath -Text (@{ version = 1; profile = 'fixture'; failures = @(); quarantined = @(); lastRun = $null } | ConvertTo-Json -Depth 10)
  Write-KnownGoodText -Path $guardPatchPath -Text "[]`n"
  Write-KnownGoodText -Path (Join-Path $workspace 'user.txt') -Text "workspace must remain untouched`n"

  $step = 'start HTTP fixture'
  $port = Get-FreeKnownGoodPort
  $powershell = Get-DshPowerShellPath
  $serverArgs = @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $MyInvocation.MyCommand.Path, '-Server', '-ServerPort', [string]$port, '-ReadyPath', $readyPath, '-StopPath', $stopPath)
  $serverProcess = Start-Process -FilePath $powershell -ArgumentList $serverArgs -PassThru -WindowStyle Hidden
  for ($attempt = 0; $attempt -lt 100; $attempt++) {
    if (Test-Path -LiteralPath $readyPath -PathType Leaf) { break }
    if ($serverProcess.HasExited) { throw 'known-good HTTP fixture exited before readiness' }
    Start-Sleep -Milliseconds 50
  }
  $baseUrl = "http://127.0.0.1:$port/"

  $step = 'save checkpoint'
  $saved = Save-DshKnownGoodCheckpoint -Profile 'fixture' -DshHome $dshHome -CheckpointRoot $checkpointRoot -StateRoot $stateRoot -Label 'healthy-fixture' -MaxAutomaticRestores 1 -DshVersion 'fixture-dsh'
  Assert-KnownGood ($saved.result -eq 'PASS' -and $saved.status -eq 'healthy') 'known-good save did not return healthy PASS'
  $checkpointId = [string]$saved.checkpointId
  Assert-KnownGood ($saved.workspaceCaptured -eq $false -and (Test-Path -LiteralPath (Join-Path $workspace 'user.txt') -PathType Leaf)) 'known-good save crossed the workspace boundary'

  $failedGuard = @{
    version = 1
    profile = 'fixture'
    failures = @(@{ entryId = 'dsh-plugin-fixture'; moduleName = 'dsh-plugin-fixture'; count = 1; lastReason = 'fixture crash' })
    quarantined = @(@{ entryId = 'dsh-plugin-fixture'; patchEntryId = 'dsh-plugin-fixture'; moduleName = 'dsh-plugin-fixture'; reason = 'fixture crash'; attribution = 'observed'; mapping = 'exact'; quarantinedAt = (Get-Date).ToUniversalTime().ToString('o') })
    lastRun = (Get-Date).ToUniversalTime().ToString('o')
  }
  Write-KnownGoodText -Path $guardStatePath -Text ($failedGuard | ConvertTo-Json -Depth 10)
  Write-KnownGoodText -Path $guardPatchPath -Text "- id: 'dsh-plugin-fixture'`n  name: 'dsh-plugin-fixture'`n  disabled: true`n"

  $step = 'restore checkpoint'
  $restored = Restore-DshKnownGoodCheckpoint -Profile 'fixture' -CheckpointId $checkpointId -DshHome $dshHome -CheckpointRoot $checkpointRoot -StateRoot $stateRoot -BaseUrl $baseUrl -FailedPluginId 'dsh-plugin-fixture' -Automatic
  $restoredState = Get-Content -LiteralPath $guardStatePath -Raw -Encoding UTF8 | ConvertFrom-Json
  $restoredPatch = Get-Content -LiteralPath $guardPatchPath -Raw -Encoding UTF8
  Assert-KnownGood ($restored.result -eq 'PASS' -and $restored.status -eq 'healthy') 'known-good restore did not return healthy PASS'
  Assert-KnownGood ($restored.web.status -eq 'ready' -and $restored.web.ready -eq $true) 'known-good restore did not verify Web readiness'
  Assert-KnownGood ($restored.failedPluginPreserved -eq $true -and @($restoredState.quarantined).Count -eq 1 -and $restoredPatch -match 'disabled: true') 'known-good restore re-enabled or lost the failed plugin quarantine'
  Assert-KnownGood ($restored.workspaceTouched -eq $false -and (Get-Content -LiteralPath (Join-Path $workspace 'user.txt') -Raw -Encoding UTF8) -match 'untouched') 'known-good restore touched workspace data'

  $limitReached = $false
  try {
    $null = Restore-DshKnownGoodCheckpoint -Profile 'fixture' -CheckpointId $checkpointId -DshHome $dshHome -CheckpointRoot $checkpointRoot -StateRoot $stateRoot -BaseUrl $baseUrl -FailedPluginId 'dsh-plugin-fixture' -Automatic
  } catch {
    $limitReached = $_.Exception.Message -match 'AUTO_RESTORE_LIMIT'
  }
  Assert-KnownGood $limitReached 'known-good automatic restore was not bounded to one attempt'

  Write-KnownGoodText -Path (Join-Path $profileRoot 'cordis.patch.yml') -Text "- id: user-edit`n"
  $conflict = Restore-DshKnownGoodCheckpoint -Profile 'fixture' -CheckpointId $checkpointId -DshHome $dshHome -CheckpointRoot $checkpointRoot -StateRoot $stateRoot
  Assert-KnownGood ($conflict.result -eq 'CONFLICT' -and $conflict.status -eq 'MANUAL_REVIEW') 'known-good restore did not refuse a concurrent Profile edit'
  $forced = Restore-DshKnownGoodCheckpoint -Profile 'fixture' -CheckpointId $checkpointId -DshHome $dshHome -CheckpointRoot $checkpointRoot -StateRoot $stateRoot -FailedPluginId 'dsh-plugin-fixture' -Force
  Assert-KnownGood ($forced.result -eq 'PASS' -and $forced.failedPluginPreserved -eq $true) 'forced known-good restore did not preserve the quarantined plugin'
} catch {
  [void]$failures.Add("unhandled at $step`: $($_.Exception.Message); profile=$profileRoot; state=$stateRoot; workspace=$workspace")
} finally {
  if ($null -ne $serverProcess -and -not $serverProcess.HasExited) {
    New-Item -ItemType File -Path $stopPath -Force | Out-Null
    try { [void]$serverProcess.WaitForExit(5000) } catch { }
    if (-not $serverProcess.HasExited) { Stop-Process -Id $serverProcess.Id -Force -ErrorAction SilentlyContinue }
  }
  if (-not $KeepTemp -and (Test-Path -LiteralPath $tempRoot)) { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
}

[ordered]@{
  result = if ($failures.Count -eq 0) { 'PASS' } else { 'FAIL' }
  kind = 'dsh-known-good-test'
  usedRealDshHome = $false
  usedRealDshPort = $false
  automaticRestoreBounded = $failures.Count -eq 0
  failedPluginPreserved = $failures.Count -eq 0
  webReadinessVerified = $failures.Count -eq 0
  workspaceUntouched = $failures.Count -eq 0
  tempRoot = if ($KeepTemp) { $tempRoot } else { $null }
  failures = @($failures)
} | ConvertTo-Json -Depth 15
if ($failures.Count -gt 0) { exit 1 }
exit 0
