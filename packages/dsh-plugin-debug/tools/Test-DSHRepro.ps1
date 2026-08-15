[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$toolRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$reproScript = Join-Path $toolRoot 'DSH-Repro.ps1'
$failures = [System.Collections.Generic.List[string]]::new()

function Assert-Repro {
  param([bool]$Condition, [string]$Message)
  if (-not $Condition) { [void]$failures.Add($Message) }
}

function Get-TestReproHash {
  param([Parameter(Mandatory = $true)][string]$Path)
  $sha = [Security.Cryptography.SHA256]::Create()
  try {
    return ([BitConverter]::ToString($sha.ComputeHash([IO.File]::ReadAllBytes($Path)))).Replace('-', '').ToLowerInvariant()
  } finally {
    $sha.Dispose()
  }
}

function Invoke-ReproJson {
  param([Parameter(Mandatory = $true)][string]$ScriptPath, [hashtable]$Arguments)
  $tokens = [System.Collections.Generic.List[string]]::new()
  foreach ($entry in $Arguments.GetEnumerator()) {
    $name = "-$($entry.Key)"
    $value = $entry.Value
    if ($value -is [bool] -or $value -is [System.Management.Automation.SwitchParameter]) {
      if ([bool]$value) { [void]$tokens.Add($name) }
      continue
    }
    if ($null -eq $value) { continue }
    if ($value -is [System.Array] -and $value -isnot [string]) {
      [void]$tokens.Add($name)
      [void]$tokens.Add([string]::Join('|', @($value | ForEach-Object { [string]$_ })))
      continue
    }
    [void]$tokens.Add($name)
    [void]$tokens.Add([string]$value)
  }
  $previousErrorAction = $ErrorActionPreference
  try {
    $ErrorActionPreference = 'Continue'
    $output = & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $ScriptPath @tokens 2>&1
    $exitCode = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $previousErrorAction
  }
  $text = ($output | Out-String).Trim()
  $value = $null
  try { $value = $text | ConvertFrom-Json } catch { }
  return [PSCustomObject]@{ exitCode = $exitCode; text = $text; value = $value }
}

function Write-ReproJson {
  param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)]$Value)
  [IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 30), [Text.UTF8Encoding]::new($false))
}

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('dsh-repro-' + [Guid]::NewGuid().ToString('N'))
try {
  New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
  $inputRoot = Join-Path $tempRoot 'inputs'
  $workspaceRoot = Join-Path $tempRoot 'workspace'
  New-Item -ItemType Directory -Path $inputRoot,$workspaceRoot -Force | Out-Null
  $workspaceMarker = Join-Path $workspaceRoot 'private-workspace.txt'
  [IO.File]::WriteAllText($workspaceMarker, 'WORKSPACE-PAYLOAD-MUST-NOT-APPEAR', [Text.UTF8Encoding]::new($false))

  $incidentPath = Join-Path $inputRoot 'incident.json'
  $tracePath = Join-Path $inputRoot 'trace.json'
  $pointerPath = Join-Path $inputRoot 'pointer.json'
  $receiptPath = Join-Path $inputRoot 'receipt.json'
  Write-ReproJson -Path $incidentPath -Value ([ordered]@{
    schemaVersion = 1
    kind = 'dsh-debug-incident'
    id = 'incident-fixture-001'
    generatedAt = '2026-08-15T01:02:03.000Z'
    result = 'PARTIAL'
    profile = 'debug'
    components = [ordered]@{
      diagnostics = [ordered]@{ status = 'PARTIAL'; model = 'gpt-5.6-sol'; provider = 'fixture-provider' }
      pluginHealth = [ordered]@{ status = 'FAIL'; pluginId = 'fixture-plugin'; errorType = 'ModuleLoadError'; error = 'Authorization: Bearer secret-token' }
    }
    workspacePath = $workspaceRoot
    workspaceContent = 'WORKSPACE-PAYLOAD-MUST-NOT-APPEAR'
    arguments = [ordered]@{ command = 'Remove-Item'; cwd = $workspaceRoot }
    resultBody = 'TOOL-RESULT-BODY-MUST-NOT-APPEAR'
  })
  Write-ReproJson -Path $tracePath -Value ([ordered]@{
    schemaVersion = 1
    kind = 'dsh-tool-call-trace'
    status = 'PARTIAL'
    model = 'gpt-5.6-sol'
    calls = @(
      [ordered]@{ seq = 1; callId = 'call-001'; tool = 'bash'; status = 'error'; sandbox = 'danger-full-access'; approval = 'ask'; errorCode = 'permission_denied'; arguments = [ordered]@{ command = 'type secret' } }
    )
    totals = [ordered]@{ totalCount = 1; errorCount = 1; pendingCount = 0 }
    sessionBody = 'SESSION-PAYLOAD-MUST-NOT-APPEAR'
  })
  Write-ReproJson -Path $pointerPath -Value ([ordered]@{
    schemaVersion = 2
    kind = 'dsh-pointer-observation'
    status = 'PASS'
    pointer = [ordered]@{
      plugin = 'fixture-plugin'
      module = 'FixtureModule'
      slot = 'fixture-slot'
      confidence = 'high'
      sourceSearchIncomplete = $false
    }
    visibleText = 'PAGE-TEXT-MUST-NOT-APPEAR'
    url = 'https://example.invalid/private'
  })
  Write-ReproJson -Path $receiptPath -Value ([ordered]@{
    schemaVersion = 1
    kind = 'dsh-repair-receipt'
    status = 'applied'
    receipt = 'receipt-fixture-001'
    operation = 'quarantine-plugin'
    pluginId = 'fixture-plugin'
    requiresApproval = $true
    evidenceHash = ('a' * 64)
    postImageHash = ('b' * 64)
    path = $workspaceRoot
  })

  $beforeHashes = @($incidentPath,$tracePath,$pointerPath,$receiptPath | ForEach-Object { Get-TestReproHash -Path $_ })
  $outputRoot = Join-Path $tempRoot 'export-one'
  $export = Invoke-ReproJson -ScriptPath $reproScript -Arguments @{
    InputPath = @($incidentPath,$tracePath,$pointerPath,$receiptPath)
    OutputPath = $outputRoot
    Zip = $true
  }
  Assert-Repro ($export.exitCode -eq 0 -and $export.value.result -eq 'PASS') "repro export did not return PASS: $($export.text)"
  Assert-Repro ($export.value.rawPayloadStored -eq $false -and $export.value.networkAccessed -eq $false) 'repro export privacy contract is not fail-closed'
  Assert-Repro ([int]$export.value.artifactCount -eq 3) 'repro export did not report the fixed artifact set'
  Assert-Repro ($export.value.zipCreated -eq $true) 'repro export did not create the optional zip'

  $artifactPaths = @(
    (Join-Path $outputRoot 'repro.json'),
    (Join-Path $outputRoot 'manifest.json'),
    (Join-Path $outputRoot 'README.txt'),
    ($outputRoot + '.zip')
  )
  foreach ($artifactPath in $artifactPaths) {
    Assert-Repro (Test-Path -LiteralPath $artifactPath -PathType Leaf) "missing repro artifact: $([IO.Path]::GetFileName($artifactPath))"
  }
  $artifactText = (($artifactPaths[0..2] | ForEach-Object { Get-Content -LiteralPath $_ -Raw -Encoding UTF8 }) -join "`n")
  foreach ($marker in @('secret-token','WORKSPACE-PAYLOAD-MUST-NOT-APPEAR','TOOL-RESULT-BODY-MUST-NOT-APPEAR','SESSION-PAYLOAD-MUST-NOT-APPEAR','PAGE-TEXT-MUST-NOT-APPEAR','private-workspace.txt','Authorization:','https://example.invalid')) {
    Assert-Repro ($artifactText -notmatch [regex]::Escape($marker)) "forbidden marker leaked into repro artifacts: $marker"
  }
  if (Test-Path -LiteralPath ($outputRoot + '.zip') -PathType Leaf) {
    $zipInspectRoot = Join-Path $tempRoot 'zip-inspect'
    Expand-Archive -LiteralPath ($outputRoot + '.zip') -DestinationPath $zipInspectRoot -Force
    $zipFiles = @(Get-ChildItem -LiteralPath $zipInspectRoot -Recurse -File)
    Assert-Repro ($zipFiles.Count -eq 3) 'zip did not contain exactly the three allowed artifacts'
    $zipText = (($zipFiles | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8 }) -join "`n")
    foreach ($marker in @('secret-token','WORKSPACE-PAYLOAD-MUST-NOT-APPEAR','TOOL-RESULT-BODY-MUST-NOT-APPEAR','SESSION-PAYLOAD-MUST-NOT-APPEAR','PAGE-TEXT-MUST-NOT-APPEAR','Authorization:','https://example.invalid')) {
      Assert-Repro ($zipText -notmatch [regex]::Escape($marker)) "forbidden marker leaked into zip artifacts: $marker"
    }
  }
  $manifest = Get-Content -LiteralPath (Join-Path $outputRoot 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
  Assert-Repro ($manifest.rawPayloadStored -eq $false -and $manifest.redactionPolicy -and @($manifest.artifacts).Count -eq 3) 'manifest contract is incomplete'
  Assert-Repro ($manifest.sourceIncidentId -eq 'incident-fixture-001') 'manifest did not preserve the safe incident identifier'
  Assert-Repro ((@($manifest.artifacts) | ForEach-Object { $_.name }) -contains 'repro.json') 'manifest does not hash repro.json'
  Assert-Repro ((Get-TestReproHash -Path $incidentPath) -eq $beforeHashes[0]) 'export changed incident input'
  Assert-Repro ((Get-TestReproHash -Path $tracePath) -eq $beforeHashes[1]) 'export changed trace input'
  Assert-Repro ((Get-TestReproHash -Path $pointerPath) -eq $beforeHashes[2]) 'export changed pointer input'
  Assert-Repro ((Get-TestReproHash -Path $receiptPath) -eq $beforeHashes[3]) 'export changed receipt input'

  $dispatcherOutput = Join-Path $tempRoot 'dispatcher-export'
  $dispatcher = Join-Path (Split-Path -Parent $toolRoot) 'DSH-Provenance.ps1'
  $dispatcherResult = Invoke-ReproJson -ScriptPath $dispatcher -Arguments @{
    Action = 'repro-export'
    InputPath = $incidentPath
    ReproPath = $dispatcherOutput
  }
  Assert-Repro ($dispatcherResult.exitCode -eq 0 -and $dispatcherResult.value.result -eq 'PASS' -and (Test-Path -LiteralPath (Join-Path $dispatcherOutput 'manifest.json') -PathType Leaf)) 'unified dispatcher did not route repro-export'

  $outputTwo = Join-Path $tempRoot 'export-two'
  $exportTwo = Invoke-ReproJson -ScriptPath $reproScript -Arguments @{
    InputPath = @($incidentPath,$tracePath,$pointerPath,$receiptPath)
    OutputPath = $outputTwo
  }
  Assert-Repro ($exportTwo.exitCode -eq 0 -and $exportTwo.value.result -eq 'PASS') 'second identical repro export did not return PASS'
  $manifestTwo = Get-Content -LiteralPath (Join-Path $outputTwo 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
  $stableOne = [ordered]@{ artifacts = @($manifest.artifacts); policy = $manifest.redactionPolicy; sourceCount = $manifest.sourceCount }
  $stableTwo = [ordered]@{ artifacts = @($manifestTwo.artifacts); policy = $manifestTwo.redactionPolicy; sourceCount = $manifestTwo.sourceCount }
  Assert-Repro (($stableOne | ConvertTo-Json -Depth 20 -Compress) -eq ($stableTwo | ConvertTo-Json -Depth 20 -Compress)) 'identical inputs did not produce a stable manifest projection'

  $containedExport = Invoke-ReproJson -ScriptPath $reproScript -Arguments @{
    InputPath = @($incidentPath)
    OutputPath = $tempRoot
  }
  Assert-Repro ($containedExport.exitCode -ne 0 -and $containedExport.text -notmatch [regex]::Escape($incidentPath)) 'output containment did not fail closed'

  $badPath = Join-Path $inputRoot 'broken.json'
  [IO.File]::WriteAllText($badPath, '{not-json', [Text.UTF8Encoding]::new($false))
  $badOutput = Join-Path $tempRoot 'bad-export'
  $malformed = Invoke-ReproJson -ScriptPath $reproScript -Arguments @{ InputPath = @($badPath); OutputPath = $badOutput }
  Assert-Repro ($malformed.exitCode -ne 0 -and -not (Test-Path -LiteralPath $badOutput)) 'malformed repro input did not fail closed'
  Assert-Repro ($malformed.text -notmatch [regex]::Escape($badPath)) 'malformed input error leaked an absolute path'

  $scriptText = Get-Content -LiteralPath $reproScript -Raw -Encoding UTF8
  Assert-Repro ($scriptText -notmatch '(?i)Invoke-WebRequest|Invoke-RestMethod|Start-BitsTransfer|curl\.exe|wget\.exe') 'repro exporter contains a network-capable command'
} catch {
  [void]$failures.Add('repro fixture threw: ' + $_.Exception.Message)
} finally {
  if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
}

if ($failures.Count -gt 0) {
  [ordered]@{ result = 'FAIL'; failures = @($failures); offline = $true } | ConvertTo-Json -Depth 12
  exit 1
}
[ordered]@{ result = 'PASS'; offline = $true; networkAccessed = $false; inputChanged = $false; forbiddenMarkersLeaked = $false } | ConvertTo-Json -Depth 8
exit 0
