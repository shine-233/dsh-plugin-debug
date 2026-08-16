[CmdletBinding()]
param(
  [string]$Profile = 'debug',
  [switch]$ShowWindow
)

$ErrorActionPreference = 'Stop'
$LauncherRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$StateModulePath = Join-Path $LauncherRoot 'DSH-State.psm1'
Import-Module $StateModulePath -Force
$LogDir = Resolve-DshDebugLogRoot
$AgentsLog = Join-Path $LogDir 'agents-install.log'
$ProfileInitLog = Join-Path $LogDir 'agents-profile-init.log'
$PluginLog = Join-Path $LogDir 'agents-plugin-install.log'
$DumpLog = Join-Path $LogDir 'agents-config-dump.log'
$StartScript = Join-Path $LauncherRoot 'Start-DSH.ps1'
$Patch = Join-Path $LauncherRoot 'combined-agents.patch.yml'
$RuntimeEntry = Join-Path $LauncherRoot 'runtime\node_modules\@deepseek-ai\dsh\lib\bin.js'

function Show-InstallError {
  param([string]$Message)
  try {
    Add-Type -AssemblyName System.Windows.Forms
    [System.Windows.Forms.MessageBox]::Show(
      "$Message`n`n日志：$AgentsLog",
      'DSH 插件安装失败',
      [System.Windows.Forms.MessageBoxButtons]::OK,
      [System.Windows.Forms.MessageBoxIcon]::Error
    ) | Out-Null
  } catch {
    if ($ShowWindow) { Write-Error $Message }
  }
}

try {
  New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
  if (-not (Test-Path -LiteralPath $StartScript -PathType Leaf)) {
    throw "找不到启动器：$StartScript"
  }
  if (-not (Test-Path -LiteralPath $Patch -PathType Leaf)) {
    throw "找不到插件 overlay：$Patch"
  }
  if ([string]::IsNullOrWhiteSpace($env:DSH_HOME)) {
    $env:DSH_HOME = Join-Path $env:USERPROFILE '.dsh'
  }

  $pwshCommand = Get-Command powershell.exe -ErrorAction SilentlyContinue
  if ($null -eq $pwshCommand) {
    $pwshCommand = Get-Command pwsh.exe -ErrorAction SilentlyContinue
  }
  if ($null -eq $pwshCommand) {
    throw '找不到 PowerShell。'
  }
  $pwsh = $pwshCommand.Source

  # Reuse the launcher’s pinned-runtime check without starting a Web process.
  $startArgs = @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $StartScript, '-Profile', $Profile, '-InstallOnly')
  if ($ShowWindow) { $startArgs += '-ShowWindow' }
  & $pwsh @startArgs *> $AgentsLog
  if ($LASTEXITCODE -ne 0) {
    throw "DSH runtime 未就绪，退出码 $LASTEXITCODE"
  }
  if (-not (Test-Path -LiteralPath $RuntimeEntry -PathType Leaf)) {
    throw "找不到 DSH runtime entry：$RuntimeEntry"
  }

  $nodeCommand = Get-Command node.exe -ErrorAction SilentlyContinue
  if ($null -eq $nodeCommand) {
    $nodeCommand = Get-Command node -ErrorAction SilentlyContinue
  }
  if ($null -eq $nodeCommand) {
    throw '找不到 node.exe。'
  }
  $node = $nodeCommand.Source
  $packages = @(
    '@deepseek-ai/dsh-subagent-acp@0.1.0-rc.6',
    '@deepseek-ai/dsh-subagent-codex@0.1.0-rc.6',
    # The two Provider packages intentionally declare their DSH runtime
    # dependencies as peers. A standalone npm DSH install does not expose
    # every peer from its own app package, so keep this closure explicit in
    # the profile rather than relying on pnpm's auto-peer heuristics.
    '@deepseek-ai/dsh-agent@0.1.0-rc.6',
    '@deepseek-ai/dsh-invariants@0.1.0-rc.6',
    '@deepseek-ai/dsh-llm@0.1.0-rc.6',
    '@deepseek-ai/dsh-sdk-protocol@0.1.0-rc.6',
    '@deepseek-ai/dsh-session@0.1.0-rc.6',
    '@deepseek-ai/dsh-subagent@0.1.0-rc.6',
    '@deepseek-ai/dsh-subprocess@0.1.0-rc.6',
    '@deepseek-ai/dsh-timeout@0.1.0-rc.6',
    '@deepseek-ai/cordis@4.0.1',
    'zod@4.4.3',
    '@deepseek-ai/dsh-attachment@0.1.0-rc.6',
    '@deepseek-ai/dsh-brand@0.1.0-rc.6',
    '@deepseek-ai/dsh-scope@0.1.0-rc.6',
    '@deepseek-ai/dsh-system-prompt@0.1.0-rc.6',
    '@deepseek-ai/dsh-tools@0.1.0-rc.6',
    '@deepseek-ai/dsh-typert-protocol@0.1.0-rc.6'
  )
  Add-Content -LiteralPath $AgentsLog -Value "安装 DSH 外部 Agent Provider：$($packages -join ', ')" -Encoding UTF8
  # Initialize the shipped Web profile without starting a server. We use
  # pnpm directly for these plain dependencies: dsh plugin's own forwarding
  # path is intentionally reserved for bundle reconciliation, while these
  # Provider packages do not declare dsh.bundle.
  & $node $RuntimeEntry --profile $Profile --dump-default-config 1> $ProfileInitLog 2>&1
  $profileInitExit = $LASTEXITCODE
  if ($profileInitExit -ne 0) {
    throw "DSH $Profile profile 初始化失败，退出码 $profileInitExit；详见 $ProfileInitLog"
  }
  $profileDir = Join-Path $env:DSH_HOME "profiles\$Profile"
  $pnpmCommand = Get-Command pnpm.cmd -ErrorAction SilentlyContinue
  if ($null -eq $pnpmCommand) { $pnpmCommand = Get-Command pnpm.exe -ErrorAction SilentlyContinue }
  if ($null -eq $pnpmCommand) { throw '找不到 pnpm.cmd；请先安装 pnpm。' }
  $pnpm = $pnpmCommand.Source
  & $pnpm --dir $profileDir add --save-exact --fetch-retries 1 --fetch-timeout 30000 @packages 1> $PluginLog 2>&1
  $pluginExit = $LASTEXITCODE
  Add-Content -LiteralPath $AgentsLog -Value "Provider 安装退出码：$pluginExit；详见 $PluginLog" -Encoding UTF8
  if ($pluginExit -ne 0) {
    throw "DSH 外部 Agent Provider 安装失败，退出码 $pluginExit"
  }

  # Config dump loads and resolves the plugin rows without starting Web or
  # invoking Kimi/Codex. It is the safest available static validation gate.
  & $node $RuntimeEntry --profile $Profile --patch $Patch --dump-config 1> $DumpLog 2>&1
  $dumpExit = $LASTEXITCODE
  Add-Content -LiteralPath $AgentsLog -Value "插件 overlay 静态校验退出码：$dumpExit；详见 $DumpLog" -Encoding UTF8
  if ($dumpExit -ne 0) {
    throw "插件 overlay 静态校验失败，退出码 $dumpExit"
  }
  if ($ShowWindow) {
    Write-Host 'DSH 的 Kimi ACP 与 Codex Provider 已安装，overlay 静态校验通过。'
  }
  exit 0
} catch {
  $message = $_.Exception.Message
  try { Add-Content -LiteralPath $AgentsLog -Value "ERROR $message" -Encoding UTF8 } catch {}
  Show-InstallError $message
  exit 1
}
