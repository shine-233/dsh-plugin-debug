[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$InputPath,
  [ValidateSet('daily', '24h', 'weekly', 'monthly', 'yearly', 'custom')][string]$Preset = 'weekly',
  [string]$From = '',
  [string]$To = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $InputPath -PathType Leaf)) {
  throw "Agent 报告输入文件不存在: $InputPath"
}

$node = Get-Command node.exe -ErrorAction SilentlyContinue
if ($null -eq $node) { throw '未找到 Node.js；离线 Agent 报告需要 Node.js 22 或更高版本' }

$scriptPath = Join-Path $PSScriptRoot 'Generate-DSHAgentReport.mjs'
$arguments = @('--input', [IO.Path]::GetFullPath($InputPath), '--preset', $Preset)
if (-not [string]::IsNullOrWhiteSpace($From)) { $arguments += @('--from', $From) }
if (-not [string]::IsNullOrWhiteSpace($To)) { $arguments += @('--to', $To) }

& $node.Path $scriptPath @arguments
$exitCode = if (Test-Path variable:LASTEXITCODE) { [int]$LASTEXITCODE } else { 0 }
exit $exitCode
