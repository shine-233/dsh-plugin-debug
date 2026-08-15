Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-DshResourcePressureProperty {
  param([AllowNull()]$Object, [Parameter(Mandatory = $true)][string]$Name)
  if ($null -eq $Object) { return $null }
  if ($Object -is [System.Collections.IDictionary] -and $Object.Contains($Name)) { return $Object[$Name] }
  $property = $Object.PSObject.Properties[$Name]
  if ($null -eq $property) { return $null }
  return $property.Value
}

function Get-DshResourceProcessRows {
  [OutputType([object[]])]
  param()

  $rows = @()
  try {
    $rows = @(Get-Process -Name node,pwsh,powershell -ErrorAction SilentlyContinue | ForEach-Object {
      $startedAt = $null
      try { $startedAt = $_.StartTime.ToUniversalTime().ToString('o') } catch { }
      [PSCustomObject]@{
        pid = [int]$_.Id
        processName = [string]$_.ProcessName
        workingSetBytes = [UInt64]$_.WorkingSet64
        startedAt = $startedAt
      }
    })
  } catch {
    return @()
  }
  return @($rows)
}

function Get-DshPhysicalMemorySnapshot {
  [OutputType([object])]
  param()

  try {
    $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
    $total = [UInt64]([UInt64]$os.TotalVisibleMemorySize * 1KB)
    $free = [UInt64]([UInt64]$os.FreePhysicalMemory * 1KB)
    if ($total -le 0 -or $free -gt $total) { return $null }
    return [PSCustomObject]@{
      totalPhysicalBytes = $total
      freePhysicalBytes = $free
      usedPhysicalBytes = $total - $free
    }
  } catch {
    return $null
  }
}

function Get-DshResourcePressure {
  [OutputType([object])]
  param(
    [AllowEmptyCollection()][object[]]$ProcessRows = @(),
    [AllowNull()]$MemorySnapshot = $null,
    [int]$NodeWarningCount = 24,
    [int]$NodeCriticalCount = 64,
    [double]$NodeWarningFraction = 0.50,
    [double]$NodeCriticalFraction = 0.75
  )

  if ($NodeWarningCount -lt 1 -or $NodeCriticalCount -lt $NodeWarningCount) { throw 'resource pressure process thresholds are invalid' }
  if ($NodeWarningFraction -le 0 -or $NodeCriticalFraction -lt $NodeWarningFraction -or $NodeCriticalFraction -gt 1) { throw 'resource pressure memory thresholds are invalid' }

  $sampledProcesses = if ($null -eq $ProcessRows -or $ProcessRows.Count -eq 0) { @(Get-DshResourceProcessRows) } else { @($ProcessRows) }
  $nodeRows = @($sampledProcesses | Where-Object { [string]$_.processName -ieq 'node' })
  $nodeWorkingSet = [UInt64]0
  foreach ($row in $nodeRows) {
    $workingSet = [UInt64](Get-DshResourcePressureProperty -Object $row -Name 'workingSetBytes')
    $nodeWorkingSet += $workingSet
  }

  $memory = if ($null -eq $MemorySnapshot) { Get-DshPhysicalMemorySnapshot } else { $MemorySnapshot }
  $totalPhysicalBytes = if ($null -eq $memory) { $null } else { [UInt64](Get-DshResourcePressureProperty -Object $memory -Name 'totalPhysicalBytes') }
  $freePhysicalBytes = if ($null -eq $memory) { $null } else { [UInt64](Get-DshResourcePressureProperty -Object $memory -Name 'freePhysicalBytes') }
  $nodeFraction = if ($null -eq $totalPhysicalBytes -or $totalPhysicalBytes -eq 0) { $null } else { [Math]::Round($nodeWorkingSet / [double]$totalPhysicalBytes, 4) }

  $reasons = [System.Collections.Generic.List[string]]::new()
  if ($nodeRows.Count -ge $NodeCriticalCount) { [void]$reasons.Add("node process count is at or above $NodeCriticalCount") }
  elseif ($nodeRows.Count -ge $NodeWarningCount) { [void]$reasons.Add("node process count is at or above $NodeWarningCount") }
  if ($null -ne $nodeFraction -and $nodeFraction -ge $NodeCriticalFraction) { [void]$reasons.Add("node working set is at or above $([Math]::Round($NodeCriticalFraction * 100))% of physical memory") }
  elseif ($null -ne $nodeFraction -and $nodeFraction -ge $NodeWarningFraction) { [void]$reasons.Add("node working set is at or above $([Math]::Round($NodeWarningFraction * 100))% of physical memory") }

  $status = if ($nodeRows.Count -ge $NodeCriticalCount -or ($null -ne $nodeFraction -and $nodeFraction -ge $NodeCriticalFraction)) {
    'critical'
  } elseif ($nodeRows.Count -ge $NodeWarningCount -or ($null -ne $nodeFraction -and $nodeFraction -ge $NodeWarningFraction)) {
    'warning'
  } elseif ($sampledProcesses.Count -eq 0 -and $null -eq $memory) {
    'unavailable'
  } else {
    'healthy'
  }

  $topProcesses = @($nodeRows | Sort-Object @{ Expression = { [UInt64](Get-DshResourcePressureProperty -Object $_ -Name 'workingSetBytes') }; Descending = $true } | Select-Object -First 10 | ForEach-Object {
    [PSCustomObject]@{
      pid = [int](Get-DshResourcePressureProperty -Object $_ -Name 'pid')
      processName = [string](Get-DshResourcePressureProperty -Object $_ -Name 'processName')
      workingSetBytes = [UInt64](Get-DshResourcePressureProperty -Object $_ -Name 'workingSetBytes')
      startedAt = [string](Get-DshResourcePressureProperty -Object $_ -Name 'startedAt')
    }
  })

  return [ordered]@{
    status = $status
    sampledAt = (Get-Date).ToUniversalTime().ToString('o')
    processCount = $sampledProcesses.Count
    nodeProcessCount = $nodeRows.Count
    nodeWorkingSetBytes = $nodeWorkingSet
    nodeWorkingSetFraction = $nodeFraction
    totalPhysicalBytes = $totalPhysicalBytes
    freePhysicalBytes = $freePhysicalBytes
    topNodeProcesses = $topProcesses
    reasons = @($reasons)
    thresholds = [ordered]@{
      nodeWarningCount = $NodeWarningCount
      nodeCriticalCount = $NodeCriticalCount
      nodeWarningFraction = $NodeWarningFraction
      nodeCriticalFraction = $NodeCriticalFraction
    }
    recommendation = if ($status -in @('critical', 'warning')) {
      'Review stale DSH/Node runtimes and rerun the diagnostic before attributing failures to a plugin. No process is stopped automatically.'
    } elseif ($status -eq 'unavailable') {
      'Resource pressure could not be sampled; treat live runtime evidence as unavailable.'
    } else {
      'No configured Node process pressure threshold was exceeded.'
    }
    privacy = 'Metadata-only process and OS memory snapshot. Command lines, paths, environment variables, session content and Tool arguments are not read.'
  }
}

Export-ModuleMember -Function @(
  'Get-DshResourceProcessRows',
  'Get-DshPhysicalMemorySnapshot',
  'Get-DshResourcePressure'
)
