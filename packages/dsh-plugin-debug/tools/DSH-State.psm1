Set-StrictMode -Version Latest

function Resolve-DshDebugHome {
  param([string]$DshHome = '')

  $value = if ([string]::IsNullOrWhiteSpace($DshHome)) {
    if ([string]::IsNullOrWhiteSpace($env:DSH_HOME)) { Join-Path $env:USERPROFILE '.dsh' } else { $env:DSH_HOME }
  } else {
    $DshHome
  }
  return [IO.Path]::GetFullPath($value)
}

function Resolve-DshDebugStateRoot {
  param(
    [string]$StateRoot = '',
    [string]$DshHome = '',
    [string]$Profile = 'web',
    [int]$Port = 3080
  )

  if (-not [string]::IsNullOrWhiteSpace($StateRoot)) {
    return [IO.Path]::GetFullPath($StateRoot)
  }
  $home = Resolve-DshDebugHome -DshHome $DshHome
  return Join-Path $home "dsh-plugin-debug\state\$Profile-$Port"
}

function Resolve-DshDebugLogRoot {
  param([string]$DshHome = '')

  return Join-Path (Resolve-DshDebugHome -DshHome $DshHome) 'dsh-plugin-debug\logs'
}

Export-ModuleMember -Function Resolve-DshDebugHome, Resolve-DshDebugStateRoot, Resolve-DshDebugLogRoot
