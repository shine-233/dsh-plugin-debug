[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][ValidateSet('list-snapshots', 'snapshot-profile', 'restore-profile', 'list-workspace-snapshots', 'snapshot-workspace', 'restore-workspace', 'session-history', 'session-fork')]
  [string]$Action,
  [string]$Profile = 'web',
  [string]$Workspace = '',
  [string]$DshHome = '',
  [string]$SnapshotRoot = '',
  [string]$SnapshotId = '',
  [string]$Label = 'manual',
  [string]$BaseUrl = '',
  [string]$SessionId = '',
  [Nullable[int]]$AtSeq,
  [int]$MaxMessages = 100,
  [switch]$Force,
  [switch]$NoRescue
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $root 'DSH-Guard.psm1') -Force
Import-Module (Join-Path $root 'DSH-Recovery.psm1') -Force

if ([string]::IsNullOrWhiteSpace($BaseUrl)) { $BaseUrl = 'http://127.0.0.1:3080/' }

try {
  $result = switch ($Action) {
    'list-snapshots' {
      Get-DshProfileSnapshots -Profile $Profile -DshHome $DshHome -SnapshotRoot $SnapshotRoot
    }
    'snapshot-profile' {
      Save-DshProfileSnapshot -Profile $Profile -DshHome $DshHome -SnapshotRoot $SnapshotRoot -Label $Label
    }
    'restore-profile' {
      if ([string]::IsNullOrWhiteSpace($SnapshotId)) { throw '-SnapshotId is required for restore-profile' }
      if (-not $Force) { throw 'restore-profile changes DSH configuration; pass -Force after reviewing the snapshot' }
      Restore-DshProfileSnapshot -Profile $Profile -SnapshotId $SnapshotId -DshHome $DshHome -SnapshotRoot $SnapshotRoot -NoRescue:$NoRescue
    }
    'list-workspace-snapshots' {
      if ([string]::IsNullOrWhiteSpace($Workspace)) { throw '-Workspace is required for list-workspace-snapshots' }
      Get-DshWorkspaceSnapshots -Workspace $Workspace -DshHome $DshHome -SnapshotRoot $SnapshotRoot
    }
    'snapshot-workspace' {
      if ([string]::IsNullOrWhiteSpace($Workspace)) { throw '-Workspace is required for snapshot-workspace' }
      Save-DshWorkspaceSnapshot -Workspace $Workspace -DshHome $DshHome -SnapshotRoot $SnapshotRoot -Label $Label
    }
    'restore-workspace' {
      if ([string]::IsNullOrWhiteSpace($Workspace)) { throw '-Workspace is required for restore-workspace' }
      if ([string]::IsNullOrWhiteSpace($SnapshotId)) { throw '-SnapshotId is required for restore-workspace' }
      if (-not $Force) { throw 'restore-workspace changes project files; pass -Force after reviewing the snapshot' }
      Restore-DshWorkspaceSnapshot -Workspace $Workspace -SnapshotId $SnapshotId -DshHome $DshHome -SnapshotRoot $SnapshotRoot -NoRescue:$NoRescue
    }
    'session-history' {
      if ([string]::IsNullOrWhiteSpace($SessionId)) { throw '-SessionId is required for session-history' }
      Get-DshSessionHistoryObservation -BaseUrl $BaseUrl -SessionId $SessionId -MaxMessages $MaxMessages
    }
    'session-fork' {
      if ([string]::IsNullOrWhiteSpace($SessionId)) { throw '-SessionId is required for session-fork' }
      if ($null -eq $AtSeq) { throw '-AtSeq is required for session-fork' }
      Invoke-DshSessionFork -BaseUrl $BaseUrl -SessionId $SessionId -AtSeq $AtSeq
    }
  }
  [ordered]@{
    result = 'PASS'
    action = $Action
    value = $result
  } | ConvertTo-Json -Depth 20
  exit 0
} catch {
  [ordered]@{
    result = 'FAIL'
    action = $Action
    error = $_.Exception.Message
  } | ConvertTo-Json -Depth 12
  exit 1
}
