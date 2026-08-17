[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][ValidateSet('plan', 'assist', 'recover', 'apply', 'revert')][string]$Action,
  [string]$Profile = 'debug',
  [int]$Port = 3081,
  [string]$HostName = '127.0.0.1',
  [string]$StateRoot = '',
  [string]$DshHome = '',
  [string]$DiagnosticsPath = '',
  [string]$PlanPath = '',
  [string]$ReceiptPath = '',
  [string]$SessionId = '',
  [string]$Cwd = '',
  [int]$TimeoutSec = 60,
  [switch]$Force,
  [switch]$ApplyModelPlan,
  [switch]$Automatic,
  [switch]$UseModel,
  [switch]$RestartAfterApply
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $root 'DSH-PowerShell.ps1')
Import-Module (Join-Path $root 'DSH-Repair.psm1') -Force
Import-Module (Join-Path $root 'DSH-State.psm1') -Force

function Resolve-RepairDshHome {
  return Resolve-DshDebugHome -DshHome $DshHome
}

function Resolve-RepairStateRoot {
  if (-not [string]::IsNullOrWhiteSpace($StateRoot)) { return [IO.Path]::GetFullPath($StateRoot) }
  return Resolve-DshDebugStateRoot -DshHome (Resolve-RepairDshHome) -Profile $Profile -Port $Port
}

function Read-JsonFile {
  param([Parameter(Mandatory = $true)][string]$Path)
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "JSON file does not exist: $Path" }
  try { return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json) }
  catch { throw "JSON file cannot be parsed: $Path; $($_.Exception.Message)" }
}

function Invoke-ChildJsonScript {
  param(
    [Parameter(Mandatory = $true)][string]$ScriptPath,
    [Parameter(Mandatory = $true)][hashtable]$Arguments
  )
  $output = & (Get-DshPowerShellPath) -NoLogo -NoProfile -ExecutionPolicy Bypass -File $ScriptPath @Arguments 2>&1
  $exitCode = $LASTEXITCODE
  $text = ($output | Out-String).Trim()
  if ($exitCode -ne 0) { throw "diagnostics command failed (exit $exitCode): $text" }
  try { return ($text | ConvertFrom-Json) } catch { throw "diagnostics command returned invalid JSON: $text" }
}

function Read-RepairDiagnostics {
  if (-not [string]::IsNullOrWhiteSpace($DiagnosticsPath)) {
    return Read-JsonFile -Path $DiagnosticsPath
  }
  $diagnosticsScript = Join-Path $root 'Get-DSH-Diagnostics.ps1'
  $arguments = @{ Profile = $Profile; Port = $Port; StateRoot = (Resolve-RepairStateRoot) }
  if (-not [string]::IsNullOrWhiteSpace($SessionId)) { $arguments.SessionId = $SessionId }
  $value = Invoke-ChildJsonScript -ScriptPath $diagnosticsScript -Arguments $arguments
  $wrappedValue = Get-DshRepairProperty -Object $value -Name 'value'
  if ($null -ne $wrappedValue) { return $wrappedValue }
  return $value
}

function Write-RepairOutput {
  param([string]$Result, [string]$Message, $Value = $null)
  [ordered]@{
    result = $Result
    action = $Action
    message = $Message
    value = $Value
  } | ConvertTo-Json -Depth 24
}

function Test-RepairWebReadiness {
  param([Parameter(Mandatory = $true)][string]$BaseUrl)
  try {
    $response = Invoke-WebRequest -UseBasicParsing -Uri $BaseUrl -Method Get -TimeoutSec 5
    $ready = [int]$response.StatusCode -ge 200 -and [int]$response.StatusCode -lt 400
    return [ordered]@{
      status = if ($ready) { 'ready' } else { 'not-ready' }
      ready = $ready
      statusCode = [int]$response.StatusCode
      responseBodyStored = $false
    }
  } catch {
    return [ordered]@{
      status = 'unavailable'
      ready = $false
      statusCode = $null
      responseBodyStored = $false
    }
  }
}

function Invoke-RepairRestart {
  param(
    [Parameter(Mandatory = $true)][string]$BaseUrl,
    [Parameter(Mandatory = $true)][string]$ResolvedDshHome,
    [Parameter(Mandatory = $true)][string]$ResolvedStateRoot
  )
  $launcher = Join-Path $root 'Start-DSH.ps1'
  $arguments = @(
    '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $launcher,
    '-Profile', $Profile, '-Port', [string]$Port, '-HostName', $HostName,
    '-NoBrowser', '-NoInstall', '-EnableCrashGuard', '-StateRoot', $ResolvedStateRoot
  )
  $previousDshHome = $env:DSH_HOME
  try {
    $env:DSH_HOME = $ResolvedDshHome
    $output = & (Get-DshPowerShellPath) @arguments 2>&1
    $exitCode = $LASTEXITCODE
  } finally {
    if ($null -eq $previousDshHome) { Remove-Item Env:DSH_HOME -ErrorAction SilentlyContinue } else { $env:DSH_HOME = $previousDshHome }
  }
  $readiness = Test-RepairWebReadiness -BaseUrl $BaseUrl
  return [ordered]@{
    requested = $true
    launcherExitCode = [int]$exitCode
    status = if ($exitCode -eq 0 -and $readiness.ready) { 'recovered' } else { 'degraded' }
    web = $readiness
    launcherOutputStored = $false
    launcherErrorObserved = $exitCode -ne 0
  }
}

function Invoke-RepairRecoveryCycle {
  $resolvedDshHome = Resolve-RepairDshHome
  $resolvedStateRoot = Resolve-RepairStateRoot
  $diagnostics = Read-RepairDiagnostics
  $deterministicPlan = New-DshRepairPlan -Diagnostics $diagnostics -Profile $Profile -StateRoot $resolvedStateRoot -Reason 'bounded recovery cycle from metadata-only diagnostics'
  $selectedPlan = $deterministicPlan
  $planSource = 'deterministic'
  $modelAssist = $null
  if ($UseModel) {
    try {
      $modelAssist = Invoke-DshModelRepairAssist -BaseUrl "http://$HostName`:$Port/" -Diagnostics $diagnostics -Profile $Profile -SessionId $SessionId -Cwd $Cwd -TimeoutSec $TimeoutSec
      if ($modelAssist.status -eq 'plan-ready' -and $null -ne $modelAssist.plan) {
        $selectedPlan = $modelAssist.plan
        $planSource = 'dsh-model-validated'
      }
    } catch {
      $modelAssist = [ordered]@{ status = 'unavailable'; plan = $null; modelResponseStored = $false; reason = 'model planner failed closed' }
    }
  }
  $written = $null
  if (-not [string]::IsNullOrWhiteSpace($PlanPath)) { $written = Write-DshRepairPlan -Plan $selectedPlan -Path $PlanPath }
  $planCheck = Test-DshRepairPlan -Plan $selectedPlan
  if (-not $planCheck.valid) { throw "recovery plan rejected: $($planCheck.errors -join '; ')" }
  $operations = @(Get-DshRepairProperty -Object $selectedPlan -Name 'operations')
  $mutations = @($operations | Where-Object { [string](Get-DshRepairProperty -Object $_ -Name 'kind') -eq 'quarantine-plugin' })
  $applied = $null
  if ($Automatic -and $mutations.Count -gt 0) {
    $applied = Invoke-DshRepairPlan -Plan $selectedPlan -Profile $Profile -DshHome $resolvedDshHome -StateRoot $resolvedStateRoot -Force
  }
  $restart = if ($RestartAfterApply) {
    if (-not $Automatic) { throw '-RestartAfterApply requires -Automatic' }
    if ($null -eq $applied -or (Get-DshRepairProperty -Object $applied -Name 'changed') -ne $true) {
      [ordered]@{ requested = $true; status = 'not-started'; reason = 'no repair mutation was applied'; web = [ordered]@{ status = 'not-requested'; ready = $false; responseBodyStored = $false } }
    } else {
      Invoke-RepairRestart -BaseUrl "http://$HostName`:$Port/" -ResolvedDshHome $resolvedDshHome -ResolvedStateRoot $resolvedStateRoot
    }
  } else {
    [ordered]@{ requested = $false; status = 'not-requested'; web = [ordered]@{ status = 'not-requested'; ready = $false; responseBodyStored = $false } }
  }
  $changed = $null -ne $applied -and (Get-DshRepairProperty -Object $applied -Name 'changed') -eq $true
  return [ordered]@{
    status = if ($restart.status -eq 'recovered') { 'recovered' } elseif ($changed) { 'repaired-restart-required' } else { 'no-safe-mutation' }
    planSource = $planSource
    planPath = $written
    plan = $selectedPlan
    planContract = $planCheck
    modelAssist = if ($null -eq $modelAssist) { [ordered]@{ status = 'not-requested'; modelResponseStored = $false } } else { $modelAssist }
    automaticRequested = $Automatic -eq $true
    applied = $applied
    restart = $restart
    safety = [ordered]@{
      modelHasNoExecutionAuthority = $true
      workspaceChanged = $false
      profileManifestChanged = $false
      dangerFullAccessChanged = $false
      onlyGuardFilesMayChange = $true
      restartIsExplicit = $RestartAfterApply -eq $true
    }
  }
}

try {
  switch ($Action) {
    'plan' {
      $diagnostics = Read-RepairDiagnostics
      $plan = New-DshRepairPlan -Diagnostics $diagnostics -Profile $Profile -StateRoot (Resolve-RepairStateRoot) -Reason 'deterministic plan from bounded diagnostics'
      $written = $null
      if (-not [string]::IsNullOrWhiteSpace($PlanPath)) { $written = Write-DshRepairPlan -Plan $plan -Path $PlanPath }
      Write-RepairOutput -Result 'PASS' -Message 'Generated an advisory repair plan; no DSH or workspace state was changed.' -Value ([ordered]@{ plan = $plan; planPath = $written })
      exit 0
    }
    'assist' {
      $diagnostics = Read-RepairDiagnostics
      $baseUrl = "http://$HostName`:$Port/"
      $assist = Invoke-DshModelRepairAssist -BaseUrl $baseUrl -Diagnostics $diagnostics -Profile $Profile -SessionId $SessionId -Cwd $Cwd -TimeoutSec $TimeoutSec
      $written = $null
      if ($null -ne $assist.plan -and -not [string]::IsNullOrWhiteSpace($PlanPath)) { $written = Write-DshRepairPlan -Plan $assist.plan -Path $PlanPath }
      if ($ApplyModelPlan) {
        if ($null -eq $assist.plan) { throw 'ApplyModelPlan was requested, but the model did not return a valid plan' }
        if (-not $Force) { throw 'ApplyModelPlan changes guard state; pass -Force after reviewing the model plan' }
        $applied = Invoke-DshRepairPlan -Plan $assist.plan -Profile $Profile -DshHome (Resolve-RepairDshHome) -StateRoot (Resolve-RepairStateRoot) -Force
        $assist.applied = $applied
      }
      $assist.planPath = $written
      $message = if ($assist.status -eq 'plan-ready') { 'The DSH model returned a validated advisory plan; no operation was applied unless ApplyModelPlan and Force were both supplied.' } else { 'The DSH model did not provide an applyable plan; no operation was applied.' }
      $assistResult = if ($assist.status -eq 'plan-ready') { 'PASS' } else { 'WARN' }
      Write-RepairOutput -Result $assistResult -Message $message -Value $assist
      exit 0
    }
    'recover' {
      if ($RestartAfterApply -and -not $Automatic) { throw '-RestartAfterApply requires -Automatic' }
      $recovery = Invoke-RepairRecoveryCycle
      $recoveryResult = if ($recovery.status -eq 'recovered' -or $recovery.status -eq 'repaired-restart-required') { 'PASS' } else { 'WARN' }
      $message = if ($recovery.status -eq 'recovered') {
        'The bounded recovery cycle quarantined an observed third-party plugin and verified Web readiness after one explicit restart.'
      } elseif ($recovery.status -eq 'repaired-restart-required') {
        'The bounded recovery cycle applied only the reviewed guard mutation; restart was not requested.'
      } else {
        'No safe third-party quarantine mutation was indicated by the supplied metadata-only diagnostics.'
      }
      Write-RepairOutput -Result $recoveryResult -Message $message -Value $recovery
      exit 0
    }
    'apply' {
      if ([string]::IsNullOrWhiteSpace($PlanPath)) { throw '-PlanPath is required for repair apply' }
      $plan = Read-DshRepairPlan -Path $PlanPath
      $value = Invoke-DshRepairPlan -Plan $plan -Profile $Profile -DshHome (Resolve-RepairDshHome) -StateRoot (Resolve-RepairStateRoot) -Force:$Force
      Write-RepairOutput -Result 'PASS' -Message 'Applied only the allowlisted, reversible repair operations.' -Value $value
      exit 0
    }
    'revert' {
      if ([string]::IsNullOrWhiteSpace($ReceiptPath)) { throw '-ReceiptPath is required for repair revert' }
      $value = Restore-DshRepairReceipt -ReceiptPath $ReceiptPath -Force:$Force
      Write-RepairOutput -Result 'PASS' -Message 'Reverted the guard files captured by the repair receipt.' -Value $value
      exit 0
    }
  }
} catch {
  Write-RepairOutput -Result 'FAIL' -Message $_.Exception.Message
  exit 1
}
