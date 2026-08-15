[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [ValidateSet('doctor', 'start', 'diagnostics', 'plugin-health', 'snapshot', 'restore', 'workspace-list', 'workspace-snapshot', 'workspace-restore', 'session-history', 'session-fork', 'known-good-list', 'known-good-save', 'known-good-restore', 'known-good-fixture', 'plugin-enable', 'plugin-disable', 'repair-plan', 'repair-assist', 'self-repair', 'repair-apply', 'repair-revert', 'trace-contract', 'trace-eval', 'trace-live', 'trace-baseline', 'trace-profile', 'trace-autopsy', 'live-api-fixture', 'trace-autopsy-fixture', 'crash-fixture', 'runtime-supervisor-fixture', 'incident-capture', 'incident-correlation', 'repro-export', 'context-doctor', 'security-audit', 'session-health', 'fail-log', 'provenance', 'pointer-evidence')]
  [string]$Action,
  [string]$Profile = 'debug',
  [int]$Port = 3081,
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
  [string]$DshVersion = '',
  [string[]]$InputPath = @(),
  [string]$PointerPath = '',
  [string]$BaselinePath = '',
  [string]$IncidentPath = '',
  [string]$ReproPath = '',
  [string]$Root = '',
  [string]$DiagnosticsPath = '',
  [string]$CorrelationKey = '',
  [string]$PlanPath = '',
  [string]$CasePath = '',
  [string]$ReceiptPath = '',
  [string]$Cwd = '',
  [int]$RepairTimeoutSec = 60,
  [int]$FixtureTimeoutSec = 40,
  [switch]$NoBrowser,
  [switch]$NoInstall,
  [switch]$NoPluginInstall,
  [switch]$NoCrashGuard,
  [switch]$NoSupervisor,
  [int]$SupervisorIntervalSec = 2,
  [int]$SupervisorMaxWebMisses = 3,
  [switch]$SkipApi,
  [switch]$IncludeWorkspace,
  [switch]$IncludeUserConfig,
  [switch]$Force,
  [switch]$NoRescue,
  [switch]$ClearQuarantine,
  [switch]$ApplyModelPlan,
  [switch]$Automatic,
  [switch]$UseModel,
  [switch]$RestartAfterApply,
  [switch]$StrictBaseline,
  [switch]$ReproZip,
  [switch]$AutomaticRestore
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$packageRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$workbench = Join-Path $packageRoot 'tools\DSH-Workbench.ps1'
$suite = Join-Path $packageRoot 'tools\DSH-ProvenanceSuite.ps1'

function Get-NestedExitCode {
  param([bool]$InvocationSucceeded = $true)
  $variable = Get-Variable -Name LASTEXITCODE -ErrorAction SilentlyContinue
  $exitCode = if ($null -eq $variable -or $null -eq $variable.Value) { 0 } else { [int]$variable.Value }
  if (-not $InvocationSucceeded -and $exitCode -eq 0) { return 1 }
  return $exitCode
}

try {
  # dsh-doctor's most useful property is a stable read-only command that is
  # still available when the Web process is down. Keep that UX shape while
  # reusing this project's bounded cross-layer incident collector. The
  # collector writes only its local report; it never repairs or executes a
  # Tool as part of this alias.
  if ($Action -eq 'doctor') { $Action = 'incident-capture' }
  $traceActions = @('trace-contract', 'trace-eval', 'trace-live', 'trace-baseline', 'trace-profile')
  if ($Action -in $traceActions) {
    $traceAction = switch ($Action) {
      'trace-contract' { 'contract' }
      'trace-eval' { 'eval' }
      'trace-live' { 'live' }
      'trace-baseline' { 'baseline' }
      'trace-profile' { 'profile' }
    }
    $traceScript = Join-Path $packageRoot 'tools\DSH-TraceEval.ps1'
    $traceArguments = @{
      Action = $traceAction
      InputPath = if ($Action -eq 'pointer-evidence' -and -not [string]::IsNullOrWhiteSpace($PointerPath)) { $PointerPath } elseif ($InputPath.Count -gt 0) { $InputPath[0] } else { '' }
      BaselinePath = $BaselinePath
      CasePath = $CasePath
      SessionId = $SessionId
      HostName = $HostName
      Port = $Port
      MaxMessages = $MaxMessages
      StrictBaseline = $StrictBaseline
    }
    $LASTEXITCODE = 0
    & $traceScript @traceArguments
    $nestedSucceeded = $?
    exit (Get-NestedExitCode -InvocationSucceeded $nestedSucceeded)
  }
  if ($Action -eq 'trace-autopsy') {
    if ($InputPath.Count -eq 0 -or [string]::IsNullOrWhiteSpace($InputPath[0])) { throw '-InputPath is required for trace-autopsy' }
    if (-not (Test-Path -LiteralPath $InputPath[0] -PathType Leaf)) { throw "trace input does not exist: $($InputPath[0])" }
    Import-Module (Join-Path $packageRoot 'tools\DSH-TraceAutopsy.psm1') -Force
    $traceInput = Get-Content -LiteralPath $InputPath[0] -Raw -Encoding UTF8 | ConvertFrom-Json
    $autopsy = Invoke-DshTraceAutopsy -InputObject $traceInput
    $autopsy | ConvertTo-Json -Depth 30
    $autopsyStatus = [string]$autopsy.status
    $autopsyExitCode = 0
    if ($autopsyStatus -eq 'INVALID') { $autopsyExitCode = 1 }
    exit $autopsyExitCode
  }
  if ($Action -eq 'known-good-fixture') {
    $knownGoodFixture = Join-Path $packageRoot 'tools\Test-DSHKnownGood.ps1'
    $LASTEXITCODE = 0
    & $knownGoodFixture
    $nestedSucceeded = $?
    exit (Get-NestedExitCode -InvocationSucceeded $nestedSucceeded)
  }
  if ($Action -in @('known-good-list', 'known-good-save', 'known-good-restore')) {
    Import-Module (Join-Path $packageRoot 'tools\DSH-KnownGood.psm1') -Force
    $knownGoodArguments = @{
      Profile = $Profile
      DshHome = $DshHome
      CheckpointRoot = $SnapshotRoot
      StateRoot = $StateRoot
      DshVersion = $DshVersion
      Label = $Label
    }
    if ($Action -eq 'known-good-list') {
      Get-DshKnownGoodCheckpoints @knownGoodArguments | ConvertTo-Json -Depth 20
      exit 0
    }
    if ($Action -eq 'known-good-save') {
      Save-DshKnownGoodCheckpoint @knownGoodArguments | ConvertTo-Json -Depth 20
      exit 0
    }
    if ([string]::IsNullOrWhiteSpace($SnapshotId)) { throw '-SnapshotId is required for known-good-restore' }
    if (-not $Force) { throw 'known-good-restore changes DSH configuration; pass -Force after reviewing the checkpoint' }
    $knownGoodArguments.Remove('DshVersion')
    $knownGoodArguments.Remove('Label')
    $knownGoodArguments.CheckpointId = $SnapshotId
    $knownGoodArguments.BaseUrl = "http://$HostName`:$Port/"
    $knownGoodArguments.FailedPluginId = $PluginId
    if ($AutomaticRestore) { $knownGoodArguments.Automatic = $true }
    if ($Force) { $knownGoodArguments.Force = $true }
    Restore-DshKnownGoodCheckpoint @knownGoodArguments | ConvertTo-Json -Depth 30
    exit 0
  }
  if ($Action -in @('live-api-fixture', 'trace-autopsy-fixture', 'crash-fixture', 'runtime-supervisor-fixture')) {
    $fixture = switch ($Action) {
      'live-api-fixture' { Join-Path $packageRoot 'tools\Test-DSHLiveApi.ps1' }
      'trace-autopsy-fixture' { Join-Path $packageRoot 'tools\Test-DSHTraceAutopsy.ps1' }
      'crash-fixture' { Join-Path $packageRoot 'tools\Test-DSHCrashGuard.ps1' }
      default { Join-Path $packageRoot 'tools\Test-DSHRuntimeSupervisor.ps1' }
    }
    $LASTEXITCODE = 0
    if ($Action -in @('crash-fixture', 'runtime-supervisor-fixture')) {
      & $fixture -TimeoutSec $FixtureTimeoutSec
    } else {
      & $fixture
    }
    $nestedSucceeded = $?
    exit (Get-NestedExitCode -InvocationSucceeded $nestedSucceeded)
  }
  if ($Action -eq 'incident-capture') {
    $incidentScript = Join-Path $packageRoot 'tools\DSH-Incident.ps1'
    $incidentArguments = @{
      Profile = $Profile
      DshHome = $DshHome
      Port = $Port
      HostName = $HostName
      Workspace = $Workspace
      StateRoot = $StateRoot
      SessionId = $SessionId
      MaxMessages = $MaxMessages
      ExpectedModel = $ExpectedModel
      RuntimeRoot = $RuntimeRoot
      SkipApi = $SkipApi
      PointerPath = $PointerPath
      CorrelationKey = $CorrelationKey
      OutputPath = $IncidentPath
    }
    $LASTEXITCODE = 0
    & $incidentScript @incidentArguments
    $nestedSucceeded = $?
    exit (Get-NestedExitCode -InvocationSucceeded $nestedSucceeded)
  }
  if ($Action -eq 'incident-correlation') {
    if ($InputPath.Count -eq 0) { throw '-InputPath is required for incident-correlation; pass one or more JSON fragment paths' }
    Import-Module (Join-Path $packageRoot 'tools\DSH-IncidentCorrelation.psm1') -Force
    $correlationReport = Invoke-DshIncidentCorrelation -InputPath @($InputPath)
    $correlationReport | ConvertTo-Json -Depth 30
    exit 0
  }
  if ($Action -eq 'repro-export') {
    if ($InputPath.Count -eq 0) { throw '-InputPath is required for repro-export' }
    if ([string]::IsNullOrWhiteSpace($ReproPath)) { throw '-ReproPath is required for repro-export' }
    $reproScript = Join-Path $packageRoot 'tools\DSH-Repro.ps1'
    $reproArguments = @{
      InputPath = @($InputPath)
      OutputPath = $ReproPath
      Zip = $ReproZip
      Force = $Force
    }
    $LASTEXITCODE = 0
    & $reproScript @reproArguments
    $nestedSucceeded = $?
    exit (Get-NestedExitCode -InvocationSucceeded $nestedSucceeded)
  }
  if ($Action -eq 'self-repair') {
    $selfRepairScript = Join-Path $packageRoot 'tools\DSH-SelfRepair.ps1'
    $selfRepairArguments = @{
      Action = 'recover'
      Profile = $Profile
      Port = $Port
      HostName = $HostName
      StateRoot = $StateRoot
      DshHome = $DshHome
      DiagnosticsPath = $DiagnosticsPath
      PlanPath = $PlanPath
      SessionId = $SessionId
      Cwd = $Cwd
      TimeoutSec = $RepairTimeoutSec
      Automatic = $Automatic
      UseModel = $UseModel
      RestartAfterApply = $RestartAfterApply
    }
    $LASTEXITCODE = 0
    & $selfRepairScript @selfRepairArguments
    $nestedSucceeded = $?
    exit (Get-NestedExitCode -InvocationSucceeded $nestedSucceeded)
  }
  $suiteActions = @('context-doctor', 'security-audit', 'session-health', 'fail-log', 'provenance', 'pointer-evidence')
  if ($Action -in $suiteActions) {
    $arguments = @{
      Action = $Action
      DshHome = $DshHome
      Profile = $Profile
      StateRoot = $StateRoot
      InputPath = if ($InputPath.Count -gt 0) { $InputPath[0] } else { '' }
      Root = if ([string]::IsNullOrWhiteSpace($Root)) { $Workspace } else { $Root }
      IncludeWorkspace = $IncludeWorkspace
      IncludeUserConfig = $IncludeUserConfig
      Port = $Port
      HostName = $HostName
      Label = $Label
    }
    $LASTEXITCODE = 0
    & $suite @arguments
    $nestedSucceeded = $?
    exit (Get-NestedExitCode -InvocationSucceeded $nestedSucceeded)
  }

  $arguments = @{
    Action = $Action
    Profile = $Profile
    Port = $Port
    HostName = $HostName
    Workspace = $Workspace
    StateRoot = $StateRoot
    DshHome = $DshHome
    RuntimeRoot = $RuntimeRoot
    SnapshotRoot = $SnapshotRoot
    SnapshotId = $SnapshotId
    Label = $Label
    PluginId = $PluginId
    SessionId = $SessionId
    MaxMessages = $MaxMessages
    ExpectedModel = $ExpectedModel
    PointerPath = $PointerPath
    DiagnosticsPath = $DiagnosticsPath
    PlanPath = $PlanPath
    ReceiptPath = $ReceiptPath
    Cwd = $Cwd
    RepairTimeoutSec = $RepairTimeoutSec
    NoBrowser = $NoBrowser
    NoInstall = $NoInstall
    NoPluginInstall = $NoPluginInstall
    NoCrashGuard = $NoCrashGuard
    NoSupervisor = $NoSupervisor
    SupervisorIntervalSec = $SupervisorIntervalSec
    SupervisorMaxWebMisses = $SupervisorMaxWebMisses
    SkipApi = $SkipApi
    Force = $Force
    NoRescue = $NoRescue
    ClearQuarantine = $ClearQuarantine
    ApplyModelPlan = $ApplyModelPlan
    Automatic = $Automatic
    UseModel = $UseModel
    RestartAfterApply = $RestartAfterApply
  }
  if ($null -ne $AtSeq -and $AtSeq.HasValue) { $arguments.AtSeq = $AtSeq }
  $LASTEXITCODE = 0
  & $workbench @arguments
  $nestedSucceeded = $?
  exit (Get-NestedExitCode -InvocationSucceeded $nestedSucceeded)
} catch {
  [ordered]@{ result = 'FAIL'; action = $Action; error = $_.Exception.Message } | ConvertTo-Json -Depth 12
  exit 1
}
