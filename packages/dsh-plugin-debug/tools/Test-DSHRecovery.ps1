[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $root 'DSH-Recovery.psm1') -Force

function Assert-Recovery {
  param([bool]$Condition, [string]$Message)
  if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
}

$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('dsh-recovery-' + [guid]::NewGuid().ToString('N'))
$dshHome = Join-Path $fixtureRoot 'home'
$profile = 'recovery-fixture'
$profileRoot = Join-Path $dshHome "profiles\$profile"
$snapshotRoot = Join-Path $fixtureRoot 'snapshots'
$workspaceRoot = Join-Path $fixtureRoot 'workspace'
$workspaceSnapshotRoot = Join-Path $fixtureRoot 'workspace-snapshots'

try {
  New-Item -ItemType Directory -Path $profileRoot -Force | Out-Null
  $profileFiles = @(
    [PSCustomObject]@{ name = 'package.json'; value = '{"name":"fixture","dependencies":{"dsh-plugin-fixture":"link:C:/fixture"}}' }
    [PSCustomObject]@{ name = 'cordis.yml'; value = "- insert:`n    - id: fixture" }
    [PSCustomObject]@{ name = 'cordis.patch.yml'; value = '[]' }
    [PSCustomObject]@{ name = 'pnpm-workspace.yaml'; value = 'allowBuildScripts: true' }
  )
  foreach ($profileFile in $profileFiles) {
    Set-Content -LiteralPath (Join-Path $profileRoot $profileFile.name) -Value $profileFile.value -Encoding UTF8
  }
  Set-Content -LiteralPath (Join-Path $dshHome 'settings.yaml') -Value 'permission:`n  defaultPreset: workspace-write' -Encoding UTF8
  Set-Content -LiteralPath (Join-Path $dshHome '.env') -Value 'DSH_FIXTURE_SECRET=do-not-print' -Encoding UTF8
  Set-Content -LiteralPath (Join-Path $dshHome '.credentials.yaml') -Value 'apiKey: credential-secret-do-not-print' -Encoding UTF8

  $snapshot = Save-DshProfileSnapshot -Profile $profile -DshHome $dshHome -SnapshotRoot $snapshotRoot -Label 'before-plugin-change'
  Assert-Recovery (-not [string]::IsNullOrWhiteSpace($snapshot.id)) 'snapshot should have an id'
  Assert-Recovery (@($snapshot.files).Count -eq 5) 'snapshot should capture only non-sensitive defined files'
  Assert-Recovery (@($snapshot.sensitiveFiles) -contains '.env') 'snapshot should mark .env as sensitive'
  Assert-Recovery (@($snapshot.sensitiveFiles) -contains '.credentials.yaml') 'snapshot should mark .credentials.yaml as sensitive'
  Assert-Recovery (-not (Test-Path -LiteralPath (Join-Path $snapshot.path '.env') -PathType Leaf)) 'snapshot must never copy .env'
  Assert-Recovery (-not (Test-Path -LiteralPath (Join-Path $snapshot.path '.credentials.yaml') -PathType Leaf)) 'snapshot must never copy .credentials.yaml'
  $snapshotManifest = Get-Content -LiteralPath (Join-Path $snapshot.path 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
  $envRecord = @($snapshotManifest.files | Where-Object { $_.relativePath -eq '.env' })[0]
  Assert-Recovery ($envRecord.excluded -eq $true -and $envRecord.captured -eq $false) 'manifest must mark .env as excluded, not captured'
  $credentialsRecord = @($snapshotManifest.files | Where-Object { $_.relativePath -eq '.credentials.yaml' })[0]
  Assert-Recovery ($credentialsRecord.excluded -eq $true -and $credentialsRecord.captured -eq $false) 'manifest must mark .credentials.yaml as excluded, not captured'
  $snapshotText = (Get-ChildItem -LiteralPath $snapshot.path -File -Recurse | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8 }) -join "`n"
  Assert-Recovery ($snapshotText -notmatch 'DSH_FIXTURE_SECRET=do-not-print|credential-secret-do-not-print') 'snapshot must not contain sensitive credential content'

  Set-Content -LiteralPath (Join-Path $profileRoot 'package.json') -Value '{"broken":true}' -Encoding UTF8
  Set-Content -LiteralPath (Join-Path $profileRoot 'cordis.patch.yml') -Value '- id: broken' -Encoding UTF8
  Set-Content -LiteralPath (Join-Path $profileRoot 'new-file-created-after-snapshot.txt') -Value 'keep me' -Encoding UTF8
  Set-Content -LiteralPath (Join-Path $dshHome '.env') -Value 'DSH_FIXTURE_SECRET=changed-after-snapshot' -Encoding UTF8
  Set-Content -LiteralPath (Join-Path $dshHome '.credentials.yaml') -Value 'apiKey: changed-credential-secret' -Encoding UTF8

  $restored = Restore-DshProfileSnapshot -Profile $profile -DshHome $dshHome -SnapshotRoot $snapshotRoot -SnapshotId $snapshot.id
  $package = Get-Content -LiteralPath (Join-Path $profileRoot 'package.json') -Raw -Encoding UTF8
  $patch = Get-Content -LiteralPath (Join-Path $profileRoot 'cordis.patch.yml') -Raw -Encoding UTF8
  Assert-Recovery ($package -match 'dsh-plugin-fixture') 'package.json should be restored'
  Assert-Recovery ($patch.Trim() -eq '[]') 'cordis.patch.yml should be restored'
  Assert-Recovery (Test-Path -LiteralPath (Join-Path $profileRoot 'new-file-created-after-snapshot.txt') -PathType Leaf) 'new files must not be deleted'
  $envAfterRestore = Get-Content -LiteralPath (Join-Path $dshHome '.env') -Raw -Encoding UTF8
  Assert-Recovery ($envAfterRestore -match 'DSH_FIXTURE_SECRET=changed-after-snapshot') 'restore must not overwrite .env'
  $credentialsAfterRestore = Get-Content -LiteralPath (Join-Path $dshHome '.credentials.yaml') -Raw -Encoding UTF8
  Assert-Recovery ($credentialsAfterRestore -match 'changed-credential-secret') 'restore must not overwrite .credentials.yaml'
  Assert-Recovery (-not [string]::IsNullOrWhiteSpace([string]$restored.rescueSnapshot)) 'restore should create a rescue snapshot'

  $snapshots = @(Get-DshProfileSnapshots -Profile $profile -DshHome $dshHome -SnapshotRoot $snapshotRoot)
  Assert-Recovery ($snapshots.Count -ge 2) 'manual and rescue snapshots should be listed'
  Assert-Recovery (@($snapshots | Where-Object { $_.sensitiveFileCount -gt 0 }).Count -ge 1) 'snapshot listing should expose only a sensitive-file count'

  New-Item -ItemType Directory -Path (Join-Path $workspaceRoot 'src') -Force | Out-Null
  New-Item -ItemType Directory -Path (Join-Path $workspaceRoot '.git') -Force | Out-Null
  New-Item -ItemType Directory -Path (Join-Path $workspaceRoot 'node_modules') -Force | Out-Null
  Set-Content -LiteralPath (Join-Path $workspaceRoot 'src\main.txt') -Value 'before workspace change' -Encoding UTF8
  Set-Content -LiteralPath (Join-Path $workspaceRoot '.git\private-index') -Value 'must not be copied' -Encoding UTF8
  Set-Content -LiteralPath (Join-Path $workspaceRoot 'node_modules\private-cache') -Value 'must not be copied' -Encoding UTF8

  $workspaceSnapshot = Save-DshWorkspaceSnapshot -Workspace $workspaceRoot -DshHome $dshHome -SnapshotRoot $workspaceSnapshotRoot -Label 'before-code-change'
  Assert-Recovery ($workspaceSnapshot.fileCount -eq 1) 'workspace snapshot should exclude .git and node_modules'
  $workspaceManifest = Get-Content -LiteralPath (Join-Path $workspaceSnapshot.path 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
  Assert-Recovery (@($workspaceManifest.files | Where-Object { $_.relativePath -match '(^|[\\/])(?:\.git|node_modules)([\\/]|$)' }).Count -eq 0) 'workspace manifest must not include excluded directories'

  Set-Content -LiteralPath (Join-Path $workspaceRoot 'src\main.txt') -Value 'after workspace change' -Encoding UTF8
  Set-Content -LiteralPath (Join-Path $workspaceRoot 'src\new-file.txt') -Value 'preserve later file' -Encoding UTF8
  $workspaceRestored = Restore-DshWorkspaceSnapshot -Workspace $workspaceRoot -DshHome $dshHome -SnapshotRoot $workspaceSnapshotRoot -SnapshotId $workspaceSnapshot.id
  $workspaceContent = Get-Content -LiteralPath (Join-Path $workspaceRoot 'src\main.txt') -Raw -Encoding UTF8
  Assert-Recovery ($workspaceContent -match 'before workspace change') 'workspace file should be restored'
  Assert-Recovery (Test-Path -LiteralPath (Join-Path $workspaceRoot 'src\new-file.txt') -PathType Leaf) 'workspace files created after snapshot must not be deleted'
  Assert-Recovery (-not (Test-Path -LiteralPath (Join-Path $workspaceSnapshot.path '.git\private-index'))) 'excluded .git files must not enter the snapshot'
  $workspaceSnapshots = @(Get-DshWorkspaceSnapshots -Workspace $workspaceRoot -DshHome $dshHome -SnapshotRoot $workspaceSnapshotRoot)
  Assert-Recovery ($workspaceSnapshots.Count -ge 2) 'workspace manual and rescue snapshots should be listed'

  $missingAtSeqError = $null
  try {
    Invoke-DshSessionFork -BaseUrl 'http://127.0.0.1:1/' -SessionId 'fixture'
  } catch {
    $missingAtSeqError = $_.Exception.Message
  }
  Assert-Recovery ($missingAtSeqError -eq 'AtSeq is required for session-fork') 'session fork must reject a missing AtSeq before contacting the API'

  $negativeAtSeqError = $null
  try {
    Invoke-DshSessionFork -BaseUrl 'http://127.0.0.1:1/' -SessionId 'fixture' -AtSeq -1
  } catch {
    $negativeAtSeqError = $_.Exception.Message
  }
  Assert-Recovery ($negativeAtSeqError -eq 'AtSeq must be non-negative') 'session fork must reject a negative AtSeq before contacting the API'

  [PSCustomObject]@{
    result = 'PASS'
    snapshotId = $snapshot.id
    rescueSnapshot = $restored.rescueSnapshot
    listedSnapshots = $snapshots.Count
    extraFilePreserved = $true
    envExcluded = $true
    envPreserved = $true
    credentialsExcluded = $true
    credentialsPreserved = $true
    workspaceSnapshotId = $workspaceSnapshot.id
    workspaceRescueSnapshot = $workspaceRestored.rescueSnapshot
    workspaceListedSnapshots = $workspaceSnapshots.Count
    workspaceExtraFilePreserved = $true
    missingAtSeqRejected = $true
    negativeAtSeqRejected = $true
  }
} finally {
  if (Test-Path -LiteralPath $fixtureRoot -PathType Container) {
    Remove-Item -LiteralPath $fixtureRoot -Recurse -Force
  }
}
