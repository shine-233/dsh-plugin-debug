[CmdletBinding()]
param()

# Single-package entry point for the optional Kimi/Codex overlay. The overlay
# is loaded by the same combined debug launcher; it is an optional provider
# overlay, not another runtime plugin.
$target = Join-Path $PSScriptRoot 'tools\Start-DSH.ps1'
if (-not (Test-Path -LiteralPath $target -PathType Leaf)) {
  throw "debug launcher is missing: $target"
}

$forwarded = @($args)
$hasProfile = $false
 $profile = 'debug'
 $explicitAgents = $false
 $explicitAgentsPatch = $false
 for ($index = 0; $index -lt $forwarded.Count; $index++) {
   $argument = [string]$forwarded[$index]
   if ($argument -ieq '-Profile') {
     $hasProfile = $true
     if ($index + 1 -lt $forwarded.Count -and -not [string]::IsNullOrWhiteSpace([string]$forwarded[$index + 1])) {
       $profile = [string]$forwarded[$index + 1]
     }
   } elseif ($argument -match '^-Profile=(.+)$') {
     $hasProfile = $true
     $profile = $Matches[1]
   } elseif ($argument -ieq '-EnableAgents') {
     $explicitAgents = $true
   } elseif ($argument -ieq '-AgentsPatchPath' -or $argument -match '^-AgentsPatchPath=') {
     $explicitAgentsPatch = $true
   }
}

function Test-AgentProvidersInstalled {
  param([Parameter(Mandatory = $true)][string]$ProfileName)

  $dshHome = if ([string]::IsNullOrWhiteSpace($env:DSH_HOME)) {
    Join-Path $env:USERPROFILE '.dsh'
  } else {
    [IO.Path]::GetFullPath($env:DSH_HOME)
  }
  $profileRoot = Join-Path $dshHome "profiles\$ProfileName"
  $required = @(
    (Join-Path $profileRoot 'node_modules\@deepseek-ai\dsh-subagent-acp\package.json'),
    (Join-Path $profileRoot 'node_modules\@deepseek-ai\dsh-subagent-codex\package.json')
  )
  return @($required | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf }).Count -eq $required.Count
}

$agentsReady = Test-AgentProvidersInstalled -ProfileName $profile
$enableAgents = $explicitAgents -or $explicitAgentsPatch -or $agentsReady
$defaults = if ($hasProfile) {
  @('-EnableCrashGuard', '-KeepAlive')
} else {
  @('-Profile', $profile, '-EnableCrashGuard', '-KeepAlive')
}
if ($enableAgents) {
  $defaults = @($defaults + '-EnableAgents')
} elseif (-not $explicitAgents -and -not $explicitAgentsPatch) {
  Write-Warning "未检测到 Profile '$profile' 的 Kimi/Codex Agent Provider；本次只启动 dsh-plugin-debug 核心。需要 Agent 时先运行 tools\\Install-DSH-Agents.ps1，或显式传 -EnableAgents。"
}
& powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $target @defaults @forwarded
exit $LASTEXITCODE
