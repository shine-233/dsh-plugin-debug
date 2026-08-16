[CmdletBinding()]
param(
  [int]$Port = 3080,
  [string]$HostName = '127.0.0.1',
  [string]$Profile = 'web',
  [string]$Workspace = '',
  [switch]$NoBrowser,
  [switch]$NoInstall,
  [switch]$NoPluginInstall,
  [switch]$NoIsolateOnConflict,
  [switch]$NoErrorDialog,
  [switch]$EnableAgents,
  [string]$AgentsPatchPath = '',
  [switch]$InstallOnly,
  [switch]$ForcePluginInstall,
  [switch]$KeepAlive,
  [int]$SupervisorIntervalSec = 2,
  [int]$SupervisorMaxWebMisses = 3,
  [switch]$ShowWindow,
  [int]$StartupTimeoutSec = 90,
  [string]$StateRoot = '',
  [switch]$EnableCrashGuard,
  [int]$GuardThreshold = 1
)

$ErrorActionPreference = 'Stop'
$LauncherRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$BundleRoot = Split-Path -Parent $LauncherRoot
$runtimeOverride = [Environment]::GetEnvironmentVariable('DSH_RUNTIME_ROOT')
$RuntimeDir = if ([string]::IsNullOrWhiteSpace($runtimeOverride)) {
  Join-Path $LauncherRoot 'runtime'
} else {
  [IO.Path]::GetFullPath($runtimeOverride)
}
$StateModulePath = Join-Path $LauncherRoot 'DSH-State.psm1'
Import-Module $StateModulePath -Force
$DefaultDshHome = Resolve-DshDebugHome
$DefaultStateBase = Join-Path $DefaultDshHome 'dsh-plugin-debug\state'
$StateRootWasExplicit = -not [string]::IsNullOrWhiteSpace($StateRoot)
if (-not $StateRootWasExplicit) {
  $StateRoot = Resolve-DshDebugStateRoot -DshHome $DefaultDshHome -Profile $Profile -Port $Port
}
$LogDir = Join-Path $StateRoot 'logs'
$LauncherLog = Join-Path $LogDir 'launcher.log'
$DshStdoutLog = Join-Path $LogDir 'dsh.stdout.log'
$DshStderrLog = Join-Path $LogDir 'dsh.stderr.log'
$InstallLog = Join-Path $LogDir 'dsh-install.log'
$PidFile = Join-Path $StateRoot 'dsh-web.pid.json'
$GuardStateFile = Join-Path $StateRoot 'guard-state.json'
$GuardPatch = Join-Path $StateRoot 'guard.patch.yml'
$SupervisorStateFile = Join-Path $StateRoot 'supervisor-state.json'
$StartupIncidentFile = Join-Path $StateRoot 'startup-incident.json'
$GuardModulePath = Join-Path $LauncherRoot 'DSH-Guard.psm1'
$AgentsPatch = if ([string]::IsNullOrWhiteSpace($AgentsPatchPath)) { Join-Path $LauncherRoot 'combined-agents.patch.yml' } else { [IO.Path]::GetFullPath($AgentsPatchPath) }
$Url = "http://$HostName`:$Port/"

if ([string]::IsNullOrWhiteSpace($Workspace)) {
  $Workspace = Join-Path $env:USERPROFILE 'Documents\projects'
  if (-not (Test-Path -LiteralPath $Workspace -PathType Container)) {
    $Workspace = $LauncherRoot
  }
}
function Ensure-Directory {
  param([Parameter(Mandatory = $true)][string]$Path)
  if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
  }
}

function Get-FreeDshPort {
  param([Parameter(Mandatory = $true)][int]$StartingPort)

  $address = [Net.IPAddress]::Loopback
  $parsedAddress = $null
  if ([Net.IPAddress]::TryParse($HostName, [ref]$parsedAddress)) {
    $address = $parsedAddress
  }
  $lastPort = [Math]::Min(65535, $StartingPort + 32)
  for ($candidate = [Math]::Max(1, $StartingPort + 1); $candidate -le $lastPort; $candidate++) {
    $listener = $null
    try {
      $listener = [Net.Sockets.TcpListener]::new($address, $candidate)
      $listener.Start()
      return $candidate
    } catch {
      # Another process won this candidate between the probe and Start().
    } finally {
      if ($null -ne $listener) {
        try { $listener.Stop() } catch { }
      }
    }
  }
  throw "无法为隔离的 dsh-plugin-debug 实例找到空闲端口（起点 $StartingPort）。"
}

function Set-DshLaunchTarget {
  param(
    [Parameter(Mandatory = $true)][int]$NewPort,
    [Parameter(Mandatory = $true)][string]$NewProfile
  )

  $previousStateRoot = $script:StateRoot
  $script:Port = $NewPort
  $script:Profile = $NewProfile
  $script:Url = "http://$HostName`:$NewPort/"
  if ($StateRootWasExplicit) {
    $script:StateRoot = Join-Path $previousStateRoot "isolated-$NewProfile-$NewPort"
  } else {
    $script:StateRoot = Resolve-DshDebugStateRoot -DshHome $DefaultDshHome -Profile $NewProfile -Port $NewPort
  }
  $script:LogDir = Join-Path $script:StateRoot 'logs'
  $script:LauncherLog = Join-Path $script:LogDir 'launcher.log'
  $script:DshStdoutLog = Join-Path $script:LogDir 'dsh.stdout.log'
  $script:DshStderrLog = Join-Path $script:LogDir 'dsh.stderr.log'
  $script:InstallLog = Join-Path $script:LogDir 'dsh-install.log'
  $script:PidFile = Join-Path $script:StateRoot 'dsh-web.pid.json'
  $script:GuardStateFile = Join-Path $script:StateRoot 'guard-state.json'
  $script:GuardPatch = Join-Path $script:StateRoot 'guard.patch.yml'
  $script:SupervisorStateFile = Join-Path $script:StateRoot 'supervisor-state.json'
  $script:StartupIncidentFile = Join-Path $script:StateRoot 'startup-incident.json'
}

function Try-IsolateDshConflict {
  param([Parameter(Mandatory = $true)][string]$Reason)
  if ($NoIsolateOnConflict) { return $false }

  $requestedProfile = [string]$Profile
  $requestedPort = [int]$Port
  $alternatePort = Get-FreeDshPort -StartingPort $requestedPort
  $suffix = "debug-$alternatePort"
  $alternateProfile = "$requestedProfile-$suffix"
  if ($alternateProfile.Length -gt 64) {
    $alternateProfile = $alternateProfile.Substring(0, 64).TrimEnd('-', '_', '.')
  }
  Write-LauncherLog "检测到外部 DSH 占用 $HostName`:$requestedPort 且 Profile=$requestedProfile 尚未安装 dsh-plugin-debug；不修改该实例，改用隔离 Profile=$alternateProfile port=$alternatePort（$Reason）。"
  Set-DshLaunchTarget -NewPort $alternatePort -NewProfile $alternateProfile
  Ensure-Directory $LogDir
  Write-LauncherLog "dsh-plugin-debug 隔离启动目标已切换：原 Profile=$requestedProfile 原 port=$requestedPort；当前 Profile=$Profile port=$Port。"
  return $true
}

function Write-LauncherLog {
  param([Parameter(Mandatory = $true)][string]$Message)
  $line = "$(Get-Date -Format o) $Message"
  Add-Content -LiteralPath $LauncherLog -Value $line -Encoding UTF8
  if ($ShowWindow) {
    Write-Host $Message
  }
}

$script:LaunchMutex = $null
$script:LaunchMutexHeld = $false
$script:BrowserOpened = $false
$script:StartupIncidentId = [guid]::NewGuid().ToString('N')
$script:StartupFailureStatus = 'failed'
$script:StartupFailureReason = 'startup-failure'

function Get-DshLaunchMutexName {
  $identity = "$LauncherRoot|$Profile|$HostName|$Port"
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($identity)
    $hash = ([System.BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '')
  } finally {
    $sha.Dispose()
  }
  return "Local\DSH-OneClick-$hash"
}

function Release-DshLaunchLock {
  if ($null -eq $script:LaunchMutex) { return }
  try {
    if ($script:LaunchMutexHeld) {
      $script:LaunchMutex.ReleaseMutex() | Out-Null
    }
  } catch {
    # The lock is process-scoped; preserve the original startup result if
    # releasing it reports that the process no longer owns the mutex.
  } finally {
    $script:LaunchMutex.Dispose()
    $script:LaunchMutex = $null
    $script:LaunchMutexHeld = $false
  }
}

function Enter-DshLaunchLock {
  param([Parameter(Mandatory = $true)][int]$TimeoutSec)

  $mutexName = Get-DshLaunchMutexName
  try {
    $script:LaunchMutex = New-Object -TypeName System.Threading.Mutex -ArgumentList @($false, $mutexName)
    try {
      $script:LaunchMutexHeld = $script:LaunchMutex.WaitOne([TimeSpan]::FromSeconds($TimeoutSec))
    } catch [System.Threading.AbandonedMutexException] {
      # An abandoned mutex is still acquired by this process. The previous
      # launcher has gone away, so it is safe to continue the preflight.
      $script:LaunchMutexHeld = $true
      Write-LauncherLog "接管已中止的启动锁：$mutexName"
    }
  } catch {
    Release-DshLaunchLock
    throw "无法取得 DSH 启动锁：$($_.Exception.Message)"
  }

  if (-not $script:LaunchMutexHeld) {
    Release-DshLaunchLock
    throw "等待同 profile/host/port 的其他启动器超时（${TimeoutSec}s）；详见 $LauncherLog"
  }
  Write-LauncherLog "已取得 DSH 启动锁（profile=$Profile host=$HostName port=$Port）。"
}

function Read-DshPidRecord {
  if (-not (Test-Path -LiteralPath $PidFile -PathType Leaf)) { return $null }
  try {
    $raw = Get-Content -LiteralPath $PidFile -Raw -Encoding UTF8 -ErrorAction Stop
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    $record = $raw | ConvertFrom-Json -ErrorAction Stop
    if ($null -eq $record.pid) { throw 'PID 记录缺少 pid' }
    return $record
  } catch {
    Write-LauncherLog "无法读取启动器 PID 记录，按未记录进程处理：$PidFile；$($_.Exception.Message)"
    return $null
  }
}

function Get-RecordedDshProcess {
  $record = Read-DshPidRecord
  if ($null -eq $record) { return $null }
  if ([string]$record.profile -ne $Profile -or
      [string]$record.host -ne $HostName -or
      [int]$record.port -ne $Port) {
    return $null
  }

  $recordPid = 0
  if (-not [int]::TryParse([string]$record.pid, [ref]$recordPid) -or $recordPid -lt 1) {
    Write-LauncherLog "忽略无效的启动器 PID 记录：$PidFile"
    return $null
  }

  try {
    $candidate = Get-Process -Id $recordPid -ErrorAction Stop
    $candidate.Refresh()
    if ($candidate.HasExited) { return $null }
  } catch {
    return $null
  }

  # New records carry the actual process start time so a recycled Windows PID
  # cannot be mistaken for the DSH child. Legacy records remain readable and
  # are still accepted when their profile/host/port and PID match.
  $recordedStart = [string]$record.processStartTimeUtc
  if (-not [string]::IsNullOrWhiteSpace($recordedStart)) {
    try {
      $expectedStart = [DateTime]::Parse($recordedStart).ToUniversalTime()
      $actualStart = $candidate.StartTime.ToUniversalTime()
      if ([Math]::Abs(($actualStart - $expectedStart).TotalSeconds) -gt 2) {
        Write-LauncherLog "忽略过期的启动器 PID 记录：pid=$recordPid profile=$Profile port=$Port"
        return $null
      }
    } catch {
      Write-LauncherLog "无法核验启动器 PID 的启动时间，按未记录进程处理：pid=$recordPid；$($_.Exception.Message)"
      return $null
    }
  }

  return [PSCustomObject]@{
    Process = $candidate
    Record = $record
  }
}

function Stop-RecordedDshProcess {
  param(
    [Parameter(Mandatory = $true)][System.Diagnostics.Process]$Candidate,
    [Parameter(Mandatory = $true)][string]$Reason
  )

  try {
    $Candidate.Refresh()
    if ($Candidate.HasExited) { return $false }
  } catch {
    Write-LauncherLog "未停止 PID=$($Candidate.Id)：无法读取进程状态（$Reason；$($_.Exception.Message)）"
    return $false
  }

  $tracked = Get-RecordedDshProcess
  if ($null -eq $tracked -or $tracked.Process.Id -ne $Candidate.Id) {
    Write-LauncherLog "未停止 PID=$($Candidate.Id)：PID 记录不匹配，避免影响非本启动器进程（$Reason）。"
    return $false
  }

  try {
    $Candidate.Refresh()
    if (-not $Candidate.HasExited) {
      Stop-Process -Id $Candidate.Id -Force -ErrorAction Stop
      Write-LauncherLog "已停止本启动器记录的 DSH 子进程 PID=$($Candidate.Id)（$Reason）。"
      return $true
    }
  } catch {
    Write-LauncherLog "停止本启动器记录的 DSH 子进程失败 PID=$($Candidate.Id)（$Reason）：$($_.Exception.Message)"
  }
  return $false
}

function Wait-RecordedDshWebReady {
  param([Parameter(Mandatory = $true)][System.Diagnostics.Process]$Candidate)

  for ($second = 0; $second -lt $StartupTimeoutSec; $second++) {
    try {
      $Candidate.Refresh()
      if ($Candidate.HasExited) {
        throw "本启动器记录的 DSH 进程已在 Web 就绪前退出，退出码 $($Candidate.ExitCode)；详见 $DshStderrLog"
      }
    } catch [System.InvalidOperationException] {
      throw "本启动器记录的 DSH 进程已在 Web 就绪前退出；详见 $DshStderrLog"
    }

    $probe = Get-WebProbe
    if ($probe.Reachable -and $probe.IsDsh) {
      return $probe
    }
    if ($probe.Reachable -and -not $probe.IsDsh) {
      throw "本启动器记录的 DSH 进程对应端口返回了非 DSH 页面（HTTP $($probe.StatusCode)）；详见 $DshStderrLog"
    }
    if ($second + 1 -lt $StartupTimeoutSec) {
      Start-Sleep -Seconds 1
    }
  }
  throw "等待已记录的 DSH Web 就绪超时（${StartupTimeoutSec}s）；详见 $DshStderrLog"
}

$GuardAvailable = $false
$GuardState = $null
$GuardManifest = $null
$script:LastGuardReadyResult = $null
$process = $null

function Initialize-DshCrashGuard {
  if (-not $EnableCrashGuard) { return }
  if (-not (Test-Path -LiteralPath $GuardModulePath -PathType Leaf)) {
    $message = "crash guard was requested but its module is unavailable: $GuardModulePath"
    Write-LauncherLog $message
    throw $message
  }
  try {
    Import-Module $GuardModulePath -Force -ErrorAction Stop
    $manifestPath = Join-Path $env:DSH_HOME "profiles\$Profile\package.json"
    $script:GuardManifest = Read-DshProfileManifest -Path $manifestPath
    $script:GuardState = Read-DshGuardState -Path $GuardStateFile -Profile $Profile
    Ensure-Directory $StateRoot
    Write-DshGuardPatch -Path $GuardPatch -Entries (Get-DshGuardPatchEntries -State $script:GuardState)
    $script:GuardAvailable = $true
    $quarantined = @($script:GuardState.quarantined).Count
    Write-LauncherLog "crash guard ready: threshold=$GuardThreshold quarantined=$quarantined patch=$GuardPatch"
  } catch {
    $script:GuardAvailable = $false
    $script:GuardState = $null
    $script:GuardManifest = $null
    $message = "crash guard was requested but could not initialize: $($_.Exception.Message)"
    Write-LauncherLog $message
    throw $message
  }
}

function Get-DshGuardErrorText {
  if (-not (Test-Path -LiteralPath $DshStderrLog -PathType Leaf)) { return '' }
  try {
    $text = ((Get-Content -LiteralPath $DshStderrLog -Tail 240 -ErrorAction Stop) -join "`n")
    if ($text.Length -gt 24000) { return $text.Substring($text.Length - 24000) }
    return $text
  } catch {
    return ''
  }
}

function Register-DshGuardCandidates {
  param(
    [Parameter(Mandatory = $true)][object[]]$Candidates,
    [Parameter(Mandatory = $true)][string]$Source
  )
  if (-not $script:GuardAvailable -or $null -eq $script:GuardState) { return $false }
  $changed = $false
  $candidateSummary = @()
  foreach ($candidate in @($Candidates)) {
    if ($null -eq $candidate) { continue }
    Add-DshGuardFailure -State $script:GuardState -Candidate $candidate | Out-Null
    $candidateSummary += [string]$candidate.moduleName
    $key = if (-not [string]::IsNullOrWhiteSpace([string]$candidate.entryId)) { [string]$candidate.entryId } else { [string]$candidate.moduleName }
    $failure = @($script:GuardState.failures | Where-Object {
        ([string]$_.entryId -eq $key) -or ([string]$_.moduleName -eq [string]$candidate.moduleName)
      } | Select-Object -First 1)
    $alreadyQuarantined = @($script:GuardState.quarantined | Where-Object {
        ([string]$_.entryId -eq $key) -or ([string]$_.moduleName -eq [string]$candidate.moduleName)
      }).Count -gt 0
    if ($failure.Count -gt 0 -and [int]$failure[0].count -ge $GuardThreshold -and -not $alreadyQuarantined) {
      Add-DshGuardQuarantine -State $script:GuardState -Candidate $candidate | Out-Null
      $changed = $true
      Write-LauncherLog "crash guard quarantined module=$($candidate.moduleName) source=$Source attribution=$($candidate.attribution)"
    }
  }
  $script:GuardState.lastRun = [PSCustomObject]@{
    at = (Get-Date).ToUniversalTime().ToString('o')
    source = $Source
    candidates = @($candidateSummary | Sort-Object -Unique)
    changed = $changed
  }
  Write-DshGuardState -Path $GuardStateFile -State $script:GuardState
  Write-DshGuardPatch -Path $GuardPatch -Entries (Get-DshGuardPatchEntries -State $script:GuardState)
  return $changed
}

function Try-DshGuardStartupRecovery {
  param([Parameter(Mandatory = $true)][string]$ErrorText)
  if (-not $script:GuardAvailable -or $null -eq $script:GuardManifest) { return $false }
  $candidates = @(Get-DshStartupGuardCandidates -Manifest $script:GuardManifest -ErrorText $ErrorText)
  if ($candidates.Count -eq 0) {
    $fallback = Get-DshSingleStartupGuardCandidate -Manifest $script:GuardManifest -ErrorText $ErrorText
    if ($null -ne $fallback) {
      $candidates = @($fallback)
      Write-LauncherLog "crash guard used the single-safe-candidate startup fallback; this is heuristic evidence, not causal proof."
    }
  }
  if ($candidates.Count -eq 0) {
    Write-LauncherLog 'crash guard did not quarantine anything: startup failure was not attributable to one safe plugin.'
    return $false
  }
  return Register-DshGuardCandidates -Candidates $candidates -Source 'startup-failure'
}

function Invoke-DshGuardReadyCheck {
  if (-not $script:GuardAvailable -or $null -eq $script:GuardManifest) {
    return [ordered]@{
      restartRequested = $false
      status = 'unavailable'
      reason = 'crash-guard-unavailable'
      inventoryObserved = $false
      failedCount = 0
      candidateCount = 0
    }
  }
  try {
    $entries = @(Get-DshPluginInventory -BaseUrl $Url -TimeoutSec 5)
    $failed = @($entries | Where-Object { $_.fiberPhase -eq 'failed' })
    Write-LauncherLog "crash guard inventory observed: entries=$($entries.Count) failed=$($failed.Count)"
    $candidates = @(Get-DshGuardCandidates -Entries $entries -Manifest $script:GuardManifest)
    $changed = if ($candidates.Count -eq 0) { $false } else { Register-DshGuardCandidates -Candidates $candidates -Source 'plugin-inventory' }
    $status = if ($changed) { 'restart-requested' } elseif ($failed.Count -gt 0) { 'degraded' } else { 'healthy' }
    $reason = if ($changed) {
      'runtime-plugin-inventory-quarantine'
    } elseif ($failed.Count -gt 0 -and $candidates.Count -eq 0) {
      'runtime-plugin-failed-unresolved'
    } elseif ($failed.Count -gt 0) {
      'runtime-plugin-failed-after-quarantine'
    } else {
      'web-and-plugin-inventory-healthy'
    }
    return [ordered]@{
      restartRequested = $changed
      status = $status
      reason = $reason
      inventoryObserved = $true
      failedCount = $failed.Count
      candidateCount = $candidates.Count
    }
  } catch {
    Write-LauncherLog "crash guard inventory probe skipped: $($_.Exception.Message)"
    return [ordered]@{
      restartRequested = $false
      status = 'degraded'
      reason = 'runtime-plugin-inventory-unavailable'
      inventoryObserved = $false
      failedCount = 0
      candidateCount = 0
    }
  }
}

function Write-DshSupervisorState {
  param(
    [Parameter(Mandatory = $true)][string]$Status,
    [string]$Reason = '',
    [AllowNull()]$Snapshot = $null,
    [int]$RestartCount = 0
  )
  $state = [ordered]@{
    schemaVersion = 1
    kind = 'dsh-runtime-supervisor'
    status = $Status
    profile = $Profile
    host = $HostName
    port = $Port
    pid = if ($null -eq $process) { $null } else { [int]$process.Id }
    processStartTimeUtc = if ($null -eq $processStartTimeUtc) { $null } else { [string]$processStartTimeUtc }
    updatedAt = (Get-Date).ToUniversalTime().ToString('o')
    reason = if ([string]::IsNullOrWhiteSpace($Reason)) { $null } else { $Reason }
    keepAlive = $KeepAlive -eq $true
    restartCount = $RestartCount
    maxRestarts = 1
    intervalSec = $SupervisorIntervalSec
    snapshot = $Snapshot
    safety = [ordered]@{
      corePackagesAutoQuarantined = $false
      arbitraryCommandsExecuted = $false
      workspaceMutated = $false
      rawToolPayloadStored = $false
    }
  }
  try {
    Ensure-Directory $StateRoot
    $temporary = Join-Path $StateRoot ('supervisor-state.' + [guid]::NewGuid().ToString('N') + '.tmp')
    $state | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $temporary -Encoding UTF8
    Move-Item -LiteralPath $temporary -Destination $SupervisorStateFile -Force
  } catch {
    Write-LauncherLog "supervisor state write failed: $($_.Exception.Message)"
  }
  return $state
}

function Get-DshSupervisorSnapshot {
  param([Parameter(Mandatory = $true)][System.Diagnostics.Process]$Candidate)
  $processAlive = $false
  try {
    $Candidate.Refresh()
    $processAlive = -not $Candidate.HasExited
  } catch { $processAlive = $false }

  $probe = Get-WebProbe
  $entries = @()
  $inventoryError = $null
  if ($probe.Reachable -and $probe.IsDsh) {
    try { $entries = @(Get-DshPluginInventory -BaseUrl $Url -TimeoutSec 5) }
    catch { $inventoryError = $_.Exception.Message }
  }
  $failed = @($entries | Where-Object { [string]$_.fiberPhase -eq 'failed' })
  $candidates = if ($script:GuardAvailable -and $null -ne $script:GuardManifest) {
    @(Get-DshGuardCandidates -Entries $entries -Manifest $script:GuardManifest)
  } else { @() }
  return [ordered]@{
    checkedAt = (Get-Date).ToUniversalTime().ToString('o')
    processAlive = $processAlive
    webReachable = $probe.Reachable -eq $true
    webIsDsh = $probe.IsDsh -eq $true
    httpStatus = [int]$probe.StatusCode
    inventoryObserved = $probe.Reachable -and $probe.IsDsh
    inventoryError = if ($null -eq $inventoryError) { $null } else { Get-SafeSupervisorText -Value $inventoryError }
    entryCount = $entries.Count
    failedCount = $failed.Count
    failedModules = @($failed | ForEach-Object { [string]$_.moduleName } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
    candidateCount = $candidates.Count
    candidateModules = @($candidates | ForEach-Object { [string]$_.moduleName } | Sort-Object -Unique)
    # Keep the resolved, manifest-backed candidates in the in-memory snapshot
    # so the supervisor can register the exact live inventory evidence. This
    # is metadata only; the state file contains no tool payload or commands.
    candidates = @($candidates)
  }
}

function Get-SafeSupervisorText {
  param([AllowNull()][string]$Value)
  if ($null -eq $Value) { return $null }
  $result = $Value -replace '(?i)(authorization|cookie|api[_-]?key|access[_-]?token|refresh[_-]?token|password|secret)\s*[:=]\s*[^\s,;]+', '$1=<redacted>'
  $result = $result -replace '(?i)[A-Z]:\\[^\s;,)}]+', '<path>'
  if ($result.Length -gt 800) { return $result.Substring(0, 800) + '...' }
  return $result
}

function Write-DshStartupIncident {
  param(
    [Parameter(Mandatory = $true)][ValidateSet('healthy', 'restarting', 'recovered', 'degraded', 'failed')][string]$Status,
    [Parameter(Mandatory = $true)][string]$Reason,
    [int]$RestartCount = 0
  )

  $quarantined = @()
  if ($null -ne $script:GuardState -and $null -ne $script:GuardState.quarantined) {
    $quarantined = @($script:GuardState.quarantined | ForEach-Object {
      $entryId = [string]$_.entryId
      if ([string]::IsNullOrWhiteSpace($entryId)) { $entryId = [string]$_.moduleName }
      if (-not [string]::IsNullOrWhiteSpace($entryId)) { $entryId }
    } | Select-Object -First 100)
  }

  $receipt = [ordered]@{
    schemaVersion = 1
    kind = 'dsh-startup-incident'
    incidentId = $script:StartupIncidentId
    correlationKey = "startup-$($script:StartupIncidentId)"
    status = $Status
    reason = Get-SafeSupervisorText -Value $Reason
    profile = $Profile
    host = $HostName
    port = $Port
    restartCount = [Math]::Max(0, $RestartCount)
    crashGuardEnabled = $script:GuardAvailable -eq $true
    quarantinedPluginIds = $quarantined
    generatedAt = (Get-Date).ToUniversalTime().ToString('o')
    evidenceFiles = @('guard-state.json', 'guard.patch.yml', 'supervisor-state.json', 'logs/launcher.log')
    privacy = [ordered]@{
      rawLogsStored = $false
      rawToolPayloadStored = $false
      credentialsStored = $false
      absolutePathsStored = $false
    }
  }

  $temporary = $null
  try {
    Ensure-Directory $StateRoot
    $temporary = Join-Path $StateRoot ('startup-incident.' + [guid]::NewGuid().ToString('N') + '.tmp')
    $receipt | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $temporary -Encoding UTF8
    Move-Item -LiteralPath $temporary -Destination $StartupIncidentFile -Force
  } catch {
    try { if ($null -ne $temporary) { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue } } catch { }
    Write-LauncherLog "startup incident receipt write failed: $($_.Exception.Message)"
  }
  return $receipt
}

function Invoke-DshRuntimeSupervisor {
  param(
    [Parameter(Mandatory = $true)][System.Diagnostics.Process]$Candidate,
    [Parameter(Mandatory = $true)][bool]$AllowRestart,
    [int]$RestartCount = 0
  )
  $webMisses = 0
  Write-DshSupervisorState -Status 'running' -Reason 'monitoring' -RestartCount $RestartCount | Out-Null
  while ($true) {
    $snapshot = Get-DshSupervisorSnapshot -Candidate $Candidate
    if (-not $snapshot.processAlive) {
      $errorText = Get-DshGuardErrorText
      $candidates = @()
      if ($script:GuardAvailable -and $null -ne $script:GuardManifest) {
        $candidates = @(Get-DshStartupGuardCandidates -Manifest $script:GuardManifest -ErrorText $errorText)
        if ($candidates.Count -eq 0) {
          $fallback = Get-DshSingleStartupGuardCandidate -Manifest $script:GuardManifest -ErrorText $errorText
          if ($null -ne $fallback) { $candidates = @($fallback) }
        }
      }
      $changed = $false
      if ($candidates.Count -gt 0) {
        $changed = Register-DshGuardCandidates -Candidates $candidates -Source 'runtime-process-exit'
      }
      $reason = if ($changed) { 'runtime-plugin-exit' } else { 'runtime-process-exit-unattributed' }
        $status = if ($changed -and $AllowRestart) { 'restart-requested' } else { 'degraded' }
      Write-DshSupervisorState -Status $status -Reason $reason -Snapshot ($snapshot + [ordered]@{ errorEvidenceObserved = -not [string]::IsNullOrWhiteSpace($errorText) }) -RestartCount $RestartCount | Out-Null
      return [ordered]@{ restartRequested = $changed -and $AllowRestart; reason = $reason; status = $status }
    }

    if ($snapshot.webReachable -and -not $snapshot.webIsDsh) {
      Write-DshSupervisorState -Status 'degraded' -Reason 'port-returned-non-dsh-page' -Snapshot $snapshot -RestartCount $RestartCount | Out-Null
      return [ordered]@{ restartRequested = $false; reason = 'port-returned-non-dsh-page'; status = 'degraded' }
    }
    if (-not $snapshot.webReachable) {
      $webMisses += 1
      if ($webMisses -ge $SupervisorMaxWebMisses) {
        $status = if ($AllowRestart -and $script:GuardAvailable) { 'restart-requested' } else { 'degraded' }
        Write-DshSupervisorState -Status $status -Reason 'web-unreachable' -Snapshot $snapshot -RestartCount $RestartCount | Out-Null
        return [ordered]@{ restartRequested = $AllowRestart -and $script:GuardAvailable; reason = 'web-unreachable'; status = $status }
      }
    } else {
      $webMisses = 0
      if ($snapshot.candidateCount -gt 0) {
        $changed = Register-DshGuardCandidates -Candidates @($snapshot.candidates) -Source 'runtime-plugin-inventory'
        if ($changed) {
          $status = if ($AllowRestart) { 'restart-requested' } else { 'degraded' }
          Write-DshSupervisorState -Status $status -Reason 'runtime-plugin-inventory' -Snapshot $snapshot -RestartCount $RestartCount | Out-Null
          return [ordered]@{ restartRequested = $AllowRestart; reason = 'runtime-plugin-inventory'; status = $status }
        }
      }
      if ($null -ne $snapshot.inventoryError) {
        Write-DshSupervisorState -Status 'degraded' -Reason 'runtime-plugin-inventory-unavailable' -Snapshot $snapshot -RestartCount $RestartCount | Out-Null
        return [ordered]@{ restartRequested = $false; reason = 'runtime-plugin-inventory-unavailable'; status = 'degraded' }
      }
      if (-not $snapshot.inventoryObserved) {
        Write-DshSupervisorState -Status 'degraded' -Reason 'runtime-plugin-inventory-unavailable' -Snapshot $snapshot -RestartCount $RestartCount | Out-Null
        return [ordered]@{ restartRequested = $false; reason = 'runtime-plugin-inventory-unavailable'; status = 'degraded' }
      }
      if ($snapshot.failedCount -gt 0) {
        $reason = if ($snapshot.candidateCount -gt 0) { 'runtime-plugin-failed-after-quarantine' } else { 'runtime-plugin-failed-unresolved' }
        Write-DshSupervisorState -Status 'degraded' -Reason $reason -Snapshot $snapshot -RestartCount $RestartCount | Out-Null
        return [ordered]@{ restartRequested = $false; reason = $reason; status = 'degraded' }
      }
      Write-DshSupervisorState -Status 'healthy' -Reason 'web-and-plugin-inventory-healthy' -Snapshot $snapshot -RestartCount $RestartCount | Out-Null
    }
    Start-Sleep -Seconds $SupervisorIntervalSec
  }
}

function Resolve-NativeCommand {
  param([Parameter(Mandatory = $true)][string[]]$Names)
  foreach ($Name in $Names) {
    $commands = @(Get-Command -Name $Name -All -ErrorAction SilentlyContinue)
    foreach ($Command in $commands) {
      if ($Command.CommandType -eq 'Application' -and -not [string]::IsNullOrWhiteSpace($Command.Source)) {
        if (Test-Path -LiteralPath $Command.Source -PathType Leaf) {
          return $Command.Source
        }
      }
    }
  }
  return $null
}

function Show-LauncherError {
  param([Parameter(Mandatory = $true)][string]$Message)
  if ($NoErrorDialog -or [string]$env:DSH_NO_ERROR_DIALOG -eq '1') {
    if ($ShowWindow) { Write-Error $Message }
    return
  }
  try {
    Add-Type -AssemblyName System.Windows.Forms
    [System.Windows.Forms.MessageBox]::Show(
      "$Message`n`n日志：$LauncherLog",
      'DSH 启动失败',
      [System.Windows.Forms.MessageBoxButtons]::OK,
      [System.Windows.Forms.MessageBoxIcon]::Error
    ) | Out-Null
  } catch {
    if ($ShowWindow) {
      Write-Error $Message
    }
  }
}

function Get-WebProbe {
  try {
    $response = Invoke-WebRequest -UseBasicParsing -Uri $Url -TimeoutSec 3
    $content = [string]$response.Content
    return [PSCustomObject]@{
      Reachable = $true
      IsDsh = ($content -match '(?i)dsh|deepseek|harness')
      StatusCode = [int]$response.StatusCode
    }
  } catch {
    # Invoke-WebRequest throws for some HTTP error statuses. A response still
    # means that the port is occupied, even when it is not a healthy DSH page.
    if ($null -ne $_.Exception.Response) {
      return [PSCustomObject]@{
        Reachable = $true
        IsDsh = $false
        StatusCode = [int]$_.Exception.Response.StatusCode
      }
    }
    return [PSCustomObject]@{
      Reachable = $false
      IsDsh = $false
      StatusCode = 0
    }
  }
}

function Get-DshBrowserLaunchUrl {
  param(
    [switch]$StartupGuardNotice,
    [string]$IncidentId = ''
  )
  if (-not $StartupGuardNotice) { return $Url }
  # Pass only a bounded event marker to the client. Plugin names, logs,
  # arguments, and error text remain in local guarded state and never enter
  # the browser URL or an automatically created Session.
  $query = 'dsh_debug_guard=isolated'
  if ($IncidentId -match '^[A-Za-z0-9._:-]{1,128}$') {
    $query += "&dsh_debug_incident=$IncidentId"
  }
  $separator = if ($Url.Contains('?')) { '&' } else { '?' }
  return "$Url$separator$query"
}

function Get-DshStartupFailureDetail {
  if (-not (Test-Path -LiteralPath $DshStderrLog -PathType Leaf)) { return '' }
  try {
    $text = Get-Content -LiteralPath $DshStderrLog -Raw -Encoding UTF8 -ErrorAction Stop
    if ($text -match '(?i)EADDRINUSE') {
      return "DSH 子进程无法监听 $HostName`:$Port：端口已被占用（EADDRINUSE）"
    }
    if ($text -match '(?i)MODULE_NOT_FOUND') {
      return 'DSH 子进程缺少运行时模块（MODULE_NOT_FOUND）'
    }
  } catch {
    return ''
  }
  return ''
}

function Test-PortListener {
  try {
    return $null -ne (Get-NetTCPConnection -LocalAddress $HostName -LocalPort $Port -State Listen -ErrorAction SilentlyContinue)
  } catch {
    return $false
  }
}

function Wait-DshPortReleased {
  param([int]$TimeoutSec = 10)

  # A crashed Node process can report HasExited before Windows has finished
  # releasing its listening socket. Starting the guarded replacement in that
  # small window produces a misleading EADDRINUSE failure and leaves the
  # launcher looking like the recovered runtime never started. Treat the
  # socket itself as part of the restart transaction and wait for both the
  # listener and the HTTP endpoint to disappear before launching again.
  $attempts = [Math]::Max(1, $TimeoutSec * 10)
  for ($attempt = 0; $attempt -lt $attempts; $attempt++) {
    $listener = Test-PortListener
    $probe = Get-WebProbe
    if (-not $listener -and -not $probe.Reachable) {
      return $true
    }
    if ($attempt + 1 -lt $attempts) {
      Start-Sleep -Milliseconds 100
    }
  }
  return $false
}

function Wait-DshPortReleasedOrThrow {
  param([string]$Reason)

  $waitSec = [Math]::Min(10, [Math]::Max(1, $StartupTimeoutSec))
  Write-LauncherLog "等待旧 DSH 子进程释放端口 $HostName`:$Port（$Reason）。"
  if (-not (Wait-DshPortReleased -TimeoutSec $waitSec)) {
    throw "旧 DSH 子进程退出后端口 $Port 仍被占用，已停止自动重启；请稍后重试或改用 -Port。"
  }
}

function Test-ProvenanceInstalled {
  $manifestPath = Join-Path $env:DSH_HOME "profiles\$Profile\package.json"
  if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { return $false }
  try {
    $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $dependenciesProperty = $manifest.PSObject.Properties['dependencies']
    $dependencies = if ($null -eq $dependenciesProperty) { $null } else { $dependenciesProperty.Value }
    $dependency = if ($null -eq $dependencies) { $null } else { $dependencies.PSObject.Properties['dsh-plugin-debug'] }
    $dshProperty = $manifest.PSObject.Properties['dsh']
    $dsh = if ($null -eq $dshProperty) { $null } else { $dshProperty.Value }
    $profileProperty = if ($null -eq $dsh) { $null } else { $dsh.PSObject.Properties['profile'] }
    $profileValue = if ($null -eq $profileProperty) { $null } else { $profileProperty.Value }
    $bundlesProperty = if ($null -eq $profileValue) { $null } else { $profileValue.PSObject.Properties['bundles'] }
    $bundles = if ($null -eq $bundlesProperty) { @() } else { @($bundlesProperty.Value) }
    $installedRoot = Join-Path $env:DSH_HOME "profiles\$Profile\node_modules\dsh-plugin-debug"
    return $null -ne $dependency -and $bundles -contains 'dsh-plugin-debug' -and
      (Test-Path -LiteralPath (Join-Path $installedRoot 'package.json') -PathType Leaf) -and
      (Test-Path -LiteralPath (Join-Path $installedRoot 'cordis.patch.yml') -PathType Leaf) -and
      (Test-Path -LiteralPath (Join-Path $installedRoot 'lib\client.js') -PathType Leaf)
  } catch {
    Write-LauncherLog "无法读取当前 Profile 的 dsh-plugin-debug 安装状态，按未安装处理：$manifestPath；$($_.Exception.Message)"
    return $false
  }
}

function Resolve-ProvenanceBundle {
  $required = @(
    (Join-Path $BundleRoot 'package.json'),
    (Join-Path $BundleRoot 'cordis.patch.yml'),
    (Join-Path $BundleRoot 'lib\index.js'),
    (Join-Path $BundleRoot 'lib\client.js')
  )
  foreach ($path in $required) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
      throw "独立工具缺少内置 dsh-plugin-debug bundle 文件：$path"
    }
  }
  $manifest = Get-Content -LiteralPath (Join-Path $BundleRoot 'package.json') -Raw -Encoding UTF8 | ConvertFrom-Json
  if ([string]$manifest.name -cne 'dsh-plugin-debug') {
    throw "内置 bundle 名称错误：$([string]$manifest.name)"
  }
  return [IO.Path]::GetFullPath($BundleRoot)
}

function Ensure-ProvenancePlugin {
  param([Parameter(Mandatory = $true)][PSCustomObject]$Invocation)
  if (-not $ForcePluginInstall -and (Test-ProvenanceInstalled)) {
    Write-LauncherLog "当前 Profile 已包含 dsh-plugin-debug bundle：$Profile"
    return
  }
  if ($NoPluginInstall) {
    Write-LauncherLog '按 -NoPluginInstall 跳过 dsh-plugin-debug bundle 安装；当前实例不会提供 Debug Web 面板。'
    return
  }

  $bundlePath = Resolve-ProvenanceBundle
  $installArguments = @($Invocation.PrefixArgs)
  $installArguments += 'plugin'
  $installArguments += '--profile'
  $installArguments += $Profile
  $installArguments += 'add'
  $installArguments += $bundlePath
  $installArguments += '--offline'
  Ensure-Directory $LogDir
  $operation = if ($ForcePluginInstall) { '更新' } else { '首次启动自动安装' }
  Write-LauncherLog "$operation dsh-plugin-debug bundle：Profile=$Profile source=$bundlePath"
  $previousErrorAction = $ErrorActionPreference
  try {
    $ErrorActionPreference = 'Continue'
    & $Invocation.FilePath @installArguments *> $InstallLog
    $installCode = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $previousErrorAction
  }
  if ($installCode -ne 0) {
    throw "dsh-plugin-debug bundle 离线安装失败，退出码 $installCode；详见 $InstallLog"
  }
  if (-not (Test-ProvenanceInstalled)) {
    throw "dsh-plugin-debug bundle 安装命令已成功返回，但当前 Profile 没有记录安装结果；详见 $InstallLog"
  }
  Write-LauncherLog 'dsh-plugin-debug bundle 已安装；当前启动不需要插件商店。'
}

function Resolve-DshInvocation {
  param([Parameter(Mandatory = $true)][string]$NodePath)

  $runtimeEntry = Join-Path $RuntimeDir 'node_modules\@deepseek-ai\dsh\lib\bin.js'
  if (Test-Path -LiteralPath $runtimeEntry -PathType Leaf) {
    return [PSCustomObject]@{
      FilePath = $NodePath
      PrefixArgs = @($runtimeEntry)
      Description = "pinned npm runtime @deepseek-ai/dsh@0.1.0-rc.6"
    }
  }

  $dshPath = Resolve-NativeCommand @('dsh.cmd', 'dsh.exe', 'dsh.bat', 'dsh')
  if ($null -ne $dshPath) {
    return [PSCustomObject]@{
      FilePath = $dshPath
      PrefixArgs = @()
      Description = "DSH from PATH: $dshPath"
    }
  }
  return $null
}

function Ensure-DshRuntime {
  param([Parameter(Mandatory = $true)][string]$NodePath)

  $runtimeEntry = Join-Path $RuntimeDir 'node_modules\@deepseek-ai\dsh\lib\bin.js'
  if (-not (Test-Path -LiteralPath $runtimeEntry -PathType Leaf) -and -not $NoInstall) {
    $npmPath = Resolve-NativeCommand @('npm.cmd', 'npm.exe', 'npm')
    if ($null -eq $npmPath) {
      throw '找不到 npm；请先安装 Node.js，或把 npm 加入 PATH。'
    }
    $runtimeManifest = Join-Path $RuntimeDir 'package.json'
    if (-not (Test-Path -LiteralPath $runtimeManifest -PathType Leaf)) {
      throw "启动器缺少固定版本清单：$runtimeManifest"
    }
    Ensure-Directory $LogDir
    Write-LauncherLog '本机没有可用的 dsh，开始安装固定版本 @deepseek-ai/dsh@0.1.0-rc.6。首次启动可能需要几十秒。'
    # Keep first-run failures bounded: the launcher must not sit indefinitely
    # in a hidden npm process when a registry mirror or one package is stuck.
    & $npmPath install --prefix $RuntimeDir --no-audit --no-fund --omit=dev --ignore-scripts --progress=false --fetch-retries=1 --fetch-timeout=30000 --loglevel=warn *> $InstallLog
    $installCode = $LASTEXITCODE
    if ($installCode -ne 0) {
      throw "DSH 安装失败，退出码 $installCode；详见 $InstallLog"
    }
  }
  return (Resolve-DshInvocation -NodePath $NodePath)
}

try {
  if ($Port -lt 1 -or $Port -gt 65535) {
    throw "端口无效：$Port"
  }
  if ($Profile -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$') {
    throw "Profile 名称无效：$Profile"
  }
  if ($StartupTimeoutSec -lt 1) {
    throw "启动超时时间无效：$StartupTimeoutSec"
  }
  if ($GuardThreshold -lt 1) {
    throw "GuardThreshold 无效：$GuardThreshold"
  }
  if ($InstallOnly) {
    if ([string]::IsNullOrWhiteSpace($env:DSH_HOME)) {
      $env:DSH_HOME = Join-Path $env:USERPROFILE '.dsh'
    }
    Ensure-Directory $env:DSH_HOME
    $installNodePath = Resolve-NativeCommand @('node.exe', 'node')
    if ($null -eq $installNodePath) {
      throw '找不到 node.exe；请先安装 Node.js 20+ 并把它加入 PATH。'
    }
    $installInvocation = Ensure-DshRuntime -NodePath $installNodePath
    if ($null -eq $installInvocation) {
      throw '找不到 dsh。请检查 npm 安装日志，或确保 dsh 已加入 PATH。'
    }
    Ensure-ProvenancePlugin -Invocation $installInvocation
    Write-LauncherLog "DSH runtime 已就绪：$($installInvocation.Description)"
    if ($ShowWindow) { Write-Host 'DSH runtime 已就绪。' }
    exit 0
  }
  if (-not (Test-Path -LiteralPath $Workspace -PathType Container)) {
    throw "工作区不存在：$Workspace"
  }
  Ensure-Directory $LogDir
  Write-LauncherLog "请求启动 DSH profile=$Profile host=$HostName port=$Port workspace=$Workspace"
  $lockWaitSec = [Math]::Max(30, $StartupTimeoutSec + 30)
  Enter-DshLaunchLock -TimeoutSec $lockWaitSec

  if ([string]::IsNullOrWhiteSpace($env:DSH_HOME)) {
    $env:DSH_HOME = $DefaultDshHome
  }
  Ensure-Directory $env:DSH_HOME
  if ($EnableCrashGuard) {
    Write-LauncherLog 'crash guard enabled: profile dependency installation is disabled by this standalone launcher.'
  }

  $existing = Get-WebProbe
  if ($existing.Reachable -and $existing.IsDsh) {
    if (-not $NoPluginInstall -and ($ForcePluginInstall -or -not (Test-ProvenanceInstalled))) {
      if (-not (Try-IsolateDshConflict -Reason 'external-web-instance')) {
        throw '检测到已有 DSH 正在运行，但当前 Profile 尚未安装 dsh-plugin-debug；请先关闭当前 DSH，或去掉 -NoIsolateOnConflict 后重新启动。'
      }
      $existing = Get-WebProbe
    }
    if ($existing.Reachable -and $existing.IsDsh) {
      Write-LauncherLog "检测到已经运行的 DSH Web（HTTP $($existing.StatusCode)），不重复启动。"
      if (-not $NoBrowser) {
        Start-Process $Url | Out-Null
      }
      Release-DshLaunchLock
      exit 0
    }
  }

  $recorded = Get-RecordedDshProcess
  if ($null -ne $recorded) {
    if (-not $NoPluginInstall -and ($ForcePluginInstall -or -not (Test-ProvenanceInstalled))) {
      if (-not (Try-IsolateDshConflict -Reason 'recorded-web-instance')) {
        throw '检测到本启动器记录的 DSH 正在运行，但当前 Profile 尚未安装 dsh-plugin-debug；请等待该实例停止，或去掉 -NoIsolateOnConflict 后重新启动。'
      }
      $recorded = $null
      $existing = Get-WebProbe
    }
    if ($null -ne $recorded) {
      $process = $recorded.Process
      Write-LauncherLog "检测到本启动器已记录的 DSH child pid=$($process.Id)，复用并等待 Web readiness。"
      $reusedProbe = Wait-RecordedDshWebReady -Candidate $process
      Write-LauncherLog "复用的 DSH Web ready：$Url（HTTP $($reusedProbe.StatusCode)）"
      if (-not $NoBrowser) {
        Start-Process $Url | Out-Null
      }
      Release-DshLaunchLock
      exit 0
    }
  }

  if ($existing.Reachable -or (Test-PortListener)) {
    throw "端口 $Port 已被其他服务占用，未强行覆盖；请改用 -Port 或先停止占用该端口的程序。"
  }

  $nodePath = Resolve-NativeCommand @('node.exe', 'node')
  if ($null -eq $nodePath) {
    throw '找不到 node.exe；请先安装 Node.js 20+ 并把它加入 PATH。'
  }
  $invocation = Ensure-DshRuntime -NodePath $nodePath
  if ($null -eq $invocation) {
    throw '找不到 dsh。请检查 npm 安装日志，或使用 -NoInstall 时确保 dsh 已加入 PATH。'
  }
  Ensure-ProvenancePlugin -Invocation $invocation
  Initialize-DshCrashGuard

  $argumentList = @()
  $argumentList += $invocation.PrefixArgs
  $argumentList += '--profile'
  $argumentList += $Profile
  if ($EnableAgents) {
    if (-not (Test-Path -LiteralPath $AgentsPatch -PathType Leaf)) {
      throw "Agent overlay is missing: $AgentsPatch"
    }
    $argumentList += '--patch'
    $argumentList += $AgentsPatch
  }
  if ($script:GuardAvailable) {
    # Keep the path in the argv for both the first boot and a guard-triggered
    # restart. The file is rewritten between those two boots.
    $argumentList += '--patch'
    $argumentList += $GuardPatch
  }
  $argumentList += '--host'
  $argumentList += $HostName
  $argumentList += '--port'
  $argumentList += [string]$Port

  $windowStyle = if ($ShowWindow) { 'Normal' } else { 'Hidden' }
  $guardRestarted = $false
  $ready = $false
  while ($true) {
    $restartRequested = $false
    $process = Start-Process -FilePath $invocation.FilePath `
      -ArgumentList $argumentList `
      -WorkingDirectory $Workspace `
      -RedirectStandardOutput $DshStdoutLog `
      -RedirectStandardError $DshStderrLog `
      -WindowStyle $windowStyle `
      -PassThru

    $processStartTimeUtc = ''
    try {
      $processStartTimeUtc = $process.StartTime.ToUniversalTime().ToString('o')
    } catch {
      Write-LauncherLog "无法读取新 DSH 子进程的启动时间，继续使用 PID 记录：pid=$($process.Id)"
    }
    $record = [PSCustomObject]@{
      pid = $process.Id
      startedAt = (Get-Date).ToUniversalTime().ToString('o')
      processStartTimeUtc = $processStartTimeUtc
      url = $Url
      profile = $Profile
      host = $HostName
      port = $Port
      workspace = $Workspace
      stateRoot = $StateRoot
      runtime = $invocation.Description
      runtimePath = $invocation.FilePath
      crashGuard = $script:GuardAvailable
      guardRestarted = $guardRestarted
    }
    $record | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $PidFile -Encoding UTF8
    Write-LauncherLog "DSH child started pid=$($process.Id); waiting for Web readiness."

    $ready = $false
    for ($second = 0; $second -lt $StartupTimeoutSec; $second++) {
      Start-Sleep -Seconds 1
      $process.Refresh()
      if ($process.HasExited) {
        $exitCode = $null
        try { $exitCode = [int]$process.ExitCode } catch { }
        $exitCodeText = if ($null -eq $exitCode) { 'unknown' } else { [string]$exitCode }
        $errorText = Get-DshGuardErrorText
        if (-not $guardRestarted -and (Try-DshGuardStartupRecovery -ErrorText $errorText)) {
          $guardRestarted = $true
          $restartRequested = $true
          Write-LauncherLog "guard will restart after quarantining a startup candidate; old pid=$($process.Id) exit=$exitCodeText"
          Write-DshStartupIncident -Status 'restarting' -Reason 'startup-failure-quarantine' -RestartCount 1 | Out-Null
          break
        }
        $detail = Get-DshStartupFailureDetail
        $suffix = if ([string]::IsNullOrWhiteSpace($detail)) { '' } else { "; $detail" }
        throw "DSH exited before Web readiness, exit code $exitCodeText$suffix; see $DshStderrLog"
      }
      $probe = Get-WebProbe
      if ($probe.Reachable -and $probe.IsDsh) {
        $ready = $true
        break
      }
      if ($probe.Reachable -and -not $probe.IsDsh) {
        $errorText = Get-DshGuardErrorText
        if (-not $guardRestarted -and (Try-DshGuardStartupRecovery -ErrorText $errorText)) {
          $guardRestarted = $true
          $restartRequested = $true
          Write-LauncherLog "guard will restart after a non-DSH response; old pid=$($process.Id)"
          Write-DshStartupIncident -Status 'restarting' -Reason 'non-dsh-response-quarantine' -RestartCount 1 | Out-Null
          break
        }
        throw "port $Port returned a non-DSH page; see $DshStderrLog"
      }
    }

    if ($restartRequested) {
      try {
        if ($null -ne $process) {
          $process.Refresh()
          if (-not $process.HasExited) {
            Stop-RecordedDshProcess -Candidate $process -Reason 'crash guard restart' | Out-Null
          }
        }
      } catch {
        Write-LauncherLog "guard cleanup warning for pid=$($process.Id): $($_.Exception.Message)"
      }
      if (Test-Path -LiteralPath $PidFile -PathType Leaf) { Remove-Item -LiteralPath $PidFile -Force }
      Wait-DshPortReleasedOrThrow -Reason 'crash guard restart'
      continue
    }

    if (-not $ready) {
      $errorText = Get-DshGuardErrorText
      if (-not $guardRestarted -and (Try-DshGuardStartupRecovery -ErrorText $errorText)) {
        $guardRestarted = $true
        Write-DshStartupIncident -Status 'restarting' -Reason 'startup-timeout-quarantine' -RestartCount 1 | Out-Null
        try {
          $process.Refresh()
          if (-not $process.HasExited) {
            Stop-RecordedDshProcess -Candidate $process -Reason 'crash guard restart after timeout' | Out-Null
          }
        } catch {
          Write-LauncherLog "guard cleanup warning for pid=$($process.Id): $($_.Exception.Message)"
        }
        if (Test-Path -LiteralPath $PidFile -PathType Leaf) { Remove-Item -LiteralPath $PidFile -Force }
        Wait-DshPortReleasedOrThrow -Reason 'crash guard restart after timeout'
        continue
      }
      throw "DSH Web startup timed out (${StartupTimeoutSec}s); see $DshStderrLog"
    }

    Write-LauncherLog "DSH Web ready: $Url"
    $guardReadyResult = Invoke-DshGuardReadyCheck
    $script:LastGuardReadyResult = $guardReadyResult
    if (-not $guardRestarted -and $guardReadyResult.restartRequested) {
      $guardRestarted = $true
      Write-LauncherLog "guard will restart once with the generated quarantine patch."
      Write-DshStartupIncident -Status 'restarting' -Reason 'runtime-plugin-inventory-quarantine' -RestartCount 1 | Out-Null
      try {
        $process.Refresh()
        if (-not $process.HasExited) {
          Stop-RecordedDshProcess -Candidate $process -Reason 'crash guard ready check' | Out-Null
        }
      } catch {
        Write-LauncherLog "guard cleanup warning for pid=$($process.Id): $($_.Exception.Message)"
      }
      if (Test-Path -LiteralPath $PidFile -PathType Leaf) { Remove-Item -LiteralPath $PidFile -Force }
      Wait-DshPortReleasedOrThrow -Reason 'crash guard ready-check restart'
      continue
    }

    if ($script:GuardAvailable -and -not $KeepAlive -and [string]$guardReadyResult.status -ne 'healthy') {
      $script:StartupFailureStatus = 'degraded'
      $script:StartupFailureReason = [string]$guardReadyResult.reason
      throw "DSH startup health check entered $($guardReadyResult.status): $($guardReadyResult.reason); see $SupervisorStateFile"
    }

    if ($KeepAlive) {
      $supervisorResult = Invoke-DshRuntimeSupervisor `
        -Candidate $process `
        -AllowRestart:(-not $guardRestarted) `
        -RestartCount ([int]$guardRestarted)
      if ($supervisorResult.restartRequested) {
        $guardRestarted = $true
        Write-LauncherLog "runtime supervisor requested one controlled restart: reason=$($supervisorResult.reason) pid=$($process.Id)"
        Write-DshStartupIncident -Status 'restarting' -Reason "runtime-supervisor-$($supervisorResult.reason)" -RestartCount 1 | Out-Null
        try {
          $process.Refresh()
          if (-not $process.HasExited) {
            Stop-RecordedDshProcess -Candidate $process -Reason 'runtime supervisor restart' | Out-Null
          }
        } catch {
          Write-LauncherLog "supervisor cleanup warning for pid=$($process.Id): $($_.Exception.Message)"
        }
        if (Test-Path -LiteralPath $PidFile -PathType Leaf) { Remove-Item -LiteralPath $PidFile -Force }
        continue
      }
      if ([string]$supervisorResult.status -ne 'healthy') {
        $script:StartupFailureStatus = if ([string]$supervisorResult.status -eq 'degraded') { 'degraded' } else { 'failed' }
        $script:StartupFailureReason = [string]$supervisorResult.reason
        throw "DSH runtime supervisor entered degraded state: $($supervisorResult.reason); see $SupervisorStateFile"
      }
    }
    break
  }

  $finalStartupStatus = if ($guardRestarted) { 'recovered' } else { 'healthy' }
  $finalStartupReason = if ($guardRestarted) { 'quarantine-and-controlled-restart' } else { 'web-ready' }
  $startupReceipt = Write-DshStartupIncident -Status $finalStartupStatus -Reason $finalStartupReason -RestartCount ([int]$guardRestarted)

  if (-not $NoBrowser) {
    Start-Process (Get-DshBrowserLaunchUrl -StartupGuardNotice:$guardRestarted -IncidentId ([string]$startupReceipt.incidentId)) | Out-Null
  }
  if ($ShowWindow) {
    Write-Host "DSH Web 已打开：$Url"
  }
  Release-DshLaunchLock
  exit 0
} catch {
  $message = $_.Exception.Message
  try {
    if ($null -ne $process) {
      $process.Refresh()
      if (-not $process.HasExited) {
        if (Stop-RecordedDshProcess -Candidate $process -Reason 'startup failure') {
          $message = "$message（已停止本启动器记录的未就绪 DSH 子进程 PID=$($process.Id)）"
        }
      }
    }
  } catch {
    # Preserve the original startup failure if cleanup cannot complete.
  }
  try {
    Ensure-Directory $LogDir
    $restartCount = 0
    $guardVariable = Get-Variable -Name guardRestarted -ErrorAction SilentlyContinue
    if ($null -ne $guardVariable -and [bool]$guardVariable.Value) { $restartCount = 1 }
    Write-DshStartupIncident -Status $script:StartupFailureStatus -Reason $script:StartupFailureReason -RestartCount $restartCount | Out-Null
    Write-LauncherLog "ERROR $message"
  } catch {
    # Preserve the original failure if logging itself is unavailable.
  }
  Release-DshLaunchLock
  Show-LauncherError $message
  exit 1
}
