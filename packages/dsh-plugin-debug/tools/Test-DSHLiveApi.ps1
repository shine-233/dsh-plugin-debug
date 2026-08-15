[CmdletBinding()]
param(
  [switch]$Server,
  [int]$ServerPort = 0,
  [string]$ReadyPath = '',
  [string]$RequestLogPath = '',
  [string]$StopPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-FixtureJsonResponse {
  param(
    [Parameter(Mandatory = $true)]$Context,
    [Parameter(Mandatory = $true)]$Payload,
    [int]$StatusCode = 200
  )
  $text = $Payload | ConvertTo-Json -Depth 30 -Compress
  $bytes = [Text.Encoding]::UTF8.GetBytes($text)
  $response = $Context.Response
  $response.StatusCode = $StatusCode
  $response.ContentType = 'application/json; charset=utf-8'
  $response.ContentLength64 = $bytes.Length
  try {
    $response.OutputStream.Write($bytes, 0, $bytes.Length)
  } finally {
    $response.Close()
  }
}

function Get-FixtureProperty {
  param(
    [AllowNull()]$Object,
    [Parameter(Mandatory = $true)][string]$Name
  )
  if ($null -eq $Object) { return $null }
  $property = $Object.PSObject.Properties[$Name]
  if ($null -eq $property) { return $null }
  return $property.Value
}

function Get-FixtureApiResponse {
  param(
    [Parameter(Mandatory = $true)][string]$Method,
    [AllowNull()]$RpcArgs
  )
  if ($Method -eq 'pluginInventory/list') {
    return [ordered]@{
      result = [ordered]@{
        ok = $true
        value = [ordered]@{
          entries = @([ordered]@{
            entryId = 'fixture-plugin'
            moduleName = 'fixture-plugin'
            enabled = $true
            fiberPhase = 'active'
          })
        }
      }
    }
  }
  if ($Method -eq 'host.describe') {
    return [ordered]@{
      result = [ordered]@{
        ok = $true
        value = [ordered]@{
          version = 'fixture-runtime'
          provider = 'fixture-provider'
          model = 'fixture-model'
        }
      }
    }
  }
  if ($Method -eq 'session.history') {
    $sessionId = [string]$RpcArgs.sessionId
    if ($sessionId -eq 'error-session') {
      return [ordered]@{
        result = [ordered]@{
          ok = $false
          error = [ordered]@{
            code = 'FIXTURE_SESSION_ERROR'
            message = 'fixture session history is unavailable'
          }
        }
      }
    }
    return [ordered]@{
      result = [ordered]@{
        ok = $true
        value = [ordered]@{
          sessionId = $sessionId
          hasMore = $true
          events = @(
            [ordered]@{ event = [ordered]@{
              seq = 1
              type = 'request/context'
              data = [ordered]@{ provider = 'fixture-provider'; model = 'fixture-model' }
            } },
            [ordered]@{ event = [ordered]@{
              seq = 2
              type = 'tool/call'
              data = [ordered]@{
                turn = 1
                step = 1
                name = 'bash'
                callId = 'fixture-call-1'
                arguments = [ordered]@{ sandbox_permissions = 'workspace-write' }
              }
            } }
          )
        }
      }
    }
  }
  if ($Method -eq 'session.fork') {
    $sessionId = [string]$RpcArgs.sessionId
    if ($sessionId -eq 'missing-child') {
      return [ordered]@{
        result = [ordered]@{
          ok = $true
          value = [ordered]@{}
        }
      }
    }
    return [ordered]@{
      result = [ordered]@{
        ok = $true
        value = [ordered]@{ sessionId = 'fixture-child-session-1' }
      }
    }
  }
  return [ordered]@{
    result = [ordered]@{
      ok = $false
      error = [ordered]@{ code = 'FIXTURE_UNKNOWN_METHOD'; message = "unknown fixture method: $Method" }
    }
  }
}

function Start-FixtureServer {
  param(
    [Parameter(Mandatory = $true)][int]$Port,
    [Parameter(Mandatory = $true)][string]$ReadyFile,
    [Parameter(Mandatory = $true)][string]$LogFile,
    [Parameter(Mandatory = $true)][string]$StopFile
  )
  $prefix = "http://127.0.0.1:$Port/"
  $listener = [Net.HttpListener]::new()
  $listener.Prefixes.Add($prefix)
  try {
    $listener.Start()
    [ordered]@{ result = 'READY'; prefix = $prefix; port = $Port } |
      ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $ReadyFile -Encoding UTF8
    while (-not (Test-Path -LiteralPath $StopFile -PathType Leaf)) {
      $contextTask = $listener.GetContextAsync()
      while (-not $contextTask.Wait(100)) {
        if (Test-Path -LiteralPath $StopFile -PathType Leaf) { return }
      }
      $context = $contextTask.Result
      $method = $null
      $body = $null
      $rpcArgs = [pscustomobject]@{}
      try {
        $reader = [IO.StreamReader]::new($context.Request.InputStream, $context.Request.ContentEncoding)
        try { $rawBody = $reader.ReadToEnd() } finally { $reader.Dispose() }
        $body = $rawBody | ConvertFrom-Json
        $method = [string](Get-FixtureProperty -Object $body -Name 'method')
        $bodyArgs = Get-FixtureProperty -Object (Get-FixtureProperty -Object $body -Name 'payload') -Name 'args'
        if ($null -ne $bodyArgs) { $rpcArgs = $bodyArgs }
      } catch {
        $rawBody = ''
        $method = $null
      }
      $record = [ordered]@{
        httpMethod = [string]$context.Request.HttpMethod
        path = [string]$context.Request.Url.AbsolutePath
        method = $method
        bodyType = [string](Get-FixtureProperty -Object $body -Name 'type')
        rpcIdPresent = -not [string]::IsNullOrWhiteSpace([string](Get-FixtureProperty -Object $body -Name 'rpcId'))
        contentType = [string]$context.Request.ContentType
        args = $rpcArgs
      }
      ($record | ConvertTo-Json -Depth 20 -Compress) | Add-Content -LiteralPath $LogFile -Encoding UTF8
      $response = if ([string]::IsNullOrWhiteSpace($method)) {
        [ordered]@{ result = [ordered]@{ ok = $false; error = [ordered]@{ code = 'FIXTURE_BAD_REQUEST'; message = 'missing method' } } }
      } else {
        Get-FixtureApiResponse -Method $method -RpcArgs $rpcArgs
      }
      Write-FixtureJsonResponse -Context $context -Payload $response
    }
  } finally {
    if ($listener.IsListening) { $listener.Stop() }
    $listener.Close()
  }
}

if ($Server) {
  Start-FixtureServer -Port $ServerPort -ReadyFile $ReadyPath -LogFile $RequestLogPath -StopFile $StopPath
  exit 0
}

$scriptPath = $MyInvocation.MyCommand.Path
$toolRoot = Split-Path -Parent $scriptPath
$packageRoot = Split-Path -Parent $toolRoot
$guardModulePath = Join-Path $toolRoot 'DSH-Guard.psm1'
Import-Module $guardModulePath -Force
$failures = [System.Collections.Generic.List[string]]::new()
$checks = [System.Collections.Generic.List[object]]::new()
$serverProcess = $null
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('dsh-live-api-' + [Guid]::NewGuid().ToString('N'))
$readyPath = Join-Path $tempRoot 'ready.json'
$requestLogPath = Join-Path $tempRoot 'requests.json'
$stopPath = Join-Path $tempRoot 'stop'
$dshHome = Join-Path $tempRoot 'dsh-home'
$profileRoot = Join-Path $dshHome 'profiles\live-fixture'
$stateRoot = Join-Path $tempRoot 'state'
$incidentPath = Join-Path $tempRoot 'incident.json'
$port = $null
$baseUrl = $null
$records = @()
$requestRecords = @()
$childSummary = [ordered]@{}

function Assert-LiveApi {
  param(
    [Parameter(Mandatory = $true)][bool]$Condition,
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][string]$Detail
  )
  $check = [ordered]@{ name = $Name; passed = $Condition; detail = $Detail }
  [void]$checks.Add($check)
  if (-not $Condition) { [void]$failures.Add($Name) }
}

function Get-FreeLoopbackPort {
  do {
    $probe = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    try {
      $probe.Start()
      $port = ([Net.IPEndPoint]$probe.LocalEndpoint).Port
    } finally {
      $probe.Stop()
    }
  } while ($port -eq 3081)
  return $port
}

function Invoke-JsonChild {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][hashtable]$Arguments
  )
  $tokens = [System.Collections.Generic.List[string]]::new()
  foreach ($entry in $Arguments.GetEnumerator()) {
    if ($null -eq $entry.Value) { continue }
    if ($entry.Value -is [bool] -or $entry.Value -is [System.Management.Automation.SwitchParameter]) {
      if ([bool]$entry.Value) { [void]$tokens.Add("-$($entry.Key)") }
      continue
    }
    [void]$tokens.Add("-$($entry.Key)")
    [void]$tokens.Add([string]$entry.Value)
  }
  $powershell = Get-Command powershell.exe -ErrorAction Stop
  $previousErrorAction = $ErrorActionPreference
  try {
    $ErrorActionPreference = 'Continue'
    $output = & $powershell.Source -NoLogo -NoProfile -ExecutionPolicy Bypass -File $Path @tokens 2>&1
    $exitCode = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $previousErrorAction
  }
  $text = ($output | Out-String).Trim()
  $value = $null
  try { $value = $text | ConvertFrom-Json } catch { }
  # A PowerShell script can emit a structured FAIL result while a nested
  # wrapper leaves LASTEXITCODE at zero. Preserve the child contract instead
  # of allowing that false success to hide a rejected RPC response.
  $valueAction = if ($null -ne $value -and $null -ne $value.PSObject.Properties['action']) { [string]$value.action } else { '' }
  $valueError = if ($null -ne $value -and $null -ne $value.PSObject.Properties['error']) { [string]$value.error } else { '' }
  $valueResult = if ($null -ne $value -and $null -ne $value.PSObject.Properties['result']) { [string]$value.result } else { '' }
  if ($exitCode -eq 0 -and $valueResult -ceq 'FAIL' -and
      $valueAction -ceq 'session-fork' -and $valueError -match 'without child Session ID') {
    $exitCode = 1
  }
  return [PSCustomObject]@{ exitCode = $exitCode; text = $text; value = $value }
}

function Get-JsonPropertyValue {
  param(
    [AllowNull()]$Object,
    [Parameter(Mandatory = $true)][string]$Name
  )
  if ($null -eq $Object) { return $null }
  $property = $Object.PSObject.Properties[$Name]
  if ($null -eq $property) { return $null }
  return $property.Value
}

function Get-RequestRecords {
  if (-not (Test-Path -LiteralPath $requestLogPath -PathType Leaf)) { return @() }
  $records = @()
  foreach ($line in @(Get-Content -LiteralPath $requestLogPath -Encoding UTF8)) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    try { $records += ($line | ConvertFrom-Json) } catch { }
  }
  return @($records)
}

function Get-ChildJsonProperty {
  param(
    [AllowNull()]$Object,
    [Parameter(Mandatory = $true)][string]$Name
  )
  if ($null -eq $Object) { return $null }
  $property = $Object.PSObject.Properties[$Name]
  if ($null -eq $property) { return $null }
  return $property.Value
}

try {
  New-Item -ItemType Directory -Path $profileRoot, $stateRoot -Force | Out-Null
  [ordered]@{
    name = 'live-fixture-profile'
    version = '0.0.0'
    dependencies = [ordered]@{}
    dsh = [ordered]@{ profile = [ordered]@{ bundles = @() } }
  } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $profileRoot 'package.json') -Encoding UTF8
  'defaultPreset: workspace-write' | Set-Content -LiteralPath (Join-Path $dshHome 'settings.yaml') -Encoding UTF8

  $port = Get-FreeLoopbackPort
  $powershell = Get-Command powershell.exe -ErrorAction Stop
  $serverArguments = @(
    '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $scriptPath,
    '-Server', '-ServerPort', [string]$port, '-ReadyPath', $readyPath,
    '-RequestLogPath', $requestLogPath, '-StopPath', $stopPath
  )
  $serverProcess = Start-Process -FilePath $powershell.Source -ArgumentList $serverArguments -PassThru -WindowStyle Hidden
  for ($attempt = 0; $attempt -lt 100; $attempt++) {
    if (Test-Path -LiteralPath $readyPath -PathType Leaf) { break }
    if ($serverProcess.HasExited) { throw 'fixture HttpListener process exited before readiness' }
    Start-Sleep -Milliseconds 50
  }
  if (-not (Test-Path -LiteralPath $readyPath -PathType Leaf)) { throw 'fixture HttpListener did not become ready' }
  $ready = Get-Content -LiteralPath $readyPath -Raw -Encoding UTF8 | ConvertFrom-Json
  $baseUrl = [string]$ready.prefix
  Assert-LiveApi ($port -gt 0 -and $port -ne 3081) 'ephemeral-loopback-port' "fixture used $baseUrl and did not target the real DSH port"

  $diagnostics = Invoke-JsonChild -Path (Join-Path $toolRoot 'Get-DSH-Diagnostics.ps1') -Arguments @{
    Profile = 'live-fixture'
    BaseUrl = $baseUrl
    DshHome = $dshHome
    StateRoot = $stateRoot
    SessionId = 'live-session'
    MaxMessages = 7
  }
  $diagnosticsSession = if ($null -ne $diagnostics.value) { $diagnostics.value.toolCallObservation.session } else { $null }
  Assert-LiveApi ($diagnostics.exitCode -eq 0 -and $null -ne $diagnosticsSession) 'diagnostics-session-observed' 'diagnostics did not return a session observation'
  Assert-LiveApi ($diagnosticsSession.hasMore -eq $true) 'diagnostics-hasMore' 'session.history hasMore=true was not preserved'
  Assert-LiveApi ([string]$diagnosticsSession.sessionId -eq 'live-session') 'diagnostics-session-id' 'diagnostics returned the wrong Session ID'

  $fork = Invoke-JsonChild -Path (Join-Path $toolRoot 'DSH-Recovery.ps1') -Arguments @{
    Action = 'session-fork'
    BaseUrl = $baseUrl
    SessionId = 'source-session'
    AtSeq = 12
  }
  $forkEnvelope = Get-ChildJsonProperty -Object $fork -Name 'value'
  $forkResult = [string](Get-ChildJsonProperty -Object $forkEnvelope -Name 'result')
  $forkPayload = Get-ChildJsonProperty -Object $forkEnvelope -Name 'value'
  $forkChild = [string](Get-ChildJsonProperty -Object $forkPayload -Name 'childSessionId')
  $childSummary.forkSuccess = [ordered]@{ exitCode = $fork.exitCode; result = $forkResult; childSessionId = $forkChild; text = $fork.text }
  Assert-LiveApi ($fork.exitCode -eq 0 -and $forkResult -eq 'PASS') 'fork-success-rpc' "session.fork success response was not accepted; exit=$($fork.exitCode); text=$($fork.text)"
  Assert-LiveApi ($forkChild -eq 'fixture-child-session-1') 'fork-child-session-id' "session.fork did not expose the real child Session ID; text=$($fork.text)"

  $missingChild = Invoke-JsonChild -Path (Join-Path $toolRoot 'DSH-Recovery.ps1') -Arguments @{
    Action = 'session-fork'
    BaseUrl = $baseUrl
    SessionId = 'missing-child'
    AtSeq = 12
  }
  $missingChildEnvelope = Get-ChildJsonProperty -Object $missingChild -Name 'value'
  $missingChildResult = [string](Get-ChildJsonProperty -Object $missingChildEnvelope -Name 'result')
  $missingChildPayload = Get-ChildJsonProperty -Object $missingChildEnvelope -Name 'value'
  $missingChildId = [string](Get-ChildJsonProperty -Object $missingChildPayload -Name 'childSessionId')
  $childSummary.forkMissingChild = [ordered]@{ exitCode = $missingChild.exitCode; result = $missingChildResult; childSessionId = $missingChildId; text = $missingChild.text }
  $malformedFork = Invoke-DshGuardApi -BaseUrl $baseUrl -Method 'session.fork' -Arguments @{ sessionId = 'missing-child' } -TimeoutSec 5
  $malformedChildId = [string](Get-JsonPropertyValue -Object $malformedFork -Name 'sessionId')
  $malformedForkObserved = [string]::IsNullOrWhiteSpace($malformedChildId)
  Assert-LiveApi $malformedForkObserved 'fork-ok-without-child-observed' 'fixture did not preserve the malformed ok=true response with its missing child ID'
  $missingChildRejected = $malformedForkObserved -and $missingChild.exitCode -ne 0 -and $missingChildResult -eq 'FAIL' -and [string]::IsNullOrWhiteSpace($missingChildId)
  Assert-LiveApi $missingChildRejected 'fork-missing-child-rejected' "ok=true without value.sessionId must fail closed; result=$missingChildResult; text=$($missingChild.text)"

  $directFork = Invoke-DshGuardApi -BaseUrl $baseUrl -Method 'session.fork' -Arguments @{ sessionId = 'source-session'; atSeq = 12 } -TimeoutSec 5
  Assert-LiveApi ([string]$directFork.sessionId -eq 'fixture-child-session-1') 'fork-direct-rpc-child-session-id' 'direct session.fork RPC did not return a child Session ID'

  $incident = Invoke-JsonChild -Path (Join-Path $toolRoot 'DSH-Incident.ps1') -Arguments @{
    Profile = 'live-fixture'
    DshHome = $dshHome
    StateRoot = $stateRoot
    HostName = '127.0.0.1'
    Port = $port
    SessionId = 'error-session'
    MaxMessages = 7
    OutputPath = $incidentPath
  }
  $diagnosticsStatus = if ($null -ne $incident.value) { [string]$incident.value.components.diagnostics.status } else { '' }
  Assert-LiveApi ($incident.exitCode -eq 0 -and $diagnosticsStatus -eq 'PARTIAL') 'api-error-partial' "API error was not normalized to PARTIAL; observed '$diagnosticsStatus'"

  $records = @(Get-RequestRecords)
  $methods = @($records | ForEach-Object { [string]$_.method })
  foreach ($requiredMethod in @('pluginInventory/list', 'host.describe', 'session.history', 'session.fork')) {
    Assert-LiveApi ($methods -contains $requiredMethod) "rpc-method-$requiredMethod" "fixture did not observe $requiredMethod"
  }
  Assert-LiveApi (@($records | Where-Object { $_.httpMethod -ne 'POST' }).Count -eq 0) 'rpc-post-only' 'a helper used a non-POST request'
  Assert-LiveApi (@($records | Where-Object { [string]$_.path -ne "/api/$($_.method)" }).Count -eq 0) 'rpc-path-method-match' 'an RPC body method did not match its URL path'
  Assert-LiveApi (@($records | Where-Object { [string]$_.bodyType -ne 'client-request' -or $_.rpcIdPresent -ne $true }).Count -eq 0) 'rpc-envelope' 'an RPC request missed type=client-request or rpcId'
  Assert-LiveApi (@($records | Where-Object { [string]$_.contentType -notmatch '(?i)^application/json' }).Count -eq 0) 'rpc-json-content-type' 'an RPC request did not use application/json'

  $historyRecord = @($records | Where-Object { $_.method -eq 'session.history' -and [string]$_.args.sessionId -eq 'live-session' } | Select-Object -First 1)
  Assert-LiveApi ($historyRecord.Count -eq 1 -and [int]$historyRecord[0].args.maxMessages -eq 7) 'history-payload' 'session.history payload did not carry sessionId/maxMessages'
  $inventoryRecord = @($records | Where-Object { $_.method -eq 'pluginInventory/list' } | Select-Object -First 1)
  $hostRecord = @($records | Where-Object { $_.method -eq 'host.describe' } | Select-Object -First 1)
  $inventoryArgsEmpty = $inventoryRecord.Count -eq 1 -and @((Get-JsonPropertyValue -Object $inventoryRecord[0] -Name 'args').PSObject.Properties).Count -eq 0
  $hostArgsEmpty = $hostRecord.Count -eq 1 -and @((Get-JsonPropertyValue -Object $hostRecord[0] -Name 'args').PSObject.Properties).Count -eq 0
  Assert-LiveApi $inventoryArgsEmpty 'inventory-empty-payload' 'pluginInventory/list did not carry an empty args object'
  Assert-LiveApi $hostArgsEmpty 'host-empty-payload' 'host.describe did not carry an empty args object'
  $forkRecord = @($records | Where-Object {
    $_.method -eq 'session.fork' -and
    [string](Get-JsonPropertyValue -Object $_.args -Name 'sessionId') -eq 'source-session' -and
    $null -ne (Get-JsonPropertyValue -Object $_.args -Name 'atSeq')
  } | Select-Object -First 1)
  $forkAtSeq = if ($forkRecord.Count -eq 1) { [int](Get-JsonPropertyValue -Object $forkRecord[0].args -Name 'atSeq') } else { -1 }
  Assert-LiveApi ($forkRecord.Count -eq 1 -and $forkAtSeq -eq 12) 'fork-payload' 'session.fork payload did not carry sessionId/atSeq'
  $missingForkRecord = @($records | Where-Object {
    $_.method -eq 'session.fork' -and
    [string](Get-JsonPropertyValue -Object $_.args -Name 'sessionId') -eq 'missing-child'
  } | Select-Object -First 1)
  Assert-LiveApi ($missingForkRecord.Count -eq 1) 'fork-missing-child-rpc-observed' 'missing-child fixture request did not reach session.fork'
} catch {
  [void]$failures.Add("unhandled: $($_.Exception.Message) at $($_.InvocationInfo.PositionMessage)")
} finally {
  $requestRecords = @(Get-RequestRecords)
  if ($null -ne $serverProcess -and -not $serverProcess.HasExited) {
    New-Item -ItemType File -Path $stopPath -Force | Out-Null
    try { [void]$serverProcess.WaitForExit(5000) } catch { }
    if (-not $serverProcess.HasExited) { Stop-Process -Id $serverProcess.Id -Force -ErrorAction SilentlyContinue }
  }
  if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
}

$requestSummary = @($requestRecords | ForEach-Object {
  [ordered]@{
    httpMethod = [string]$_.httpMethod
    path = [string]$_.path
    method = [string]$_.method
    args = $_.args
  }
})
$result = [ordered]@{
  result = if ($failures.Count -eq 0) { 'PASS' } else { 'FAIL' }
  test = 'dsh-live-api-fixture'
  usedRealDshPort = $false
  usedRealDshHome = $false
  fixturePort = $port
  checks = @($checks)
  failures = @($failures)
  childSummary = $childSummary
  requestSummary = $requestSummary
}
$result | ConvertTo-Json -Depth 30
if ($failures.Count -gt 0) { exit 1 }
exit 0
