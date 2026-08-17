[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$packageRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$toolRoot = Join-Path $packageRoot 'tools'
. (Join-Path $toolRoot 'DSH-PowerShell.ps1')
$failures = [System.Collections.Generic.List[string]]::new()

function Assert-Standalone {
  param([bool]$Condition, [string]$Message)
  if (-not $Condition) { $failures.Add($Message) }
}

function Get-StandaloneSha256 {
  param([Parameter(Mandatory = $true)][string]$Path)
  $hashCommand = Get-Command Get-FileHash -ErrorAction SilentlyContinue
  if ($null -ne $hashCommand) {
    return [string](Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
  }
  $sha = [Security.Cryptography.SHA256]::Create()
  try {
    $bytes = [IO.File]::ReadAllBytes($Path)
    return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '')
  } finally {
    $sha.Dispose()
  }
}

function Stop-StandaloneProcessTree {
  param([Diagnostics.Process]$Process)
  if ($null -eq $Process) { return }
  try {
    if ($Process.HasExited) { return }
  } catch { return }

  # A fixture may start a server below the wrapper.  Killing only the
  # wrapper leaves that server alive and makes the next run look hung.
  $taskKill = Get-Command taskkill.exe -ErrorAction SilentlyContinue
  if ($null -ne $taskKill) {
    try {
      & $taskKill.Source /PID ([string]$Process.Id) /T /F *> $null
      return
    } catch { }
  }
  try { $Process.Kill() } catch { }
}

function Read-StandaloneTaskText {
  param(
    [Parameter(Mandatory = $true)]$Task,
    [int]$TimeoutMs = 5000
  )
  try {
    if (-not $Task.Wait($TimeoutMs)) { return $null }
    if (-not $Task.IsCompleted) { return $null }
    return [string]$Task.Result
  } catch {
    return $null
  }
}

function Get-StandalonePowerShellPath {
  return Get-DshPowerShellPath
}

function Invoke-PowerShellJson {
  param(
    [string]$ScriptPath,
    [hashtable]$Arguments,
    # The live API fixture intentionally starts a nested PowerShell HTTP
    # listener and exercises several child scripts.  On a cold Windows host
    # it takes about 33 seconds, so a 30-second wrapper timeout falsely marks
    # it as hung and leaves the listener behind.  Keep the timeout bounded,
    # but leave enough room for one cold fixture run.
    [int]$TimeoutSec = 60
  )
  $argumentMap = [ordered]@{}
  foreach ($entry in $Arguments.GetEnumerator()) {
    $value = $entry.Value
    if ($value -is [bool] -or $value -is [System.Management.Automation.SwitchParameter]) {
      if ([bool]$value) { $argumentMap[$entry.Key] = $true }
      continue
    }
    if ($null -eq $value -or ($value -is [string] -and [string]::IsNullOrWhiteSpace($value))) { continue }
    $argumentMap[$entry.Key] = $value
  }
  $process = $null
  $invocationWatch = [Diagnostics.Stopwatch]::StartNew()
  $scriptName = Split-Path -Leaf $ScriptPath
  Write-Host "[standalone] start $scriptName"
  try {
    # Start-Process returns a Process object whose ExitCode can remain null
    # after WaitForExit() when stdout/stderr are redirected under Windows
    # PowerShell.  That made a child `{ result: FAIL }` look like exit 0 and
    # masked the fail-closed repair assertions.  Launch the process directly
    # so the operating-system exit code is available after the bounded wait.
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $childPowerShell = Get-StandalonePowerShellPath
    $startInfo.FileName = $childPowerShell
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    # ProcessStartInfo on Windows PowerShell can start with a reduced module
    # search path when environment variables are assigned explicitly.  Keep
    # the standard module path so built-in commands such as Get-FileHash remain
    # available to the child script.
    $modulePath = [Environment]::GetEnvironmentVariable('PSModulePath')
    if ([string]::IsNullOrWhiteSpace($modulePath)) {
      $modulePath = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\Modules'
    }
    $startInfo.EnvironmentVariables['PSModulePath'] = $modulePath
    $startInfo.EnvironmentVariables['PATH'] = [Environment]::GetEnvironmentVariable('PATH')
    $startInfo.EnvironmentVariables['DSH_STANDALONE_CHILD_HOST'] = $childPowerShell
    $startInfo.EnvironmentVariables['DSH_STANDALONE_CHILD_SCRIPT'] = [IO.Path]::GetFullPath($ScriptPath)
    $startInfo.EnvironmentVariables['DSH_STANDALONE_CHILD_ARGS'] = (ConvertTo-Json -InputObject $argumentMap -Compress -Depth 12)
    # JSON is parsed in the child, then converted to real command-line tokens
    # for an external PowerShell process.  Splatting a hashtable directly into
    # an external process serializes switch values as strings (for example
    # `-Force True`), which Windows PowerShell cannot bind to SwitchParameter.
    # A token array is safe here because the target is the external host, not a
    # PowerShell function or script with positional parameter binding.
    $childCommand = '$parsedArgs = ConvertFrom-Json -InputObject $env:DSH_STANDALONE_CHILD_ARGS; $rawArgs = [System.Collections.Generic.List[string]]::new(); if ($null -ne $parsedArgs) { foreach ($property in $parsedArgs.PSObject.Properties) { $name = [string]$property.Name; $value = $property.Value; if ($value -is [bool]) { if ([bool]$value) { [void]$rawArgs.Add("-$name") }; continue }; if ($null -eq $value) { continue }; if ($value -is [System.Array]) { foreach ($item in $value) { if ($null -ne $item) { [void]$rawArgs.Add("-$name"); [void]$rawArgs.Add([string]$item) } } } else { [void]$rawArgs.Add("-$name"); [void]$rawArgs.Add([string]$value) } } }; & $env:DSH_STANDALONE_CHILD_HOST -NoLogo -NoProfile -ExecutionPolicy Bypass -File $env:DSH_STANDALONE_CHILD_SCRIPT @rawArgs; $invocationSucceeded = $LASTEXITCODE -eq 0; $childExit = if (Test-Path variable:LASTEXITCODE) { [int]$LASTEXITCODE } elseif ($invocationSucceeded) { 0 } else { 1 }; exit $childExit'
    $encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($childCommand))
    $startInfo.Arguments = "-NoLogo -NoProfile -ExecutionPolicy Bypass -EncodedCommand $encodedCommand"
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    if (-not $process.Start()) { throw "could not start child PowerShell: $ScriptPath" }
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit($TimeoutSec * 1000)) {
      Stop-StandaloneProcessTree -Process $process
      Start-Sleep -Milliseconds 100
      $timeoutText = "child PowerShell timed out after ${TimeoutSec}s: $ScriptPath"
      $invocationWatch.Stop()
      Write-Host "[standalone] timeout $scriptName after $([Math]::Round($invocationWatch.Elapsed.TotalSeconds, 1))s"
      return [PSCustomObject]@{ exitCode = 124; text = $timeoutText; value = $null }
    }
    # Do not call parameterless WaitForExit or GetResult here.  A nested
    # fixture can inherit a redirected handle after the wrapper exits, which
    # would otherwise block the whole standalone suite indefinitely.
    $exitCode = [int]$process.ExitCode
    $stdout = Read-StandaloneTaskText -Task $stdoutTask
    $stderr = Read-StandaloneTaskText -Task $stderrTask
    $outputDrainWarning = if ($null -eq $stdout -or $null -eq $stderr) {
      'child output did not close within 5s after process exit'
    } else {
      $null
    }
    if ($null -eq $stdout) { $stdout = '' }
    if ($null -eq $stderr) { $stderr = '' }
    # Windows PowerShell serializes progress records as CLIXML on the error
    # stream when stdout/stderr are redirected.  The child scripts keep their
    # JSON contract on stdout, so parse that stream first and use stderr only
    # as diagnostic text when stdout is empty.
    $primaryText = if (-not [string]::IsNullOrWhiteSpace($stdout)) { $stdout.Trim() } else { $stderr.Trim() }
    $text = if (-not [string]::IsNullOrWhiteSpace($stderr) -and -not [string]::IsNullOrWhiteSpace($stdout)) {
      "$primaryText`n$($stderr.Trim())"
    } else {
      $primaryText
    }
    if ($null -ne $outputDrainWarning) {
      $text = if ([string]::IsNullOrWhiteSpace($text)) { $outputDrainWarning } else { "$text`n$outputDrainWarning" }
    }
  } finally {
    if ($null -ne $process) { $process.Dispose() }
  }
  $invocationWatch.Stop()
  Write-Host "[standalone] done $scriptName exit=$exitCode after $([Math]::Round($invocationWatch.Elapsed.TotalSeconds, 1))s"
  $value = $null
  try {
    if (-not [string]::IsNullOrWhiteSpace($stdout)) {
      $value = $stdout.Trim() | ConvertFrom-Json
    } elseif (-not [string]::IsNullOrWhiteSpace($text)) {
      $value = $text | ConvertFrom-Json
    }
  } catch { }
  return [PSCustomObject]@{ exitCode = $exitCode; text = $text; value = $value }
}

function Invoke-StandaloneFixtureWithStartupRetry {
  param(
    [Parameter(Mandatory = $true)][string]$ScriptPath,
    [Parameter(Mandatory = $true)][hashtable]$Arguments,
    [int]$TimeoutSec = 90
  )

  $result = Invoke-PowerShellJson -ScriptPath $ScriptPath -Arguments $Arguments -TimeoutSec $TimeoutSec
  # HttpListener fixtures are deliberately launched in a child PowerShell.
  # A cold Windows host can occasionally terminate that child before its
  # readiness marker is written. Retry only that bounded startup condition;
  # assertion failures and protocol failures must remain real failures.
  $startupFailure = [string]$result.text -match '(?i)(?:HttpListener process exited before readiness|HttpListener did not become ready|HTTP fixture exited before readiness)'
  if ($result.exitCode -ne 0 -and $startupFailure) {
    Write-Host "[standalone] retry fixture startup: $(Split-Path -Leaf $ScriptPath)"
    Start-Sleep -Milliseconds 750
    return Invoke-PowerShellJson -ScriptPath $ScriptPath -Arguments $Arguments -TimeoutSec $TimeoutSec
  }
  return $result
}

$expected = @(
  'DSH-PowerShell.ps1',
  'DSH-Guard.psm1',
  'DSH-Repair.psm1',
  'DSH-Recovery.psm1',
  'DSH-Recovery.ps1',
  'DSH-SelfRepair.ps1',
  'Test-DSHSelfRepair.ps1',
  'DSH-Trace.psm1',
  'DSH-TraceAutopsy.psm1',
  'DSH-TraceEval.ps1',
  'DSH-TraceLoop.ps1',
  'Test-DSHTraceLoop.ps1',
  'DSH-TraceRecursion.ps1',
  'Test-DSHTraceRecursion.ps1',
  'Test-DSHTraceProfile.ps1',
  'DSH-IncidentCorrelation.psm1',
  'Test-DSHTraceAutopsy.ps1',
  'Test-DSHIncidentCorrelation.ps1',
  'Test-DSHLiveApi.ps1',
  'Test-DSHCompatibility.ps1',
  'DSH-KnownGood.psm1',
  'Test-DSHKnownGood.ps1',
  'Test-DSHPointerBrowser.ps1',
  'DSH-Incident.ps1',
  'DSH-ResourcePressure.psm1',
  'DSH-Repro.ps1',
  'Test-DSHRepro.ps1',
  'Test-DSHResourcePressure.ps1',
  'Test-DSHIncidentRuntimeEvidence.ps1',
  'Test-DSHCrashGuard.ps1',
  'DSH-Workbench.ps1',
  'Get-DSH-Diagnostics.ps1',
  'Get-DSH-PluginHealth.ps1',
  'Set-DSHPluginState.ps1',
  'Start-DSH.ps1',
  'Test-DSHLauncherConflict.ps1',
  'DSH-Bisect.ps1',
  'Test-DSHBisect.ps1',
  'DSH-Preflight.ps1',
  'Test-DSHPreflight.ps1',
  'Get-DSHGuardianStatus.ps1',
  'Test-DSHGuardianStatus.ps1',
  'DSH-DependencyGraph.ps1',
  'Test-DSHDependencyGraph.ps1',
  'DSH-TraceLoop.ps1',
  'Test-DSHTraceLoop.ps1',
  'DSH-DiagnosticsDiff.ps1',
  'Test-DSHDiagnosticsDiff.ps1',
  'DSH-ProvenanceSuite.ps1',
  'Test-DSHRuntimeSupervisor.ps1',
  'runtime\package.json',
  'fixtures\tool-call-trace.json',
  'fixtures\tool-call-case.json',
  'fixtures\tool-call-baseline.json',
  'fixtures\tool-call-incomplete-page.json',
  'fixtures\tool-call-incomplete-page-case.json',
  'fixtures\pointer-browser.html',
  'fixtures\plugin-bisect-plan.json',
  'fixtures\plugin-dependency-graph.json',
  'fixtures\trace-loop.json',
  'fixtures\trace-recursion.json'
)
$repoRoot = [IO.Path]::GetFullPath((Split-Path -Parent (Split-Path -Parent $packageRoot)))
$publishHelper = Join-Path $packageRoot 'Publish-GitHub.ps1'
$repoGit = Join-Path $repoRoot '.git'
$hasRepoGit = (Test-Path -LiteralPath $repoGit -PathType Container) -or (Test-Path -LiteralPath $repoGit -PathType Leaf)
if ((Test-Path -LiteralPath $publishHelper -PathType Leaf) -and $hasRepoGit) {
  try {
    $publishDryRun = & $publishHelper -DryRun 2>&1 | Out-String
    Assert-Standalone ($LASTEXITCODE -eq 0) 'Publish-GitHub.ps1 -DryRun failed'
    Assert-Standalone ($publishDryRun -match '"wouldInitializeGit"\s*:\s*false') 'Publish-GitHub.ps1 dry run would initialize a repository'
    Assert-Standalone ($publishDryRun -notmatch '(?i)nestedGit.*true') 'Publish-GitHub.ps1 dry run detected nested .git'
  } catch {
    Assert-Standalone $false "Publish-GitHub.ps1 dry run threw: $($_.Exception.Message)"
  }
} else {
  Write-Host '[standalone] publication helper skipped: package-only layout'
}
foreach ($relative in $expected) {
  Assert-Standalone (Test-Path -LiteralPath (Join-Path $toolRoot $relative) -PathType Leaf) "missing standalone file: $relative"
}

$powerShellFiles = @(Get-ChildItem -LiteralPath $toolRoot -File | Where-Object { $_.Extension -in @('.ps1', '.psm1') })
foreach ($file in $powerShellFiles) {
  $tokens = $null
  $errors = $null
  [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors) | Out-Null
  Assert-Standalone ($errors.Count -eq 0) "PowerShell parse errors: $($file.Name)"
}

$standaloneLauncherText = Get-Content -LiteralPath (Join-Path $toolRoot 'Start-DSH.ps1') -Raw -Encoding UTF8
Assert-Standalone ($standaloneLauncherText -notmatch '(?i)plugin.?store') 'standalone launcher still contains plugin-store coupling'
Assert-Standalone ($standaloneLauncherText -notmatch '(?i)dsh-one-click') 'standalone launcher references dsh-one-click'
foreach ($generatedEntry in @('index.js', 'client.js', 'hotswap-check.js', 'agent-report.js', 'repository-check.js', 'tool-adapter.js', 'task-guardian.js')) {
  Assert-Standalone (Test-Path -LiteralPath (Join-Path $packageRoot "lib\$generatedEntry") -PathType Leaf) "missing generated entry: lib/$generatedEntry"
}

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('dsh-provenance-standalone-' + [Guid]::NewGuid().ToString('N'))
$fixtureRoot = Join-Path $tempRoot 'workspace'
$fixtureDsh = Join-Path $tempRoot 'dsh-home'
$fixtureState = Join-Path $tempRoot 'state'
$fixtureChecks = 0
try {
  New-Item -ItemType Directory -Path $fixtureRoot,$fixtureDsh,$fixtureState -Force | Out-Null
  [IO.File]::WriteAllText((Join-Path $fixtureRoot 'AGENTS.md'), 'Use the test workspace.`n', [Text.UTF8Encoding]::new($false))
  [IO.File]::WriteAllText((Join-Path $fixtureRoot 'CONTEXT.md'), 'The test workspace is isolated.`n', [Text.UTF8Encoding]::new($false))
  $fixtureProfileRoot = Join-Path $fixtureDsh 'profiles\test'
  New-Item -ItemType Directory -Path $fixtureProfileRoot -Force | Out-Null
  [IO.File]::WriteAllText((Join-Path $fixtureProfileRoot 'package.json'), (@{
    name = 'fixture-profile'
    version = '0.0.0'
    dependencies = [ordered]@{ 'test-dsh-plugin' = 'file:..\..\test-dsh-plugin' }
    # Deliberately declare a bundle that is absent from the isolated fixture.
    # This gives incident-capture a real plugin-health error instead of only
    # the warning produced by an empty bundle list.
    dsh = [ordered]@{ profile = [ordered]@{ bundles = @('test-dsh-plugin') } }
  } | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
  [IO.File]::WriteAllText((Join-Path $fixtureProfileRoot 'cordis.yml'), "- id: fixture`n", [Text.UTF8Encoding]::new($false))
  [IO.File]::WriteAllText((Join-Path $fixtureProfileRoot 'cordis.patch.yml'), "- id: fixture`n", [Text.UTF8Encoding]::new($false))
  [IO.File]::WriteAllText((Join-Path $fixtureProfileRoot 'pnpm-workspace.yaml'), "packages: []`n", [Text.UTF8Encoding]::new($false))
  [IO.File]::WriteAllText((Join-Path $fixtureDsh 'settings.yaml'), "defaultPreset: workspace-write`n", [Text.UTF8Encoding]::new($false))
  [IO.File]::WriteAllText((Join-Path $fixtureDsh '.env'), "API_KEY=fixture-secret`n", [Text.UTF8Encoding]::new($false))

  $suite = Join-Path $toolRoot 'DSH-ProvenanceSuite.ps1'
  $doctor = Invoke-PowerShellJson -ScriptPath $suite -Arguments @{ Action = 'context-doctor'; Root = $fixtureRoot; DshHome = $fixtureDsh }
  Assert-Standalone ($doctor.exitCode -eq 0 -and $doctor.value.result -eq 'PASS') 'context-doctor did not return PASS'
  Assert-Standalone ([int]$doctor.value.totalFiles -ge 2) 'context-doctor did not inspect fixture files'
  $fixtureChecks++

  $security = Invoke-PowerShellJson -ScriptPath $suite -Arguments @{ Action = 'security-audit'; DshHome = $fixtureDsh; Profile = 'test' }
  Assert-Standalone ($security.exitCode -eq 0 -and $security.value.result -eq 'PASS') 'security-audit did not return PASS'
  Assert-Standalone ($security.value.envContentRead -eq $false) 'security-audit claims it read env content'
  $fixtureChecks++

  $defaultSessionRoot = Join-Path $fixtureDsh 'sessions'
  New-Item -ItemType Directory -Path $defaultSessionRoot -Force | Out-Null
  $defaultSessionPath = Join-Path $defaultSessionRoot 'fixture.jsonl'
  [IO.File]::WriteAllText($defaultSessionPath, "{`"type`":`"session/start`"}`n", [Text.UTF8Encoding]::new($false))
  $defaultHealth = Invoke-PowerShellJson -ScriptPath $suite -Arguments @{ Action = 'session-health'; DshHome = $fixtureDsh; Profile = 'test' }
  Assert-Standalone ($defaultHealth.exitCode -eq 0 -and $defaultHealth.value.result -eq 'PASS') 'default session-health did not return PASS'
  Assert-Standalone ($defaultHealth.value.filesScanned -eq 1) 'default session-health scanned files outside the session roots'
  Assert-Standalone (@($defaultHealth.value.observations)[0].inputMode -eq 'default-root') 'default session-health did not identify its discovery mode'
  $fixtureChecks++

  $sessionPath = Join-Path $tempRoot 'session.jsonl'
  $sessionText = [string]::Join("`n", @('{"type":"session/start"}', '{"type":"broken"')) + "`n"
  [IO.File]::WriteAllText($sessionPath, $sessionText, [Text.UTF8Encoding]::new($false))
  $health = Invoke-PowerShellJson -ScriptPath $suite -Arguments @{ Action = 'session-health'; InputPath = $sessionPath; DshHome = $fixtureDsh; Profile = 'test' }
  Assert-Standalone ($health.exitCode -eq 0 -and $health.value.result -eq 'PASS') 'session-health did not return PASS'
  Assert-Standalone (@($health.value.observations)[0].status -eq 'torn-tail') 'session-health did not classify malformed tail as torn-tail'
  $fixtureChecks++

  $failureInput = Join-Path $tempRoot 'failure.txt'
  $failureText = [string]::Join("`n", @('tool call failed: sandbox permission denied', 'tool call failed: sandbox permission denied')) + "`n"
  [IO.File]::WriteAllText($failureInput, $failureText, [Text.UTF8Encoding]::new($false))
  $failLog = Invoke-PowerShellJson -ScriptPath $suite -Arguments @{ Action = 'fail-log'; InputPath = $failureInput; StateRoot = $fixtureState; Label = 'fixture' }
  Assert-Standalone ($failLog.exitCode -eq 0 -and $failLog.value.result -eq 'PASS') 'fail-log did not return PASS'
  Assert-Standalone ($failLog.value.rawInputStored -eq $false) 'fail-log claims raw input was stored'
  Assert-Standalone (Test-Path -LiteralPath (Join-Path $fixtureState 'failures.json') -PathType Leaf) 'fail-log did not create aggregate state'
  $fixtureChecks++

  $provenance = Invoke-PowerShellJson -ScriptPath $suite -Arguments @{ Action = 'provenance' }
  Assert-Standalone ($provenance.exitCode -eq 0 -and $provenance.value.result -eq 'PASS') 'provenance contract did not return PASS'
  Assert-Standalone ($provenance.value.globalName -eq '__DSH_PLUGIN_DEBUG__' -and $provenance.value.legacyGlobalName -eq '__DSH_PLUGIN_PROVENANCE__') 'debug/provenance bridge global names are not stable'
  Assert-Standalone ($provenance.value.bridgeSelector -eq 'meta[data-dsh-debug-bridge="1"]' -and $provenance.value.legacyBridgeSelector -eq 'meta[data-dsh-provenance-bridge="1"]') 'debug/provenance bridge selectors are not stable'
  Assert-Standalone (@($provenance.value.requiredMethods).Count -ge 8) 'provenance contract is missing browser bridge methods'
  Assert-Standalone ($provenance.value.privacy.sendsNetworkPayload -eq $false) 'provenance bridge claims network payload capture'
  Assert-Standalone ($provenance.value.bundleManifestValid -eq $true) 'provenance contract did not validate the embedded bundle manifest'
  $fixtureChecks++

  $provenanceDsh = Join-Path $tempRoot 'provenance-dsh-home'
  $provenanceProfileRoot = Join-Path $provenanceDsh 'profiles\debug'
  $provenanceInstalledRoot = Join-Path $provenanceProfileRoot 'node_modules\dsh-plugin-debug'
  New-Item -ItemType Directory -Path (Join-Path $provenanceInstalledRoot 'lib') -Force | Out-Null
  [ordered]@{
    name = 'fixture-provenance-profile'
    version = '0.0.0'
    dependencies = [ordered]@{ 'dsh-plugin-debug' = 'link:C:/fixture/dsh-plugin-debug' }
    dsh = [ordered]@{ profile = [ordered]@{ bundles = @('dsh-plugin-debug') } }
  } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $provenanceProfileRoot 'package.json') -Encoding UTF8
  Copy-Item -LiteralPath (Join-Path $packageRoot 'package.json') -Destination (Join-Path $provenanceInstalledRoot 'package.json') -Force
  Copy-Item -LiteralPath (Join-Path $packageRoot 'bundle-manifest.json') -Destination (Join-Path $provenanceInstalledRoot 'bundle-manifest.json') -Force
  Copy-Item -LiteralPath (Join-Path $packageRoot 'cordis.patch.yml') -Destination (Join-Path $provenanceInstalledRoot 'cordis.patch.yml') -Force
  Copy-Item -LiteralPath (Join-Path $packageRoot 'lib\index.js') -Destination (Join-Path $provenanceInstalledRoot 'lib\index.js') -Force
  Copy-Item -LiteralPath (Join-Path $packageRoot 'lib\client.js') -Destination (Join-Path $provenanceInstalledRoot 'lib\client.js') -Force
  $installedProvenance = Invoke-PowerShellJson -ScriptPath $suite -Arguments @{ Action = 'provenance'; Profile = 'debug'; DshHome = $provenanceDsh }
  Assert-Standalone ($installedProvenance.exitCode -eq 0 -and $installedProvenance.value.profileIntegration.status -eq 'installed') 'provenance contract did not recognize the self-contained installed bundle'
  Assert-Standalone ($installedProvenance.value.integratedIntoCurrentProfile -eq $true) 'provenance contract did not report the independent Profile integration boundary'
  Assert-Standalone ($installedProvenance.value.profileIntegration.installedFiles.bundleManifest -eq $true) 'provenance fixture did not include the embedded bundle manifest'
  $fixtureChecks++

  $installRoot = Join-Path $tempRoot 'install-fixture'
  $installTools = Join-Path $installRoot 'tools'
  $installRuntimeEntry = Join-Path $installTools 'runtime\node_modules\@deepseek-ai\dsh\lib\bin.js'
  $installDsh = Join-Path $tempRoot 'install-fixture-dsh-home'
  New-Item -ItemType Directory -Path (Split-Path -Parent $installRuntimeEntry),$installTools -Force | Out-Null
  Copy-Item -LiteralPath (Join-Path $toolRoot 'Start-DSH.ps1') -Destination (Join-Path $installTools 'Start-DSH.ps1') -Force
  Copy-Item -LiteralPath (Join-Path $toolRoot 'DSH-State.psm1') -Destination (Join-Path $installTools 'DSH-State.psm1') -Force
  Copy-Item -LiteralPath (Join-Path $packageRoot 'package.json') -Destination (Join-Path $installRoot 'package.json') -Force
  Copy-Item -LiteralPath (Join-Path $packageRoot 'cordis.patch.yml') -Destination (Join-Path $installRoot 'cordis.patch.yml') -Force
  Copy-Item -LiteralPath (Join-Path $packageRoot 'lib') -Destination (Join-Path $installRoot 'lib') -Recurse -Force
  $fakeDshCli = @'
const fs = require('node:fs');
const path = require('node:path');
const args = process.argv.slice(2);
if (!args.includes('plugin') || !args.includes('add')) process.exit(9);
const profile = args[args.indexOf('--profile') + 1];
const source = args[args.indexOf('add') + 1];
const home = process.env.DSH_HOME;
const profileRoot = path.join(home, 'profiles', profile);
const installedRoot = path.join(profileRoot, 'node_modules', 'dsh-plugin-debug');
fs.mkdirSync(installedRoot, { recursive: true });
fs.writeFileSync(path.join(profileRoot, 'package.json'), JSON.stringify({
  name: 'fixture-profile',
  version: '0.0.0',
  dependencies: { 'dsh-plugin-debug': `link:${source}` },
  dsh: { profile: { bundles: ['dsh-plugin-debug'] } },
}, null, 2));
fs.cpSync(source, installedRoot, { recursive: true });
'@
  [IO.File]::WriteAllText($installRuntimeEntry, $fakeDshCli, [Text.UTF8Encoding]::new($false))
  $previousInstallDshHome = $env:DSH_HOME
  try {
    $env:DSH_HOME = $installDsh
    $installResult = Invoke-PowerShellJson -ScriptPath (Join-Path $installTools 'Start-DSH.ps1') -Arguments @{
      Profile = 'debug'
      StateRoot = (Join-Path $tempRoot 'install-fixture-state')
      InstallOnly = $true
      NoInstall = $true
    }
  } finally {
    if ($null -eq $previousInstallDshHome) { Remove-Item Env:DSH_HOME -ErrorAction SilentlyContinue } else { $env:DSH_HOME = $previousInstallDshHome }
  }
  $installManifestPath = Join-Path $installDsh 'profiles\debug\package.json'
  $installManifest = if (Test-Path -LiteralPath $installManifestPath -PathType Leaf) { Get-Content -LiteralPath $installManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json } else { $null }
  Assert-Standalone ($installResult.exitCode -eq 0) "standalone launcher auto-install fixture failed: $($installResult.text)"
  Assert-Standalone ($null -ne $installManifest -and @($installManifest.dsh.profile.bundles) -contains 'dsh-plugin-debug') 'standalone launcher did not install its own bundle into an empty Profile'
  $fixtureChecks++

  $previousUpdateDshHome = $env:DSH_HOME
  try {
    $env:DSH_HOME = $installDsh
    $updateResult = Invoke-PowerShellJson -ScriptPath (Join-Path $installTools 'Start-DSH.ps1') -Arguments @{
      Profile = 'debug'
      StateRoot = (Join-Path $tempRoot 'install-fixture-state')
      InstallOnly = $true
      ForcePluginInstall = $true
      NoInstall = $true
    }
  } finally {
    if ($null -eq $previousUpdateDshHome) { Remove-Item Env:DSH_HOME -ErrorAction SilentlyContinue } else { $env:DSH_HOME = $previousUpdateDshHome }
  }
  Assert-Standalone ($updateResult.exitCode -eq 0) "standalone launcher forced bundle update failed: $($updateResult.text)"
  $fixtureChecks++

  $launcherConflict = Invoke-PowerShellJson -ScriptPath (Join-Path $toolRoot 'Test-DSHLauncherConflict.ps1') -Arguments @{}
  Assert-Standalone ($launcherConflict.exitCode -eq 0 -and $launcherConflict.value.result -eq 'PASS' -and $launcherConflict.value.timedOut -eq $false) "launcher conflict fixture did not isolate an existing DSH without blocking: $($launcherConflict.text)"
  $fixtureChecks++

  $diagnosticsEntry = Invoke-PowerShellJson -ScriptPath (Join-Path $packageRoot 'DSH-Provenance.ps1') -Arguments @{
    Action = 'diagnostics'
    Profile = 'test'
    Port = 1
    DshHome = $fixtureDsh
    RuntimeRoot = (Join-Path $tempRoot 'runtime-root')
    StateRoot = $fixtureState
  }
  Assert-Standalone ($diagnosticsEntry.exitCode -eq 0 -and $diagnosticsEntry.value.schemaVersion -eq 2) 'diagnostics wrapper failed on a pure PowerShell child script'
  Assert-Standalone ($diagnosticsEntry.value.profile -eq 'test') 'diagnostics wrapper ignored the explicit DshHome/Profile'
  Assert-Standalone (@($diagnosticsEntry.value.runtimeRootsChecked | Where-Object { $_ -eq [IO.Path]::GetFullPath((Join-Path $tempRoot 'runtime-root')) }).Count -eq 1) 'diagnostics wrapper did not propagate RuntimeRoot'
  $fixtureChecks++

  $recoveryScript = Join-Path $toolRoot 'DSH-Recovery.ps1'
  $profileSnapshotRoot = Join-Path $tempRoot 'profile-snapshots'
  $profilePackagePath = Join-Path $fixtureProfileRoot 'package.json'
  $profilePackageBefore = Get-Content -LiteralPath $profilePackagePath -Raw -Encoding UTF8
  $profileSnapshot = Invoke-PowerShellJson -ScriptPath $recoveryScript -Arguments @{
    Action = 'snapshot-profile'
    Profile = 'test'
    DshHome = $fixtureDsh
    SnapshotRoot = $profileSnapshotRoot
    Label = 'standalone-profile-fixture'
  }
  Assert-Standalone ($profileSnapshot.exitCode -eq 0 -and $profileSnapshot.value.result -eq 'PASS') 'profile snapshot did not return PASS'
  $profileSnapshotId = [string]$profileSnapshot.value.value.id
  Assert-Standalone (-not [string]::IsNullOrWhiteSpace($profileSnapshotId)) 'profile snapshot did not return an id'
  [IO.File]::WriteAllText($profilePackagePath, '{"name":"mutated-profile"}', [Text.UTF8Encoding]::new($false))
  $profileRestore = Invoke-PowerShellJson -ScriptPath $recoveryScript -Arguments @{
    Action = 'restore-profile'
    Profile = 'test'
    DshHome = $fixtureDsh
    SnapshotRoot = $profileSnapshotRoot
    SnapshotId = $profileSnapshotId
    Force = $true
  }
  Assert-Standalone ($profileRestore.exitCode -eq 0 -and $profileRestore.value.result -eq 'PASS') 'profile restore did not return PASS'
  Assert-Standalone ((Get-Content -LiteralPath $profilePackagePath -Raw -Encoding UTF8) -eq $profilePackageBefore) 'profile restore did not restore the package manifest'
  Assert-Standalone (-not [string]::IsNullOrWhiteSpace([string]$profileRestore.value.value.rescueSnapshot)) 'profile restore did not create a rescue snapshot'
  $fixtureChecks++

  $workspaceSnapshotRoot = Join-Path $tempRoot 'workspace-snapshots'
  $workspaceFilePath = Join-Path $fixtureRoot 'mutable.txt'
  [IO.File]::WriteAllText($workspaceFilePath, 'before-mutation`n', [Text.UTF8Encoding]::new($false))
  $workspaceSnapshot = Invoke-PowerShellJson -ScriptPath $recoveryScript -Arguments @{
    Action = 'snapshot-workspace'
    Workspace = $fixtureRoot
    DshHome = $fixtureDsh
    SnapshotRoot = $workspaceSnapshotRoot
    Label = 'standalone-workspace-fixture'
  }
  Assert-Standalone ($workspaceSnapshot.exitCode -eq 0 -and $workspaceSnapshot.value.result -eq 'PASS') 'workspace snapshot did not return PASS'
  $workspaceSnapshotId = [string]$workspaceSnapshot.value.value.id
  Assert-Standalone (-not [string]::IsNullOrWhiteSpace($workspaceSnapshotId)) 'workspace snapshot did not return an id'
  [IO.File]::WriteAllText($workspaceFilePath, 'after-mutation`n', [Text.UTF8Encoding]::new($false))
  $newWorkspaceFilePath = Join-Path $fixtureRoot 'created-after-snapshot.txt'
  [IO.File]::WriteAllText($newWorkspaceFilePath, 'keep this file`n', [Text.UTF8Encoding]::new($false))
  $workspaceRestore = Invoke-PowerShellJson -ScriptPath $recoveryScript -Arguments @{
    Action = 'restore-workspace'
    Workspace = $fixtureRoot
    DshHome = $fixtureDsh
    SnapshotRoot = $workspaceSnapshotRoot
    SnapshotId = $workspaceSnapshotId
    Force = $true
  }
  Assert-Standalone ($workspaceRestore.exitCode -eq 0 -and $workspaceRestore.value.result -eq 'PASS') 'workspace restore did not return PASS'
  Assert-Standalone ((Get-Content -LiteralPath $workspaceFilePath -Raw -Encoding UTF8) -eq 'before-mutation`n') 'workspace restore did not restore the captured file'
  Assert-Standalone (Test-Path -LiteralPath $newWorkspaceFilePath -PathType Leaf) 'workspace restore deleted a file created after the snapshot'
  Assert-Standalone (-not [string]::IsNullOrWhiteSpace([string]$workspaceRestore.value.value.rescueSnapshot)) 'workspace restore did not create a rescue snapshot'
  $fixtureChecks++

  $traceScript = Join-Path $toolRoot 'DSH-TraceEval.ps1'
  $traceInputPath = Join-Path $toolRoot 'fixtures\tool-call-trace.json'
  $traceCasePath = Join-Path $toolRoot 'fixtures\tool-call-case.json'
  $traceContract = Invoke-PowerShellJson -ScriptPath $traceScript -Arguments @{
    Action = 'contract'
    InputPath = $traceInputPath
  }
  Assert-Standalone ($traceContract.exitCode -eq 0 -and $traceContract.value.result -eq 'PASS') 'trace contract fixture did not return PASS'
  Assert-Standalone ($traceContract.value.value.contract.valid -eq $true) 'trace contract fixture was not valid'
  Assert-Standalone ($traceContract.text -notmatch 'secret-value|secret command output') 'trace contract emitted raw fixture secrets'
  $traceEval = Invoke-PowerShellJson -ScriptPath (Join-Path $packageRoot 'DSH-Provenance.ps1') -Arguments @{
    Action = 'trace-eval'
    InputPath = $traceInputPath
    CasePath = $traceCasePath
  }
  Assert-Standalone ($traceEval.exitCode -eq 0 -and $traceEval.value.result -eq 'PASS') 'unified trace-eval entry did not return PASS'
  Assert-Standalone ($traceEval.value.value.failedCount -eq 0) 'trace-eval reported failed assertions'
  Assert-Standalone ($traceEval.text -notmatch 'secret-value|secret command output') 'trace-eval emitted raw fixture secrets'
  $fixtureChecks++

  $traceProfile = Invoke-PowerShellJson -ScriptPath (Join-Path $toolRoot 'Test-DSHTraceProfile.ps1') -Arguments @{}
  Assert-Standalone ($traceProfile.exitCode -eq 0 -and $traceProfile.value.result -eq 'PASS') 'trace profile fixture did not return PASS'
  Assert-Standalone ($traceProfile.value.metrics.rawPayloadLeak -eq $false -and $traceProfile.value.metrics.absoluteTimestampLeak -eq $false) 'trace profile fixture did not preserve metadata-only privacy'
  $fixtureChecks++

  $traceBaseline = Invoke-PowerShellJson -ScriptPath (Join-Path $packageRoot 'DSH-Provenance.ps1') -Arguments @{
    Action = 'trace-baseline'
    InputPath = $traceInputPath
    BaselinePath = (Join-Path $toolRoot 'fixtures\tool-call-baseline.json')
  }
  Assert-Standalone ($traceBaseline.exitCode -ne 0 -and $traceBaseline.value.result -eq 'FAIL') 'trace baseline did not fail on increased Tool Call errors'
  Assert-Standalone (@($traceBaseline.value.value.errors | Where-Object { $_ -match 'errorResultCount' }).Count -eq 1) 'trace baseline did not report the error-result regression'
  Assert-Standalone ($traceBaseline.text -notmatch 'secret-value|secret command output') 'trace baseline emitted raw fixture secrets'
  $fixtureChecks++

  $incompleteTracePath = Join-Path $toolRoot 'fixtures\tool-call-incomplete-page.json'
  $incompleteCasePath = Join-Path $toolRoot 'fixtures\tool-call-incomplete-page-case.json'
  $incompleteContract = Invoke-PowerShellJson -ScriptPath $traceScript -Arguments @{
    Action = 'contract'
    InputPath = $incompleteTracePath
  }
  Assert-Standalone ($incompleteContract.exitCode -eq 0 -and $incompleteContract.value.value.contract.valid -eq $true) 'incomplete-page trace contract did not pass'
  Assert-Standalone ($incompleteContract.value.value.trace.hasMore -eq $true) 'incomplete-page trace lost hasMore=true'
  Assert-Standalone ($incompleteContract.value.value.trace.toolCallStats.callCount -eq 1 -and $incompleteContract.value.value.trace.toolCallStats.pendingCount -eq 1) 'incomplete-page trace did not preserve the pending Tool Call'
  Assert-Standalone ($incompleteContract.value.value.trace.toolCallStats.dispatchErrorCount -eq 1 -and $incompleteContract.value.value.trace.toolCallStats.turnErrorCount -eq 1) 'incomplete-page trace did not distinguish dispatch and turn errors'
  $incompleteEval = Invoke-PowerShellJson -ScriptPath (Join-Path $packageRoot 'DSH-Provenance.ps1') -Arguments @{
    Action = 'trace-eval'
    InputPath = $incompleteTracePath
    CasePath = $incompleteCasePath
  }
  Assert-Standalone ($incompleteEval.exitCode -eq 0 -and $incompleteEval.value.value.failedCount -eq 0) 'incomplete-page trace assertions failed'
  $fixtureChecks++

  $traceAutopsyFixture = Invoke-PowerShellJson -ScriptPath (Join-Path $packageRoot 'DSH-Provenance.ps1') -Arguments @{ Action = 'trace-autopsy-fixture' }
  Assert-Standalone ($traceAutopsyFixture.exitCode -eq 0 -and $traceAutopsyFixture.value.result -eq 'PASS') 'TraceAutopsy fixture did not return PASS'
  Assert-Standalone ($traceAutopsyFixture.value.tests.rawPayloadLeak -eq $false -and $traceAutopsyFixture.value.tests.faultFindingCount -ge 9) 'TraceAutopsy fixture did not preserve metadata-only evidence'
  $fixtureChecks++

  $knownGoodFixture = Invoke-StandaloneFixtureWithStartupRetry -ScriptPath (Join-Path $packageRoot 'DSH-Provenance.ps1') -Arguments @{ Action = 'known-good-fixture' }
  Assert-Standalone ($knownGoodFixture.exitCode -eq 0 -and $knownGoodFixture.value.result -eq 'PASS') "known-good fixture did not return PASS: $($knownGoodFixture.text)"
  Assert-Standalone ($knownGoodFixture.value.automaticRestoreBounded -eq $true -and $knownGoodFixture.value.failedPluginPreserved -eq $true -and $knownGoodFixture.value.workspaceUntouched -eq $true) "known-good fixture did not prove bounded recovery and workspace safety: $($knownGoodFixture.text)"
  $fixtureChecks++

  $liveApiFixture = Invoke-StandaloneFixtureWithStartupRetry -ScriptPath (Join-Path $packageRoot 'DSH-Provenance.ps1') -Arguments @{ Action = 'live-api-fixture' } -TimeoutSec 90
  Assert-Standalone ($liveApiFixture.exitCode -eq 0 -and $liveApiFixture.value.result -eq 'PASS') "live API fixture did not return PASS: exit=$($liveApiFixture.exitCode); text=$($liveApiFixture.text)"
  Assert-Standalone ($liveApiFixture.value.usedRealDshPort -eq $false -and $liveApiFixture.value.usedRealDshHome -eq $false) 'live API fixture crossed the real DSH boundary'
  $fixtureChecks++

  $crashFixture = Invoke-PowerShellJson -ScriptPath (Join-Path $packageRoot 'DSH-Provenance.ps1') -Arguments @{
    Action = 'crash-fixture'
    FixtureTimeoutSec = 40
  }
  Assert-Standalone ($crashFixture.exitCode -eq 0 -and $crashFixture.value.result -eq 'PASS') 'crash guard startup fixture did not return PASS'
  Assert-Standalone ($crashFixture.value.bootCount -ge 2 -and $crashFixture.value.quarantinedPlugin -eq 'test-dsh-plugin') 'crash guard fixture did not restart after quarantining the safe plugin'
  Assert-Standalone ($crashFixture.value.reversiblePatchPresent -eq $true -and $crashFixture.value.startupReadyObserved -eq $true) 'crash guard fixture did not prove patch and Web readiness'
  $fixtureChecks++

  $runtimeSupervisorFixture = Invoke-PowerShellJson -ScriptPath (Join-Path $packageRoot 'DSH-Provenance.ps1') -Arguments @{
    Action = 'runtime-supervisor-fixture'
    FixtureTimeoutSec = 40
  }
  Assert-Standalone ($runtimeSupervisorFixture.exitCode -eq 0 -and $runtimeSupervisorFixture.value.result -eq 'PASS') 'runtime supervisor fixture did not return PASS'
  Assert-Standalone ($runtimeSupervisorFixture.value.portReleaseWaitObserved -eq $true) 'runtime supervisor did not exercise the guarded port-release wait'
  Assert-Standalone ($runtimeSupervisorFixture.value.bootCount -eq 2 -and $runtimeSupervisorFixture.value.quarantinedPlugin -eq 'test-dsh-plugin') 'runtime supervisor did not perform exactly one plugin quarantine restart'
  Assert-Standalone ($runtimeSupervisorFixture.value.reversiblePatchPresent -eq $true -and $runtimeSupervisorFixture.value.webReadyAfterRestart -eq $true) 'runtime supervisor fixture did not prove reversible patch and second Web readiness'
  Assert-Standalone ($runtimeSupervisorFixture.value.supervisorStatus -eq 'healthy' -and $runtimeSupervisorFixture.value.supervisorRestartCount -eq 1) 'runtime supervisor did not finish in healthy state after one restart'
  $fixtureChecks++

  $unresolvedSupervisorFixture = Invoke-PowerShellJson -ScriptPath (Join-Path $toolRoot 'Test-DSHRuntimeSupervisor.ps1') -Arguments @{
    TimeoutSec = 40
    UnresolvedPluginFailure = $true
  }
  Assert-Standalone ($unresolvedSupervisorFixture.exitCode -eq 0 -and $unresolvedSupervisorFixture.value.result -eq 'PASS') 'unresolved plugin supervisor fixture did not return PASS'
  Assert-Standalone ($unresolvedSupervisorFixture.value.scenario -eq 'unresolved-plugin-fail-closed' -and $unresolvedSupervisorFixture.value.startupBlocked -eq $true) 'unresolved plugin failure was not fail-closed'
  Assert-Standalone ($unresolvedSupervisorFixture.value.bootCount -eq 1 -and $unresolvedSupervisorFixture.value.quarantineCount -eq 0) 'unresolved plugin failure caused a quarantine or a second restart'
  Assert-Standalone ($unresolvedSupervisorFixture.value.startupIncidentStatus -eq 'degraded') 'unresolved plugin failure did not preserve a degraded startup incident receipt'
  Assert-Standalone ($unresolvedSupervisorFixture.value.supervisorStatus -eq 'degraded' -and $unresolvedSupervisorFixture.value.supervisorReason -eq 'runtime-plugin-failed-unresolved') 'unresolved plugin failure did not produce the expected degraded supervisor receipt'
  $fixtureChecks++

  $guardianStatusFixture = Invoke-PowerShellJson -ScriptPath (Join-Path $packageRoot 'DSH-Provenance.ps1') -Arguments @{ Action = 'guardian-status-fixture' }
  Assert-Standalone ($guardianStatusFixture.exitCode -eq 0 -and $guardianStatusFixture.value.result -eq 'PASS') 'Guardian status fixture did not return PASS'
  Assert-Standalone ($guardianStatusFixture.value.readOnly -eq $true -and $guardianStatusFixture.value.noTermination -eq $true) 'Guardian status fixture did not prove read-only behavior'
  $fixtureChecks++

  $guardianIdlePath = Join-Path $tempRoot 'guardian-idle.json'
  $guardianBusyPath = Join-Path $tempRoot 'guardian-busy.json'
  [ordered]@{
    ok = $true
    kind = 'dsh-plugin-debug-guardian-status'
    safeToRestart = $true
    activeSessions = 0
    inFlightOperations = 0
  } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $guardianIdlePath -Encoding UTF8
  [ordered]@{
    ok = $true
    kind = 'dsh-plugin-debug-guardian-status'
    safeToRestart = $false
    activeSessions = 1
    inFlightOperations = 2
  } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $guardianBusyPath -Encoding UTF8
  $guardianIdleEntry = Invoke-PowerShellJson -ScriptPath (Join-Path $packageRoot 'Debug-DSH.ps1') -Arguments @{
    Action = 'guardian-status'
    InputPath = $guardianIdlePath
  }
  $guardianBusyEntry = Invoke-PowerShellJson -ScriptPath (Join-Path $packageRoot 'Debug-DSH.ps1') -Arguments @{
    Action = 'guardian-status'
    InputPath = $guardianBusyPath
  }
  Assert-Standalone ($guardianIdleEntry.exitCode -eq 0 -and $guardianIdleEntry.value.result -eq 'SAFE_TO_RESTART') 'public Guardian status entry did not accept an idle state'
  Assert-Standalone ($guardianBusyEntry.exitCode -eq 2 -and $guardianBusyEntry.value.result -eq 'BUSY_DO_NOT_RESTART') 'public Guardian status entry did not fail closed for a busy state'
  Assert-Standalone ($guardianBusyEntry.value.restartsHost -ne $true -and $guardianBusyEntry.value.terminatesTasks -eq $false) 'public Guardian status entry exposed a mutating action'
  $fixtureChecks++

  $pointerEvidencePath = Join-Path $tempRoot 'pointer-evidence.json'
  [ordered]@{
    schemaVersion = 1
    enabled = $true
    pointerEvent = 'dsh-plugin-debug:pointer'
    pageObservationId = 'page-fixture'
    current = [ordered]@{
      plugin = 'fixture-plugin'
      module = 'fixture-module'
      slot = 'shell.overlay'
      evidence = 'data-dsh-plugin'
      confidence = 'high'
      node = 'button fixture'
      className = 'fixture-class'
      observationId = 'pointer-fixture'
      pageObservationId = 'page-fixture'
      observedAt = '2026-08-15T00:00:00.000Z'
      sources = @([ordered]@{ plugin = 'fixture-plugin'; module = 'fixture-module' })
    }
  } | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $pointerEvidencePath -Encoding UTF8

  $pointerEvidence = Invoke-PowerShellJson -ScriptPath (Join-Path $packageRoot 'DSH-Provenance.ps1') -Arguments @{
    Action = 'pointer-evidence'
    InputPath = $pointerEvidencePath
  }
  Assert-Standalone ($pointerEvidence.exitCode -eq 0 -and $pointerEvidence.value.result -eq 'PASS' -and $pointerEvidence.value.observation.plugin -eq 'fixture-plugin') 'pointer-evidence action did not import the sanitized pointer observation'
  Assert-Standalone ($pointerEvidence.value.causalAttribution -eq 'not-supported' -and $pointerEvidence.value.privacy.rawInputStored -eq $false) 'pointer-evidence action weakened the attribution or privacy boundary'
  $fixtureChecks++

  $incidentCorrelationFixture = Invoke-PowerShellJson -ScriptPath (Join-Path $toolRoot 'Test-DSHIncidentCorrelation.ps1') -Arguments @{}
  Assert-Standalone ($incidentCorrelationFixture.exitCode -eq 0 -and $incidentCorrelationFixture.value.result -eq 'PASS') "incident correlation fixture did not return PASS: $($incidentCorrelationFixture.text)"
  Assert-Standalone ($incidentCorrelationFixture.value.kind -eq 'dsh-incident-correlation-test' -and $incidentCorrelationFixture.value.offline -eq $true -and $incidentCorrelationFixture.value.networkAccessed -eq $false -and $incidentCorrelationFixture.value.externalRuntimeRead -eq $false) 'incident correlation fixture crossed its offline/runtime boundary'
  Assert-Standalone ($incidentCorrelationFixture.value.tests.fullChain -eq 'CORRELATED' -and $incidentCorrelationFixture.value.tests.outputContract -eq $true -and [int]$incidentCorrelationFixture.value.tests.evidenceCount -eq 9 -and [string]$incidentCorrelationFixture.value.tests.stableIncidentId -match '^dsh-inc-[0-9a-f]{32}$') 'incident correlation fixture did not prove the complete output contract'
  Assert-Standalone ($incidentCorrelationFixture.value.tests.missingEvidence -eq 'INCONCLUSIVE' -and $incidentCorrelationFixture.value.tests.conflictingEvidence -eq 'MANUAL_REVIEW' -and $incidentCorrelationFixture.value.tests.sensitiveEvidence -eq 'MANUAL_REVIEW' -and $incidentCorrelationFixture.value.tests.emptyInput -eq 'INCONCLUSIVE') 'incident correlation fixture did not retain its negative-path behavior assertions'
  $fixtureChecks++

  $incidentPath = Join-Path $tempRoot 'incident-report.json'
  $incident = Invoke-PowerShellJson -ScriptPath (Join-Path $packageRoot 'DSH-Provenance.ps1') -Arguments @{
    Action = 'incident-capture'
    Profile = 'test'
    DshHome = $fixtureDsh
    Workspace = $fixtureRoot
    StateRoot = $fixtureState
    Port = 1
    ExpectedModel = 'gpt-5.6-sol'
    PointerPath = $pointerEvidencePath
    IncidentPath = $incidentPath
  }
  Assert-Standalone ($incident.exitCode -eq 0 -and $incident.value.result -eq 'FAIL') 'incident-capture did not surface the fixture plugin-health failure'
  Assert-Standalone (Test-Path -LiteralPath $incidentPath -PathType Leaf) 'incident-capture did not write the requested report'
  Assert-Standalone ($incident.value.privacy.rawToolArgumentsStored -eq $false -and $incident.value.privacy.networkPayloadSent -eq $false) 'incident-capture privacy boundary is not metadata-only'
  Assert-Standalone ($incident.value.readOnly -eq $false -and $incident.value.collection.readOnlyCollection -eq $true -and $incident.value.collection.writesLocalReport -eq $true) 'incident-capture did not distinguish read-only collection from local report output'
  $incidentStatusMap = if ($null -ne $incident.value.components) {
    ($incident.value.components.PSObject.Properties | ForEach-Object { "$($_.Name)=$($_.Value.status)" }) -join ', '
  } else { 'components=missing' }
  Assert-Standalone ($incident.value.componentStatusCounts.failed -eq 1 -and $incident.value.componentStatusCounts.unavailable -eq 0) "incident-capture did not count the known fixture plugin-health failure accurately (failed=$($incident.value.componentStatusCounts.failed); unavailable=$($incident.value.componentStatusCounts.unavailable); statuses=$incidentStatusMap)"
  Assert-Standalone ($incident.value.components.diagnostics.status -eq 'PARTIAL') "incident-capture did not classify unavailable loopback diagnostics as PARTIAL (statuses=$incidentStatusMap)"
  Assert-Standalone ($incident.value.components.provenance.clientArtifactExists -eq $true -and $incident.value.components.context.totalFiles -ge 2) 'incident-capture did not combine provenance and workspace evidence'
  Assert-Standalone ($null -ne $incident.value.components.provenance.profileIntegration) 'incident-capture did not carry the independent provenance integration status'
  Assert-Standalone ($incident.value.components.diagnostics.failedPluginCount -eq 0) 'incident-capture counted a missing failed-plugin array as one item'
  Assert-Standalone ($incident.value.components.pointer.status -eq 'PASS' -and $incident.value.components.pointer.observation.plugin -eq 'fixture-plugin' -and $incident.value.pointerEvidenceProvided -eq $true) 'incident-capture did not absorb pointer provenance evidence'
  Assert-Standalone (@($incident.value.componentHashes.PSObject.Properties).Count -ge 5) 'incident-capture did not write component integrity hashes'
  $fixtureChecks++

  $resourcePressureFixture = Invoke-PowerShellJson -ScriptPath (Join-Path $toolRoot 'Test-DSHResourcePressure.ps1') -Arguments @{}
  Assert-Standalone ($resourcePressureFixture.exitCode -eq 0 -and $resourcePressureFixture.value.result -eq 'PASS') "resource pressure fixture did not return PASS: $($resourcePressureFixture.text)"
  Assert-Standalone ($resourcePressureFixture.value.diagnosticsIntegration -eq $true -and $resourcePressureFixture.value.privacyContract -eq $true) 'resource pressure fixture did not prove diagnostics integration and privacy'
  $fixtureChecks++

  $incidentEvidenceFixture = Invoke-PowerShellJson -ScriptPath (Join-Path $toolRoot 'Test-DSHIncidentRuntimeEvidence.ps1') -Arguments @{}
  Assert-Standalone ($incidentEvidenceFixture.exitCode -eq 0 -and $incidentEvidenceFixture.value.result -eq 'PASS') "incident runtime evidence fixture did not return PASS: $($incidentEvidenceFixture.text)"
  Assert-Standalone ($incidentEvidenceFixture.value.privacyContract -eq $true -and $incidentEvidenceFixture.value.runtimeEvidenceStatus -in @('usable', 'degraded', 'unavailable')) 'incident runtime evidence fixture did not preserve its boundary'
  $fixtureChecks++

  $reproFixture = Invoke-PowerShellJson -ScriptPath (Join-Path $toolRoot 'Test-DSHRepro.ps1') -Arguments @{}
  Assert-Standalone ($reproFixture.exitCode -eq 0 -and $reproFixture.value.result -eq 'PASS' -and $reproFixture.value.offline -eq $true -and $reproFixture.value.networkAccessed -eq $false) "repro export fixture did not return PASS: $($reproFixture.text)"
  $fixtureChecks++

  $bisectInputPath = Join-Path $toolRoot 'fixtures\plugin-bisect-plan.json'
  $bisectFixture = Invoke-PowerShellJson -ScriptPath (Join-Path $packageRoot 'DSH-Provenance.ps1') -Arguments @{
    Action = 'plugin-bisect-plan'
    InputPath = $bisectInputPath
  }
  Assert-Standalone ($bisectFixture.exitCode -eq 0 -and $bisectFixture.value.result -eq 'PASS') "plugin-bisect-plan did not return PASS: $($bisectFixture.text)"
  Assert-Standalone ($bisectFixture.value.offline -eq $true -and $bisectFixture.value.networkAccessed -eq $false -and $bisectFixture.value.safety.autoDisabled -eq $false) 'plugin-bisect-plan crossed the offline or no-auto-disable boundary'
  Assert-Standalone (@($bisectFixture.value.candidates | Where-Object { $_.classification -eq 'safe' -and $_.pluginId -eq 'fixture-dsh-plugin' }).Count -eq 1) 'plugin-bisect-plan did not retain the safe mapped candidate'
  Assert-Standalone (@($bisectFixture.value.candidates | Where-Object { $_.classification -eq 'protected' -and $_.reason -eq 'core-package' }).Count -eq 1) 'plugin-bisect-plan did not protect the DSH core candidate'
  $fixtureChecks++

  $bisectPublicWrapper = Invoke-PowerShellJson -ScriptPath (Join-Path $packageRoot 'Debug-DSH.ps1') -Arguments @{
    Action = 'plugin-bisect-plan'
    InputPath = $bisectInputPath
  }
  Assert-Standalone ($bisectPublicWrapper.exitCode -eq 0 -and $bisectPublicWrapper.value.result -eq 'PASS') "Debug-DSH wrapper did not preserve named argument binding: $($bisectPublicWrapper.text)"
  $fixtureChecks++

  $bisectTest = Invoke-PowerShellJson -ScriptPath (Join-Path $toolRoot 'Test-DSHBisect.ps1') -Arguments @{}
  Assert-Standalone ($bisectTest.exitCode -eq 0 -and $bisectTest.value.result -eq 'PASS' -and $bisectTest.value.privacyContract -eq $true -and $bisectTest.value.mutationContract -eq $true) "plugin-bisect test did not return PASS: $($bisectTest.text)"
  $fixtureChecks++

  $preflightTest = Invoke-PowerShellJson -ScriptPath (Join-Path $toolRoot 'Test-DSHPreflight.ps1') -Arguments @{}
  Assert-Standalone ($preflightTest.exitCode -eq 0 -and $preflightTest.value.result -eq 'PASS') "plugin preflight test did not return PASS: $($preflightTest.text)"
  Assert-Standalone ($preflightTest.value.metadataOnly -eq $true -and $preflightTest.value.networkAccessed -eq $false -and $preflightTest.value.dynamicResult -eq 'MANUAL_REVIEW') 'plugin preflight test crossed its safety or dynamic-input boundary'
  $fixtureChecks++

  $traceLoopTest = Invoke-PowerShellJson -ScriptPath (Join-Path $toolRoot 'Test-DSHTraceLoop.ps1') -Arguments @{}
  Assert-Standalone ($traceLoopTest.exitCode -eq 0 -and $traceLoopTest.value.result -eq 'PASS') "trace loop test did not return PASS: $($traceLoopTest.text)"
  Assert-Standalone ($traceLoopTest.value.metadataOnly -eq $true -and $traceLoopTest.value.networkAccessed -eq $false -and $traceLoopTest.value.loopDetected -eq $true) 'trace loop test crossed its offline/privacy boundary'
  $fixtureChecks++

  $traceRecursionTest = Invoke-PowerShellJson -ScriptPath (Join-Path $packageRoot 'DSH-Provenance.ps1') -Arguments @{ Action = 'trace-recursion-fixture' }
  Assert-Standalone ($traceRecursionTest.exitCode -eq 0 -and $traceRecursionTest.value.result -eq 'PASS') "trace recursion test did not return PASS: $($traceRecursionTest.text)"
  Assert-Standalone ($traceRecursionTest.value.metadataOnly -eq $true -and $traceRecursionTest.value.networkAccessed -eq $false -and $traceRecursionTest.value.recursionDetected -eq $true) 'trace recursion test crossed its offline/privacy boundary'
  $fixtureChecks++

  $traceRecursionEntry = Invoke-PowerShellJson -ScriptPath (Join-Path $packageRoot 'Debug-DSH.ps1') -Arguments @{
    Action = 'trace-recursion'
    InputPath = (Join-Path $toolRoot 'fixtures\trace-recursion.json')
    MaxDepth = 3
  }
  Assert-Standalone ($traceRecursionEntry.exitCode -eq 0 -and $traceRecursionEntry.value.result -eq 'RECURSION_DETECTED') "trace recursion public entry did not report the fixture: $($traceRecursionEntry.text)"
  Assert-Standalone ($traceRecursionEntry.value.input.maxObservedDepth -eq 4 -and $traceRecursionEntry.value.privacy.agentIdsReturned -eq $false) 'trace recursion public entry weakened the depth or privacy contract'
  $fixtureChecks++

  $dependencyGraphTest = Invoke-PowerShellJson -ScriptPath (Join-Path $toolRoot 'Test-DSHDependencyGraph.ps1') -Arguments @{}
  Assert-Standalone ($dependencyGraphTest.exitCode -eq 0 -and $dependencyGraphTest.value.result -eq 'PASS') "dependency graph test did not return PASS: $($dependencyGraphTest.text)"
  Assert-Standalone ($dependencyGraphTest.value.metadataOnly -eq $true -and $dependencyGraphTest.value.networkAccessed -eq $false) 'dependency graph test crossed its offline/privacy boundary'
  $fixtureChecks++

  $diagnosticsDiffTest = Invoke-PowerShellJson -ScriptPath (Join-Path $toolRoot 'Test-DSHDiagnosticsDiff.ps1') -Arguments @{}
  Assert-Standalone ($diagnosticsDiffTest.exitCode -eq 0 -and $diagnosticsDiffTest.value.result -eq 'PASS') "diagnostics diff test did not return PASS: $($diagnosticsDiffTest.text)"
  Assert-Standalone ($diagnosticsDiffTest.value.metadataOnly -eq $true -and $diagnosticsDiffTest.value.networkAccessed -eq $false) 'diagnostics diff test crossed its offline/privacy boundary'
  Assert-Standalone ($diagnosticsDiffTest.value.manualReview -eq 'MANUAL_REVIEW' -and $diagnosticsDiffTest.value.invalidInput -eq 'FAIL') 'diagnostics diff negative paths were not fail-closed'
  $fixtureChecks++

  $diagnosticsPath = Join-Path $tempRoot 'repair-diagnostics.json'
  $planPath = Join-Path $tempRoot 'repair-plan.json'
  $diagnosticsFixture = [ordered]@{
    schemaVersion = 1
    pluginInventory = [ordered]@{
      failed = @([ordered]@{ moduleName = 'test-dsh-plugin'; fiberPhase = 'failed' })
    }
    toolCallObservation = [ordered]@{
      session = [ordered]@{ toolCallStats = [ordered]@{ errorResultCount = 1 } }
    }
    permission = [ordered]@{ settingsDefaultPreset = 'danger-full-access' }
  }
  $diagnosticsFixture | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $diagnosticsPath -Encoding UTF8

  $repairScript = Join-Path $toolRoot 'DSH-SelfRepair.ps1'
  $repairPlan = Invoke-PowerShellJson -ScriptPath $repairScript -Arguments @{
    Action = 'plan'
    Profile = 'test'
    DiagnosticsPath = $diagnosticsPath
    PlanPath = $planPath
    StateRoot = $fixtureState
  }
  Assert-Standalone ($repairPlan.exitCode -eq 0 -and $repairPlan.value.result -eq 'PASS') 'repair plan did not return PASS'
  Assert-Standalone (Test-Path -LiteralPath $planPath -PathType Leaf) 'repair plan was not written'
  Assert-Standalone (-not [string]::IsNullOrWhiteSpace([string]$repairPlan.value.value.plan.incidentId) -and [string]$repairPlan.value.value.plan.evidenceHash -match '^[a-f0-9]{64}$' -and [string]$repairPlan.value.value.plan.expiresAt) 'repair plan did not bind an incident, evidence hash, and expiry'
  Assert-Standalone (@($repairPlan.value.value.plan.observedCandidateIds | Where-Object { $_ -eq 'test-dsh-plugin' }).Count -eq 1) 'repair plan did not retain the observed candidate id'
  Assert-Standalone (@($repairPlan.value.value.plan.operations | Where-Object { $_.kind -eq 'quarantine-plugin' -and $_.pluginId -eq 'test-dsh-plugin' }).Count -eq 1) 'repair plan did not contain the safe failed-plugin operation'
  Assert-Standalone (-not (Test-Path -LiteralPath (Join-Path $fixtureState 'guard-state.json') -PathType Leaf)) 'repair plan changed guard state'
  $fixtureChecks++

  $repairAssist = Invoke-PowerShellJson -ScriptPath $repairScript -Arguments @{
    Action = 'assist'
    Profile = 'test'
    Port = 1
    DiagnosticsPath = $diagnosticsPath
    Cwd = $fixtureRoot
  }
  Assert-Standalone ($repairAssist.exitCode -eq 0 -and $repairAssist.value.result -eq 'WARN' -and $repairAssist.value.value.status -eq 'unavailable') 'repair assist did not fail closed when Host no-tools capability was unavailable'
  Assert-Standalone ($repairAssist.value.value.sessionCreated -eq $false -and $repairAssist.value.value.cwdForwarded -eq $false) 'repair assist created or scoped an unsafe model Session'
  $fixtureChecks++

  $profileManifestPath = Join-Path $fixtureDsh 'profiles\test\package.json'
  New-Item -ItemType Directory -Path (Split-Path -Parent $profileManifestPath) -Force | Out-Null
  $profileManifest = [ordered]@{
    name = 'fixture-profile'
    version = '0.0.0'
    dependencies = [ordered]@{ 'test-dsh-plugin' = 'file:..\..\test-dsh-plugin' }
  }
  $profileManifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $profileManifestPath -Encoding UTF8
  $manifestHashBefore = Get-StandaloneSha256 -Path $profileManifestPath

  $repairApply = Invoke-PowerShellJson -ScriptPath $repairScript -Arguments @{
    Action = 'apply'
    Profile = 'test'
    DshHome = $fixtureDsh
    StateRoot = $fixtureState
    PlanPath = $planPath
    Force = $true
  }
  $repairApplyValue = if ($null -ne $repairApply.value -and $null -ne $repairApply.value.PSObject.Properties['value']) { $repairApply.value.value } else { $null }
  $receiptPath = if ($null -ne $repairApplyValue -and $null -ne $repairApplyValue.PSObject.Properties['receipt']) { [string]$repairApplyValue.receipt } else { '' }
  Assert-Standalone ($repairApply.exitCode -eq 0 -and $repairApply.value.result -eq 'PASS') 'repair apply did not return PASS'
  Assert-Standalone ($null -ne $repairApplyValue -and $repairApplyValue.status -eq 'applied') "repair apply did not report applied: $($repairApply.text)"
  Assert-Standalone (-not [string]::IsNullOrWhiteSpace($receiptPath)) "repair apply did not return a receipt path: $($repairApply.text)"
  if ([string]::IsNullOrWhiteSpace($receiptPath)) { $receiptPath = Join-Path $tempRoot 'missing-receipt.json' }
  Assert-Standalone (Test-Path -LiteralPath (Join-Path $fixtureState 'guard-state.json') -PathType Leaf) 'repair apply did not write guard-state.json'
  Assert-Standalone (Test-Path -LiteralPath (Join-Path $fixtureState 'guard.patch.yml') -PathType Leaf) "repair apply did not write guard.patch.yml (exit=$($repairApply.exitCode); output=$($repairApply.text))"
  Assert-Standalone (Test-Path -LiteralPath $receiptPath -PathType Leaf) 'repair apply did not write a receipt'
  $guardStatePath = Join-Path $fixtureState 'guard-state.json'
  if (Test-Path -LiteralPath $guardStatePath -PathType Leaf) {
    Assert-Standalone (@(((Get-Content -LiteralPath $guardStatePath -Raw -Encoding UTF8) | ConvertFrom-Json).quarantined)[0].entryId -eq 'test-dsh-plugin') 'repair apply did not quarantine the requested plugin'
  }
  Assert-Standalone ((Get-StandaloneSha256 -Path $profileManifestPath) -eq $manifestHashBefore) 'repair apply changed the Profile manifest'
  $fixtureChecks++

  $patchPath = Join-Path $fixtureState 'guard.patch.yml'
  $patchBeforeConflict = $null
  if (Test-Path -LiteralPath $patchPath -PathType Leaf) {
    $patchBeforeConflict = [IO.File]::ReadAllText($patchPath)
    [IO.File]::WriteAllText($patchPath, $patchBeforeConflict + "`n# user edit after repair`n", [Text.UTF8Encoding]::new($false))
    $repairConflict = Invoke-PowerShellJson -ScriptPath $repairScript -Arguments @{
      Action = 'revert'
      ReceiptPath = $receiptPath
      Force = $true
    }
    Assert-Standalone ($repairConflict.exitCode -ne 0 -and $repairConflict.text -match 'ROLLBACK_CONFLICT') 'repair revert did not fail closed on a changed post-image'
    [IO.File]::WriteAllText($patchPath, $patchBeforeConflict, [Text.UTF8Encoding]::new($false))
  } else {
    Assert-Standalone $false "repair apply output did not create guard.patch.yml; exit=$($repairApply.exitCode); output=$($repairApply.text)"
  }
  $fixtureChecks++

  $repairRevert = Invoke-PowerShellJson -ScriptPath $repairScript -Arguments @{
    Action = 'revert'
    ReceiptPath = $receiptPath
    Force = $true
  }
  Assert-Standalone ($repairRevert.exitCode -eq 0 -and $repairRevert.value.result -eq 'PASS') 'repair revert did not return PASS'
  Assert-Standalone (-not (Test-Path -LiteralPath (Join-Path $fixtureState 'guard-state.json') -PathType Leaf)) 'repair revert did not remove generated guard-state.json'
  Assert-Standalone (-not (Test-Path -LiteralPath (Join-Path $fixtureState 'guard.patch.yml') -PathType Leaf)) 'repair revert did not remove generated guard.patch.yml'
  Assert-Standalone ((Get-StandaloneSha256 -Path $profileManifestPath) -eq $manifestHashBefore) 'repair revert changed the Profile manifest'
  $fixtureChecks++

  $selfRepairTest = Invoke-PowerShellJson -ScriptPath (Join-Path $toolRoot 'Test-DSHSelfRepair.ps1') -Arguments @{}
  Assert-Standalone ($selfRepairTest.exitCode -eq 0 -and $selfRepairTest.value.result -eq 'PASS' -and $selfRepairTest.value.offline -eq $true -and $selfRepairTest.value.workspaceChanged -eq $false) 'self-repair recovery fixture did not prove bounded offline recovery'
  $fixtureChecks++

  $unifiedEntry = Join-Path $packageRoot 'DSH-Provenance.ps1'
  $unifiedPlanPath = Join-Path $tempRoot 'unified-repair-plan.json'
  $unifiedPlan = Invoke-PowerShellJson -ScriptPath $unifiedEntry -Arguments @{
    Action = 'repair-plan'
    Profile = 'test'
    Port = 1
    StateRoot = $fixtureState
    DiagnosticsPath = $diagnosticsPath
    PlanPath = $unifiedPlanPath
  }
  Assert-Standalone ($unifiedPlan.exitCode -eq 0 -and $unifiedPlan.value.result -eq 'PASS') 'unified repair-plan entry did not return PASS'
  Assert-Standalone (Test-Path -LiteralPath $unifiedPlanPath -PathType Leaf) 'unified repair-plan entry did not write the requested plan'
  $unifiedApply = Invoke-PowerShellJson -ScriptPath $unifiedEntry -Arguments @{
    Action = 'repair-apply'
    Profile = 'test'
    Port = 1
    DshHome = $fixtureDsh
    StateRoot = $fixtureState
    PlanPath = $unifiedPlanPath
    Force = $true
  }
  $unifiedApplyValue = if ($null -ne $unifiedApply.value -and $null -ne $unifiedApply.value.PSObject.Properties['value']) { $unifiedApply.value.value } else { $null }
  $unifiedReceiptPath = if ($null -ne $unifiedApplyValue -and $null -ne $unifiedApplyValue.PSObject.Properties['receipt']) { [string]$unifiedApplyValue.receipt } else { '' }
  Assert-Standalone ($unifiedApply.exitCode -eq 0 -and $unifiedApply.value.result -eq 'PASS' -and $null -ne $unifiedApplyValue -and $unifiedApplyValue.status -eq 'applied') "unified repair-apply entry did not apply the reviewed plan: $($unifiedApply.text)"
  Assert-Standalone (-not [string]::IsNullOrWhiteSpace($unifiedReceiptPath)) "unified repair-apply entry did not return a receipt: $($unifiedApply.text)"
  if ([string]::IsNullOrWhiteSpace($unifiedReceiptPath)) { $unifiedReceiptPath = Join-Path $tempRoot 'missing-unified-receipt.json' }
  $unifiedRevert = Invoke-PowerShellJson -ScriptPath $unifiedEntry -Arguments @{
    Action = 'repair-revert'
    ReceiptPath = $unifiedReceiptPath
    Force = $true
  }
  Assert-Standalone ($unifiedRevert.exitCode -eq 0 -and $unifiedRevert.value.result -eq 'PASS') 'unified repair-revert entry did not return PASS'
  Assert-Standalone (-not (Test-Path -LiteralPath (Join-Path $fixtureState 'guard-state.json') -PathType Leaf)) 'unified repair-revert left guard-state.json behind'
  $fixtureChecks++

  $pluginDisable = Invoke-PowerShellJson -ScriptPath $unifiedEntry -Arguments @{
    Action = 'plugin-disable'
    Profile = 'test'
    PluginId = 'test-dsh-plugin'
    DshHome = $fixtureDsh
    StateRoot = $fixtureState
    Port = 1
  }
  Assert-Standalone ($pluginDisable.exitCode -eq 0 -and $pluginDisable.value.result -eq 'PASS') 'plugin-disable did not return PASS'
  $manualPatchPath = Join-Path $fixtureState 'guard.patch.yml'
  $manualPatchText = if (Test-Path -LiteralPath $manualPatchPath -PathType Leaf) { Get-Content -LiteralPath $manualPatchPath -Raw -Encoding UTF8 } else { '' }
  Assert-Standalone ($manualPatchText -match "id: 'test-dsh-plugin'" -and $manualPatchText -match 'disabled: true') 'plugin-disable did not write the reversible patch'
  $pluginEnable = Invoke-PowerShellJson -ScriptPath $unifiedEntry -Arguments @{
    Action = 'plugin-enable'
    Profile = 'test'
    PluginId = 'test-dsh-plugin'
    DshHome = $fixtureDsh
    StateRoot = $fixtureState
    Port = 1
    ClearQuarantine = $true
  }
  Assert-Standalone ($pluginEnable.exitCode -eq 0 -and $pluginEnable.value.result -eq 'PASS') 'plugin-enable did not return PASS'
  $manualPatchTextAfterEnable = if (Test-Path -LiteralPath $manualPatchPath -PathType Leaf) { Get-Content -LiteralPath $manualPatchPath -Raw -Encoding UTF8 } else { '' }
  Assert-Standalone ($manualPatchTextAfterEnable -notmatch "id: 'test-dsh-plugin'") 'plugin-enable did not clear the reversible patch'
  $fixtureChecks++

  $maliciousPlanPath = Join-Path $tempRoot 'malicious-repair-plan.json'
  [ordered]@{
    schemaVersion = 2
    profile = 'test'
    mode = 'advisory'
    operations = @([ordered]@{ kind = 'recommendation'; message = 'fixture'; mutates = $false; command = 'Remove-Item' })
  } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $maliciousPlanPath -Encoding UTF8
  $maliciousApply = Invoke-PowerShellJson -ScriptPath $repairScript -Arguments @{
    Action = 'apply'
    Profile = 'test'
    DshHome = $fixtureDsh
    StateRoot = $fixtureState
    PlanPath = $maliciousPlanPath
  }
  Assert-Standalone ($maliciousApply.exitCode -ne 0 -and $maliciousApply.text -match 'forbidden property') 'malicious repair plan was not rejected'
  $fixtureChecks++

  $emptyAtSeqFork = Invoke-PowerShellJson -ScriptPath (Join-Path $toolRoot 'DSH-Recovery.ps1') -Arguments @{
    Action = 'session-fork'
    Profile = 'test'
    BaseUrl = 'http://127.0.0.1:1/'
    SessionId = 'fixture'
  }
  Assert-Standalone ($emptyAtSeqFork.exitCode -ne 0) 'empty AtSeq session-fork unexpectedly succeeded'
  Assert-Standalone ($emptyAtSeqFork.text -match 'AtSeq is required') 'empty AtSeq session-fork did not report the explicit AtSeq requirement'
  Assert-Standalone ($emptyAtSeqFork.text -notmatch 'HasValue') 'empty AtSeq session-fork regressed to Nullable.HasValue failure'
  $fixtureChecks++

  Import-Module (Join-Path $toolRoot 'DSH-Guard.psm1') -Force
  $crashCandidate = Get-DshSingleStartupGuardCandidate -Manifest (Read-DshProfileManifest -Path $profileManifestPath) -ErrorText 'Error: test-dsh-plugin failed to initialize'
  Assert-Standalone ($null -ne $crashCandidate -and $crashCandidate.moduleName -eq 'test-dsh-plugin') 'crash fixture did not identify the single safe plugin candidate'
  Assert-Standalone (-not (Test-DshGuardCandidate -ModuleName '@deepseek-ai/dsh-web-app' -Manifest (Read-DshProfileManifest -Path $profileManifestPath))) 'crash fixture would allow a core @deepseek-ai package'
  $crashState = New-DshGuardState -Profile 'test'
  $crashState = Add-DshGuardFailure -State $crashState -Candidate $crashCandidate
  $crashState = Add-DshGuardFailure -State $crashState -Candidate $crashCandidate
  Assert-Standalone ([int]@($crashState.failures)[0].count -eq 2) 'crash fixture did not count repeated failures'
  $crashState = Add-DshGuardQuarantine -State $crashState -Candidate $crashCandidate
  $crashStatePath = Join-Path $fixtureState 'crash-fixture-guard-state.json'
  $crashPatchPath = Join-Path $fixtureState 'crash-fixture-guard.patch.yml'
  Write-DshGuardState -Path $crashStatePath -State $crashState
  Write-DshGuardPatch -Path $crashPatchPath -Entries (Get-DshGuardPatchEntries -State $crashState)
  $crashPatchText = Get-Content -LiteralPath $crashPatchPath -Raw -Encoding UTF8
  Assert-Standalone ($crashPatchText -match "id: 'test-dsh-plugin'" -and $crashPatchText -match 'disabled: true') 'crash fixture did not write a reversible disabled patch'
  $fixtureChecks++
} finally {
  if (Test-Path -LiteralPath $tempRoot) {
    $cleanupDeadline = [DateTime]::UtcNow.AddSeconds(5)
    do {
      try {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction Stop
        break
      } catch {
        if ([DateTime]::UtcNow -ge $cleanupDeadline) { throw }
        Start-Sleep -Milliseconds 100
      }
    } while ([DateTime]::UtcNow -lt $cleanupDeadline)
  }
}

if ($failures.Count -gt 0) {
  [ordered]@{ result = 'FAIL'; failures = @($failures) } | ConvertTo-Json -Depth 8
  exit 1
}
[ordered]@{ result = 'PASS'; filesChecked = $expected.Count; powershellFilesParsed = $powerShellFiles.Count; fixtureChecks = $fixtureChecks } | ConvertTo-Json -Depth 8
exit 0
