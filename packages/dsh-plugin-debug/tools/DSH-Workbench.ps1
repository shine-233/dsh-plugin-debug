[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][ValidateSet('start', 'status', 'diagnostics', 'plugin-health', 'snapshot', 'restore', 'workspace-list', 'workspace-snapshot', 'workspace-restore', 'session-history', 'session-fork', 'plugin-enable', 'plugin-disable', 'pointer-evidence', 'repair-plan', 'repair-assist', 'self-repair', 'repair-apply', 'repair-revert')]
  [string]$Action,
  [string]$Profile = 'web',
  [int]$Port = 3080,
  [string]$HostName = '127.0.0.1',
  [string]$Workspace = '',
  [string]$StateRoot = '',
  [string]$DshHome = '',
  [string]$RuntimeRoot = '',
  [string]$SnapshotRoot = '',
  [string]$SnapshotId = '',
  [string]$Label = 'manual',
  [string]$PluginId = '',
  [string]$SessionId = '',
  [Nullable[int]]$AtSeq,
  [int]$MaxMessages = 100,
  [string]$ExpectedModel = '',
  [string]$PointerPath = '',
  [string]$DiagnosticsPath = '',
  [string]$PlanPath = '',
  [string]$ReceiptPath = '',
  [string]$Cwd = '',
  [int]$RepairTimeoutSec = 60,
  [switch]$NoBrowser,
  [switch]$NoInstall,
  [switch]$NoPluginInstall,
  [switch]$NoCrashGuard,
  [switch]$NoSupervisor,
  [int]$SupervisorIntervalSec = 2,
  [int]$SupervisorMaxWebMisses = 3,
  [switch]$SkipApi,
  [switch]$Force,
  [switch]$NoRescue,
  [switch]$ClearQuarantine,
  [switch]$ApplyModelPlan,
  [switch]$Automatic,
  [switch]$UseModel,
  [switch]$RestartAfterApply
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path

function Get-NestedExitCode {
  param([bool]$InvocationSucceeded = $true)
  $variable = Get-Variable -Name LASTEXITCODE -ErrorAction SilentlyContinue
  $exitCode = if ($null -eq $variable -or $null -eq $variable.Value) { 0 } else { [int]$variable.Value }
  if (-not $InvocationSucceeded -and $exitCode -eq 0) { return 1 }
  return $exitCode
}

function Add-IfPresent {
  param(
    [Parameter(Mandatory = $true)][System.Collections.Generic.List[string]]$Arguments,
    [Parameter(Mandatory = $true)][string]$Name,
    [AllowNull()][string]$Value
  )
  if (-not [string]::IsNullOrWhiteSpace($Value)) {
    $Arguments.Add($Name)
    $Arguments.Add($Value)
  }
}

function Invoke-LocalScript {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][System.Collections.Generic.List[string]]$Arguments
  )
  $named = @{}
  for ($index = 0; $index -lt $Arguments.Count; $index++) {
    $token = [string]$Arguments[$index]
    if ($token -notmatch '^-[A-Za-z]') { throw "internal workbench argument is not named: $token" }
    $name = $token.Substring(1)
    if ($index + 1 -lt $Arguments.Count -and [string]$Arguments[$index + 1] -notmatch '^-[A-Za-z]') {
      $named[$name] = [string]$Arguments[$index + 1]
      $index += 1
    } else {
      $named[$name] = $true
    }
  }
  # Pure PowerShell child scripts do not necessarily initialize
  # LASTEXITCODE. Seed it so a successful child is not misreported as a
  # strict-mode failure or as a stale native-process exit code.
  $LASTEXITCODE = 0
  & $Path @named
  $nestedSucceeded = $?
  exit (Get-NestedExitCode -InvocationSucceeded $nestedSucceeded)
}

try {
  if ($Action -eq 'status') { $Action = 'diagnostics' }
  switch ($Action) {
    'start' {
      $arguments = [System.Collections.Generic.List[string]]::new()
      $arguments.Add('-Profile'); $arguments.Add($Profile)
      $arguments.Add('-Port'); $arguments.Add([string]$Port)
      $arguments.Add('-HostName'); $arguments.Add($HostName)
      Add-IfPresent -Arguments $arguments -Name '-Workspace' -Value $Workspace
      Add-IfPresent -Arguments $arguments -Name '-StateRoot' -Value $StateRoot
      $arguments.Add('-SupervisorIntervalSec'); $arguments.Add([string]$SupervisorIntervalSec)
      $arguments.Add('-SupervisorMaxWebMisses'); $arguments.Add([string]$SupervisorMaxWebMisses)
      if ($NoBrowser) { $arguments.Add('-NoBrowser') }
      if ($NoInstall) { $arguments.Add('-NoInstall') }
      if ($NoPluginInstall) { $arguments.Add('-NoPluginInstall') }
      if (-not $NoCrashGuard) { $arguments.Add('-EnableCrashGuard') }
      if (-not $NoSupervisor) { $arguments.Add('-KeepAlive') }
      Invoke-LocalScript -Path (Join-Path $root 'Start-DSH.ps1') -Arguments $arguments
    }
    'diagnostics' {
      $arguments = [System.Collections.Generic.List[string]]::new()
      $arguments.Add('-Profile'); $arguments.Add($Profile)
      $arguments.Add('-Port'); $arguments.Add([string]$Port)
      Add-IfPresent -Arguments $arguments -Name '-DshHome' -Value $DshHome
      Add-IfPresent -Arguments $arguments -Name '-StateRoot' -Value $StateRoot
      Add-IfPresent -Arguments $arguments -Name '-RuntimeRoot' -Value $RuntimeRoot
      Add-IfPresent -Arguments $arguments -Name '-SessionId' -Value $SessionId
      Add-IfPresent -Arguments $arguments -Name '-ExpectedModel' -Value $ExpectedModel
      Invoke-LocalScript -Path (Join-Path $root 'Get-DSH-Diagnostics.ps1') -Arguments $arguments
    }
    'plugin-health' {
      $arguments = [System.Collections.Generic.List[string]]::new()
      $arguments.Add('-Profile'); $arguments.Add($Profile)
      Add-IfPresent -Arguments $arguments -Name '-DshHome' -Value $DshHome
      Add-IfPresent -Arguments $arguments -Name '-RuntimeRoot' -Value $RuntimeRoot
      $healthBaseUrl = if ($Port -gt 0) { "http://$HostName`:$Port/" } else { '' }
      Add-IfPresent -Arguments $arguments -Name '-BaseUrl' -Value $healthBaseUrl
      if ($SkipApi) { $arguments.Add('-SkipApi') }
      Invoke-LocalScript -Path (Join-Path $root 'Get-DSH-PluginHealth.ps1') -Arguments $arguments
    }
    'snapshot' {
      $arguments = [System.Collections.Generic.List[string]]::new()
      $arguments.Add('-Action'); $arguments.Add('snapshot-profile')
      $arguments.Add('-Profile'); $arguments.Add($Profile)
      Add-IfPresent -Arguments $arguments -Name '-DshHome' -Value $DshHome
      Add-IfPresent -Arguments $arguments -Name '-SnapshotRoot' -Value $SnapshotRoot
      $arguments.Add('-Label'); $arguments.Add($Label)
      Invoke-LocalScript -Path (Join-Path $root 'DSH-Recovery.ps1') -Arguments $arguments
    }
    'restore' {
      if ([string]::IsNullOrWhiteSpace($SnapshotId)) { throw '-SnapshotId is required for restore' }
      if (-not $Force) { throw 'restore changes DSH configuration; pass -Force after reviewing the snapshot' }
      $arguments = [System.Collections.Generic.List[string]]::new()
      $arguments.Add('-Action'); $arguments.Add('restore-profile')
      $arguments.Add('-Profile'); $arguments.Add($Profile)
      $arguments.Add('-SnapshotId'); $arguments.Add($SnapshotId)
      $arguments.Add('-Force')
      if ($NoRescue) { $arguments.Add('-NoRescue') }
      Add-IfPresent -Arguments $arguments -Name '-DshHome' -Value $DshHome
      Add-IfPresent -Arguments $arguments -Name '-SnapshotRoot' -Value $SnapshotRoot
      Invoke-LocalScript -Path (Join-Path $root 'DSH-Recovery.ps1') -Arguments $arguments
    }
    'workspace-list' {
      if ([string]::IsNullOrWhiteSpace($Workspace)) { throw '-Workspace is required for workspace-list' }
      $arguments = [System.Collections.Generic.List[string]]::new()
      $arguments.Add('-Action'); $arguments.Add('list-workspace-snapshots')
      $arguments.Add('-Workspace'); $arguments.Add($Workspace)
      Add-IfPresent -Arguments $arguments -Name '-DshHome' -Value $DshHome
      Add-IfPresent -Arguments $arguments -Name '-SnapshotRoot' -Value $SnapshotRoot
      Invoke-LocalScript -Path (Join-Path $root 'DSH-Recovery.ps1') -Arguments $arguments
    }
    'workspace-snapshot' {
      if ([string]::IsNullOrWhiteSpace($Workspace)) { throw '-Workspace is required for workspace-snapshot' }
      $arguments = [System.Collections.Generic.List[string]]::new()
      $arguments.Add('-Action'); $arguments.Add('snapshot-workspace')
      $arguments.Add('-Workspace'); $arguments.Add($Workspace)
      Add-IfPresent -Arguments $arguments -Name '-DshHome' -Value $DshHome
      Add-IfPresent -Arguments $arguments -Name '-SnapshotRoot' -Value $SnapshotRoot
      $arguments.Add('-Label'); $arguments.Add($Label)
      Invoke-LocalScript -Path (Join-Path $root 'DSH-Recovery.ps1') -Arguments $arguments
    }
    'workspace-restore' {
      if ([string]::IsNullOrWhiteSpace($Workspace)) { throw '-Workspace is required for workspace-restore' }
      if ([string]::IsNullOrWhiteSpace($SnapshotId)) { throw '-SnapshotId is required for workspace-restore' }
      if (-not $Force) { throw 'workspace-restore changes project files; pass -Force after reviewing the snapshot' }
      $arguments = [System.Collections.Generic.List[string]]::new()
      $arguments.Add('-Action'); $arguments.Add('restore-workspace')
      $arguments.Add('-Workspace'); $arguments.Add($Workspace)
      $arguments.Add('-SnapshotId'); $arguments.Add($SnapshotId)
      $arguments.Add('-Force')
      if ($NoRescue) { $arguments.Add('-NoRescue') }
      Add-IfPresent -Arguments $arguments -Name '-DshHome' -Value $DshHome
      Add-IfPresent -Arguments $arguments -Name '-SnapshotRoot' -Value $SnapshotRoot
      Invoke-LocalScript -Path (Join-Path $root 'DSH-Recovery.ps1') -Arguments $arguments
    }
    'session-history' {
      if ([string]::IsNullOrWhiteSpace($SessionId)) { throw '-SessionId is required for session-history' }
      $arguments = [System.Collections.Generic.List[string]]::new()
      $arguments.Add('-Action'); $arguments.Add('session-history')
      $arguments.Add('-Profile'); $arguments.Add($Profile)
      $arguments.Add('-BaseUrl'); $arguments.Add("http://$HostName`:$Port/")
      $arguments.Add('-SessionId'); $arguments.Add($SessionId)
      $arguments.Add('-MaxMessages'); $arguments.Add([string]$MaxMessages)
      Invoke-LocalScript -Path (Join-Path $root 'DSH-Recovery.ps1') -Arguments $arguments
    }
    'session-fork' {
      if ([string]::IsNullOrWhiteSpace($SessionId)) { throw '-SessionId is required for session-fork' }
      if ($null -eq $AtSeq) { throw '-AtSeq is required for session-fork' }
      $arguments = [System.Collections.Generic.List[string]]::new()
      $arguments.Add('-Action'); $arguments.Add('session-fork')
      $arguments.Add('-Profile'); $arguments.Add($Profile)
      $arguments.Add('-BaseUrl'); $arguments.Add("http://$HostName`:$Port/")
      $arguments.Add('-SessionId'); $arguments.Add($SessionId)
      $arguments.Add('-AtSeq'); $arguments.Add([string]$AtSeq)
      Invoke-LocalScript -Path (Join-Path $root 'DSH-Recovery.ps1') -Arguments $arguments
    }
    'plugin-enable' {
      if ([string]::IsNullOrWhiteSpace($PluginId)) { throw '-PluginId is required for plugin-enable' }
      $arguments = [System.Collections.Generic.List[string]]::new()
      $arguments.Add('-DesiredState'); $arguments.Add('enable')
      $arguments.Add('-PluginId'); $arguments.Add($PluginId)
      $arguments.Add('-Profile'); $arguments.Add($Profile)
      $arguments.Add('-Port'); $arguments.Add([string]$Port)
      if ($ClearQuarantine) { $arguments.Add('-ClearQuarantine') }
      Add-IfPresent -Arguments $arguments -Name '-DshHome' -Value $DshHome
      Add-IfPresent -Arguments $arguments -Name '-StateRoot' -Value $StateRoot
      Invoke-LocalScript -Path (Join-Path $root 'Set-DSHPluginState.ps1') -Arguments $arguments
    }
    'plugin-disable' {
      if ([string]::IsNullOrWhiteSpace($PluginId)) { throw '-PluginId is required for plugin-disable' }
      $arguments = [System.Collections.Generic.List[string]]::new()
      $arguments.Add('-DesiredState'); $arguments.Add('disable')
      $arguments.Add('-PluginId'); $arguments.Add($PluginId)
      $arguments.Add('-Profile'); $arguments.Add($Profile)
      $arguments.Add('-Port'); $arguments.Add([string]$Port)
      Add-IfPresent -Arguments $arguments -Name '-DshHome' -Value $DshHome
      Add-IfPresent -Arguments $arguments -Name '-StateRoot' -Value $StateRoot
      Invoke-LocalScript -Path (Join-Path $root 'Set-DSHPluginState.ps1') -Arguments $arguments
    }
    'pointer-evidence' {
      $inputPath = if (-not [string]::IsNullOrWhiteSpace($PointerPath)) { $PointerPath } else { $DiagnosticsPath }
      if ([string]::IsNullOrWhiteSpace($inputPath)) { throw '-PointerPath or -DiagnosticsPath is required for pointer-evidence' }
      $arguments = [System.Collections.Generic.List[string]]::new()
      $arguments.Add('-Action'); $arguments.Add('pointer-evidence')
      $arguments.Add('-Profile'); $arguments.Add($Profile)
      Add-IfPresent -Arguments $arguments -Name '-DshHome' -Value $DshHome
      Add-IfPresent -Arguments $arguments -Name '-StateRoot' -Value $StateRoot
      Add-IfPresent -Arguments $arguments -Name '-InputPath' -Value $inputPath
      Invoke-LocalScript -Path (Join-Path $root 'DSH-ProvenanceSuite.ps1') -Arguments $arguments
    }
    'repair-plan' {
      $arguments = [System.Collections.Generic.List[string]]::new()
      $arguments.Add('-Action'); $arguments.Add('plan')
      $arguments.Add('-Profile'); $arguments.Add($Profile)
      $arguments.Add('-Port'); $arguments.Add([string]$Port)
      $arguments.Add('-HostName'); $arguments.Add($HostName)
      Add-IfPresent -Arguments $arguments -Name '-StateRoot' -Value $StateRoot
      Add-IfPresent -Arguments $arguments -Name '-DiagnosticsPath' -Value $DiagnosticsPath
      Add-IfPresent -Arguments $arguments -Name '-PlanPath' -Value $PlanPath
      Add-IfPresent -Arguments $arguments -Name '-SessionId' -Value $SessionId
      Invoke-LocalScript -Path (Join-Path $root 'DSH-SelfRepair.ps1') -Arguments $arguments
    }
    'repair-assist' {
      $arguments = [System.Collections.Generic.List[string]]::new()
      $arguments.Add('-Action'); $arguments.Add('assist')
      $arguments.Add('-Profile'); $arguments.Add($Profile)
      $arguments.Add('-Port'); $arguments.Add([string]$Port)
      $arguments.Add('-HostName'); $arguments.Add($HostName)
      $arguments.Add('-TimeoutSec'); $arguments.Add([string]$RepairTimeoutSec)
      Add-IfPresent -Arguments $arguments -Name '-StateRoot' -Value $StateRoot
      Add-IfPresent -Arguments $arguments -Name '-DshHome' -Value $DshHome
      Add-IfPresent -Arguments $arguments -Name '-DiagnosticsPath' -Value $DiagnosticsPath
      Add-IfPresent -Arguments $arguments -Name '-PlanPath' -Value $PlanPath
      Add-IfPresent -Arguments $arguments -Name '-SessionId' -Value $SessionId
      Add-IfPresent -Arguments $arguments -Name '-Cwd' -Value $Cwd
      if ($ApplyModelPlan) { $arguments.Add('-ApplyModelPlan') }
      if ($Force) { $arguments.Add('-Force') }
      Invoke-LocalScript -Path (Join-Path $root 'DSH-SelfRepair.ps1') -Arguments $arguments
    }
    'self-repair' {
      $arguments = [System.Collections.Generic.List[string]]::new()
      $arguments.Add('-Action'); $arguments.Add('recover')
      $arguments.Add('-Profile'); $arguments.Add($Profile)
      $arguments.Add('-Port'); $arguments.Add([string]$Port)
      $arguments.Add('-HostName'); $arguments.Add($HostName)
      $arguments.Add('-TimeoutSec'); $arguments.Add([string]$RepairTimeoutSec)
      Add-IfPresent -Arguments $arguments -Name '-StateRoot' -Value $StateRoot
      Add-IfPresent -Arguments $arguments -Name '-DshHome' -Value $DshHome
      Add-IfPresent -Arguments $arguments -Name '-DiagnosticsPath' -Value $DiagnosticsPath
      Add-IfPresent -Arguments $arguments -Name '-PlanPath' -Value $PlanPath
      Add-IfPresent -Arguments $arguments -Name '-SessionId' -Value $SessionId
      Add-IfPresent -Arguments $arguments -Name '-Cwd' -Value $Cwd
      if ($Automatic) { $arguments.Add('-Automatic') }
      if ($UseModel) { $arguments.Add('-UseModel') }
      if ($RestartAfterApply) { $arguments.Add('-RestartAfterApply') }
      Invoke-LocalScript -Path (Join-Path $root 'DSH-SelfRepair.ps1') -Arguments $arguments
    }
    'repair-apply' {
      if ([string]::IsNullOrWhiteSpace($PlanPath)) { throw '-PlanPath is required for repair-apply' }
      $arguments = [System.Collections.Generic.List[string]]::new()
      $arguments.Add('-Action'); $arguments.Add('apply')
      $arguments.Add('-Profile'); $arguments.Add($Profile)
      $arguments.Add('-Port'); $arguments.Add([string]$Port)
      Add-IfPresent -Arguments $arguments -Name '-StateRoot' -Value $StateRoot
      Add-IfPresent -Arguments $arguments -Name '-DshHome' -Value $DshHome
      Add-IfPresent -Arguments $arguments -Name '-PlanPath' -Value $PlanPath
      if ($Force) { $arguments.Add('-Force') }
      Invoke-LocalScript -Path (Join-Path $root 'DSH-SelfRepair.ps1') -Arguments $arguments
    }
    'repair-revert' {
      if ([string]::IsNullOrWhiteSpace($ReceiptPath)) { throw '-ReceiptPath is required for repair-revert' }
      $arguments = [System.Collections.Generic.List[string]]::new()
      $arguments.Add('-Action'); $arguments.Add('revert')
      Add-IfPresent -Arguments $arguments -Name '-ReceiptPath' -Value $ReceiptPath
      if ($Force) { $arguments.Add('-Force') }
      Invoke-LocalScript -Path (Join-Path $root 'DSH-SelfRepair.ps1') -Arguments $arguments
    }
  }
} catch {
  [ordered]@{ result = 'FAIL'; action = $Action; error = $_.Exception.Message } | ConvertTo-Json -Depth 8
  exit 1
}
