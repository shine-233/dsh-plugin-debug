[CmdletBinding()]
param(
  [string]$Path = (Get-Location).Path,
  [switch]$Strict
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$node = Get-Command node.exe -ErrorAction SilentlyContinue
if ($null -eq $node) { throw '未找到 Node.js；hotswap 源码预检需要 Node.js 22 或更高版本' }

$scriptPath = Join-Path $PSScriptRoot 'Preflight-DSHHotswap.mjs'
$arguments = @('--path', [IO.Path]::GetFullPath($Path))
if ($Strict) { $arguments += '--strict' }

& $node.Path $scriptPath @arguments
$exitCode = if (Test-Path variable:LASTEXITCODE) { [int]$LASTEXITCODE } else { 0 }
exit $exitCode
