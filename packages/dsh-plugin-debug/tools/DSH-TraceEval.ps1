[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][ValidateSet('contract', 'eval', 'live', 'baseline', 'profile')][string]$Action,
  [string]$InputPath = '',
  [string]$BaselinePath = '',
  [string]$CasePath = '',
  [string]$SessionId = '',
  [string]$HostName = '127.0.0.1',
  [int]$Port = 3081,
  [int]$MaxMessages = 500,
  [switch]$StrictBaseline
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $root 'DSH-Trace.psm1') -Force
Import-Module (Join-Path $root 'DSH-Guard.psm1') -Force

function Read-DshTraceJson {
  param([Parameter(Mandatory = $true)][string]$Path)
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "trace input does not exist: $Path" }
  $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
  if ($raw.Length -gt 4194304) { throw 'trace input is larger than 4 MiB' }
  try { return $raw | ConvertFrom-Json } catch { throw "trace input is not valid JSON: $($_.Exception.Message)" }
}

function Read-DshTraceCaseJson {
  param([Parameter(Mandatory = $true)][string]$Path)
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "trace case does not exist: $Path" }
  $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
  if ($raw.Length -gt 1048576) { throw 'trace case is larger than 1 MiB' }
  try { return $raw | ConvertFrom-Json } catch { throw "trace case is not valid JSON: $($_.Exception.Message)" }
}

function Write-DshTraceResult {
  param([string]$Result, [string]$Message, $Value = $null)
  [ordered]@{ result = $Result; action = $Action; message = $Message; value = $Value } | ConvertTo-Json -Depth 30
}

try {
  if ($MaxMessages -lt 1 -or $MaxMessages -gt 500) { throw 'MaxMessages must be between 1 and 500' }
  switch ($Action) {
    'contract' {
      if ([string]::IsNullOrWhiteSpace($InputPath)) { throw '-InputPath is required for trace contract' }
      $input = Read-DshTraceJson -Path $InputPath
      $trace = ConvertTo-DshTrace -InputObject $input -TraceSource 'file'
      $check = Test-DshTraceContract -Trace $trace
      if ($check.valid) { $contractResult = 'PASS'; $contractExit = 0 } else { $contractResult = 'FAIL'; $contractExit = 1 }
      Write-DshTraceResult -Result $contractResult -Message 'Normalized and checked a metadata-only session trace.' -Value ([ordered]@{ trace = $trace; contract = $check })
      exit $contractExit
    }
    'eval' {
      if ([string]::IsNullOrWhiteSpace($InputPath)) { throw '-InputPath is required for trace eval' }
      if ([string]::IsNullOrWhiteSpace($CasePath)) { throw '-CasePath is required for trace eval' }
      $trace = ConvertTo-DshTrace -InputObject (Read-DshTraceJson -Path $InputPath) -TraceSource 'file'
      $case = Read-DshTraceCaseJson -Path $CasePath
      $evaluation = Invoke-DshTraceEvaluation -Trace $trace -Case $case
      Write-DshTraceResult -Result ([string]$evaluation.status) -Message 'Evaluated metadata-only Tool Call assertions.' -Value $evaluation
      if ($evaluation.status -eq 'PASS') { exit 0 } else { exit 1 }
    }
    'baseline' {
      if ([string]::IsNullOrWhiteSpace($InputPath)) { throw '-InputPath is required for trace baseline' }
      if ([string]::IsNullOrWhiteSpace($BaselinePath)) { throw '-BaselinePath is required for trace baseline' }
      $current = ConvertTo-DshTrace -InputObject (Read-DshTraceJson -Path $InputPath) -TraceSource 'current'
      $baseline = ConvertTo-DshTrace -InputObject (Read-DshTraceJson -Path $BaselinePath) -TraceSource 'baseline'
      $comparison = Compare-DshTraceBaseline -Current $current -Baseline $baseline -Strict:$StrictBaseline
      Write-DshTraceResult -Result ([string]$comparison.status) -Message 'Compared two metadata-only Tool Call traces against a bounded baseline gate.' -Value $comparison
      if ($comparison.status -eq 'PASS' -or $comparison.status -eq 'WARN') { exit 0 } else { exit 1 }
    }
    'profile' {
      if ([string]::IsNullOrWhiteSpace($InputPath) -and [string]::IsNullOrWhiteSpace($SessionId)) { throw 'trace profile requires -InputPath or -SessionId' }
      if (-not [string]::IsNullOrWhiteSpace($InputPath)) {
        $profileInput = Read-DshTraceJson -Path $InputPath
        $profileSource = 'file'
      } else {
        $baseUrl = "http://$HostName`:$Port/"
        $profileInput = Invoke-DshGuardApi -BaseUrl $baseUrl -Method 'session.history' -Arguments @{ sessionId = $SessionId; maxMessages = $MaxMessages } -TimeoutSec 8
        $profileSource = 'session.history'
      }
      $profile = Get-DshTraceProfile -Trace (ConvertTo-DshTrace -InputObject $profileInput -TraceSource $profileSource)
      $profileContract = Test-DshTraceProfileContract -Report $profile
      if (-not $profileContract.valid) {
        Write-DshTraceResult -Result 'FAIL' -Message 'The metadata-only runtime profile failed its output contract.' -Value ([ordered]@{ profile = $profile; contract = $profileContract })
        exit 1
      }
      Write-DshTraceResult -Result ([string]$profile.status) -Message 'Built a bounded metadata-only runtime profile.' -Value ([ordered]@{ profile = $profile; contract = $profileContract })
      if ($profile.status -eq 'PASS') { exit 0 } else { exit 1 }
    }
    'live' {
      if ([string]::IsNullOrWhiteSpace($SessionId)) { throw '-SessionId is required for live trace evaluation' }
      $baseUrl = "http://$HostName`:$Port/"
      $history = Invoke-DshGuardApi -BaseUrl $baseUrl -Method 'session.history' -Arguments @{ sessionId = $SessionId; maxMessages = $MaxMessages } -TimeoutSec 8
      $trace = ConvertTo-DshTrace -InputObject $history -TraceSource 'session.history'
      if ([string]::IsNullOrWhiteSpace($CasePath)) {
        $check = Test-DshTraceContract -Trace $trace
        if ($check.valid) { $contractResult = 'PASS'; $contractExit = 0 } else { $contractResult = 'FAIL'; $contractExit = 1 }
        Write-DshTraceResult -Result $contractResult -Message 'Read and normalized one bounded live session.history page.' -Value ([ordered]@{ trace = $trace; contract = $check })
        exit $contractExit
      }
      $evaluation = Invoke-DshTraceEvaluation -Trace $trace -Case (Read-DshTraceCaseJson -Path $CasePath)
      Write-DshTraceResult -Result ([string]$evaluation.status) -Message 'Evaluated one bounded live session.history page.' -Value $evaluation
      if ($evaluation.status -eq 'PASS') { exit 0 } else { exit 1 }
    }
  }
} catch {
  Write-DshTraceResult -Result 'FAIL' -Message $_.Exception.Message
  exit 1
}
