[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$toolRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $toolRoot 'DSH-PowerShell.ps1')
$bridgeScript = Join-Path $toolRoot 'DSH-ResearchBridge.ps1'
$failures = [System.Collections.Generic.List[string]]::new()

function Assert-ResearchBridge {
  param([bool]$Condition, [string]$Message)
  if (-not $Condition) { [void]$failures.Add($Message) }
}

function Write-ResearchBridgeJson {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)]$Value
  )
  [IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 30), [Text.UTF8Encoding]::new($false))
}

function Get-ResearchBridgeHash {
  param([Parameter(Mandatory = $true)][string]$Path)
  $getFileHash = Get-Command Get-FileHash -ErrorAction SilentlyContinue
  if ($null -ne $getFileHash) { return [string](Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
  $sha = [Security.Cryptography.SHA256]::Create()
  try {
    return ([BitConverter]::ToString($sha.ComputeHash([IO.File]::ReadAllBytes($Path)))).Replace('-', '').ToLowerInvariant()
  } finally {
    $sha.Dispose()
  }
}

function New-ResearchBridgeRequest {
  param(
    [string]$RequestId = 'course-context-001',
    [bool]$Safe = $true,
    [bool]$CompleteShape = $true
  )
  if (-not $CompleteShape) {
    return [ordered]@{
      schemaVersion = 1
      kind = 'dsh-research-diagnostic-request'
      requestId = $RequestId
      question = [ordered]@{}
      safety = [ordered]@{ inputMode = 'explicit-file-only'; networkAccessed = $false; commandsExecuted = $false; targetMutated = $false; uploads = $false }
    }
  }
  return [ordered]@{
    schemaVersion = 1
    kind = 'dsh-research-diagnostic-request'
    requestId = $RequestId
    course = [ordered]@{
      siteId = 'dsh-study'
      courseId = 'deepseek-harness'
      lessonId = 'debug-bridge-v1'
      questionId = 'evidence-coverage'
    }
    question = [ordered]@{
      title = '检查上下文诊断证据是否完整'
      requiredSourceKinds = @('diagnostics', 'trace')
      requestedChecks = @('coverage', 'privacy', 'integrity')
    }
    safety = [ordered]@{
      inputMode = 'explicit-file-only'
      networkAccessed = $false
      commandsExecuted = $false
      targetMutated = $false
      uploads = $false
    }
  }
}

function New-ResearchBridgeRepro {
  param(
    [string[]]$SourceKinds = @('diagnostics', 'trace'),
    [bool]$Private = $true
  )
  $sources = @($SourceKinds | ForEach-Object {
      [ordered]@{
        sourceKind = [string]$_
        evidence = [ordered]@{ status = 'PASS'; result = 'PASS' }
      }
    })
  $privacy = [ordered]@{
    toolArgumentsStored = $false
    toolResultBodiesStored = $false
    sessionContentStored = $false
    workspaceContentStored = $false
    envContentsStored = $false
    credentialsStored = $false
    absolutePathsStored = $false
    networkAccessed = $false
  }
  if (-not $Private) { $privacy.credentialsStored = $true }
  return [ordered]@{
    schemaVersion = 1
    kind = 'dsh-debug-repro'
    sourceCount = $sources.Count
    sourceKinds = @($SourceKinds)
    sources = $sources
    rawPayloadStored = $false
    privacy = $privacy
    ignoredRawPayload = 'RAW-PAYLOAD-MUST-NOT-APPEAR'
    ignoredToolArguments = 'TOOL-ARGUMENTS-MUST-NOT-APPEAR'
    ignoredSessionBody = 'SESSION-BODY-MUST-NOT-APPEAR'
  }
}

function New-ResearchBridgeEvidence {
  param(
    [Parameter(Mandatory = $true)][string]$Root,
    [string[]]$SourceKinds = @('diagnostics', 'trace'),
    [bool]$Private = $true,
    [bool]$ValidManifest = $true
  )
  New-Item -ItemType Directory -Path $Root -Force | Out-Null
  $reproPath = Join-Path $Root 'repro.json'
  $manifestPath = Join-Path $Root 'manifest.json'
  $repro = New-ResearchBridgeRepro -SourceKinds $SourceKinds -Private $Private
  Write-ResearchBridgeJson -Path $reproPath -Value $repro
  $hash = if ($ValidManifest) { Get-ResearchBridgeHash -Path $reproPath } else { ('0' * 64) }
  Write-ResearchBridgeJson -Path $manifestPath -Value ([ordered]@{
      schemaVersion = 1
      kind = 'dsh-debug-repro-manifest'
      artifacts = @([ordered]@{ name = 'repro.json'; sha256 = $hash })
    })
  return $reproPath
}

function Invoke-ResearchBridge {
  param(
    [Parameter(Mandatory = $true)][string]$RequestPath,
    [string]$EvidencePath = '',
    [string]$OutputPath = '',
    [string]$ScriptPath = $bridgeScript,
    [switch]$ThroughAction,
    [switch]$Force
  )
  $tokens = [System.Collections.Generic.List[string]]::new()
  if ($ThroughAction) {
    [void]$tokens.Add('-Action'); [void]$tokens.Add('research-bridge')
    [void]$tokens.Add('-ResearchRequestPath'); [void]$tokens.Add($RequestPath)
  } else {
    [void]$tokens.Add('-RequestPath'); [void]$tokens.Add($RequestPath)
  }
  if (-not [string]::IsNullOrWhiteSpace($EvidencePath)) {
    [void]$tokens.Add($(if ($ThroughAction) { '-ResearchEvidencePath' } else { '-EvidencePath' })); [void]$tokens.Add($EvidencePath)
  }
  if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
    [void]$tokens.Add($(if ($ThroughAction) { '-ResearchResultPath' } else { '-OutputPath' })); [void]$tokens.Add($OutputPath)
  }
  if ($Force) { [void]$tokens.Add('-Force') }
  $previousErrorAction = $ErrorActionPreference
  try {
    $ErrorActionPreference = 'Continue'
    $lines = @(& (Get-DshPowerShellPath) -NoLogo -NoProfile -ExecutionPolicy Bypass -File $ScriptPath @tokens 2>&1)
    $exitCode = if (Test-Path variable:LASTEXITCODE) { [int]$LASTEXITCODE } else { 0 }
  } finally {
    $ErrorActionPreference = $previousErrorAction
  }
  $text = ($lines | ForEach-Object { [string]$_ }) -join "`n"
  $value = $null
  try { $value = ($text.Trim() | ConvertFrom-Json -ErrorAction Stop) } catch { }
  return [PSCustomObject]@{ exitCode = $exitCode; text = $text; value = $value }
}

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('dsh-research-bridge-' + [Guid]::NewGuid().ToString('N'))
try {
  New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
  $requestPath = Join-Path $tempRoot 'request.json'
  Write-ResearchBridgeJson -Path $requestPath -Value (New-ResearchBridgeRequest)
  $requestHashBefore = Get-ResearchBridgeHash -Path $requestPath

  $completeRoot = Join-Path $tempRoot 'complete'
  $completeEvidence = New-ResearchBridgeEvidence -Root $completeRoot
  $completeOutput = Join-Path $tempRoot 'complete-result.json'
  $complete = Invoke-ResearchBridge -RequestPath $requestPath -EvidencePath $completeEvidence -OutputPath $completeOutput
  Assert-ResearchBridge ($complete.exitCode -eq 0 -and $complete.value.status -eq 'COMPLETE') 'complete evidence did not return COMPLETE'
  Assert-ResearchBridge ($complete.value.outputWritten -eq $true) 'complete result did not report outputWritten=true'
  Assert-ResearchBridge ($complete.value.evidence.integrity -eq 'verified') 'complete evidence manifest was not verified'
  Assert-ResearchBridge (@($complete.value.evidence.sourceKinds) -contains 'diagnostics' -and @($complete.value.evidence.sourceKinds) -contains 'trace') 'complete source kinds were not projected'
  Assert-ResearchBridge (@($complete.value.checks).Count -eq 3 -and @($complete.value.checks | Where-Object { $_.status -ne 'PASS' }).Count -eq 0) 'complete result did not report every requested check as PASS'
  Assert-ResearchBridge (Test-Path -LiteralPath $completeOutput -PathType Leaf) 'complete result file was not written'
  $completeFile = Get-Content -LiteralPath $completeOutput -Raw -Encoding UTF8 | ConvertFrom-Json
  Assert-ResearchBridge ($completeFile.outputWritten -eq $true -and $completeFile.status -eq 'COMPLETE') 'result file did not contain the same output flag/status as stdout'

  $dispatcher = Invoke-ResearchBridge -RequestPath $requestPath -EvidencePath $completeEvidence -ScriptPath (Join-Path (Split-Path -Parent $toolRoot) 'DSH-Provenance.ps1') -ThroughAction
  Assert-ResearchBridge ($dispatcher.exitCode -eq 0 -and $dispatcher.value.status -eq 'COMPLETE') 'unified dispatcher did not route research-bridge'
  $publicEntry = Invoke-ResearchBridge -RequestPath $requestPath -EvidencePath $completeEvidence -ScriptPath (Join-Path (Split-Path -Parent $toolRoot) 'Debug-DSH.ps1') -ThroughAction
  Assert-ResearchBridge ($publicEntry.exitCode -eq 0 -and $publicEntry.value.status -eq 'COMPLETE') 'public Debug-DSH entry did not route research-bridge'

  $contractRoot = Join-Path $toolRoot 'fixtures\research-bridge-contract'
  $contractExpected = Get-Content -LiteralPath (Join-Path $contractRoot 'expected.json') -Raw -Encoding UTF8 | ConvertFrom-Json
  $contractResult = Invoke-ResearchBridge -RequestPath (Join-Path $contractRoot 'request.json') -EvidencePath (Join-Path $contractRoot 'repro.json')
  $contractProjection = [ordered]@{
    schemaVersion = $contractResult.value.schemaVersion
    requestId = $contractResult.value.requestId
    status = $contractResult.value.status
    sourceKinds = @($contractResult.value.evidence.sourceKinds)
    missingKinds = @($contractResult.value.evidence.missingKinds)
    integrity = $contractResult.value.evidence.integrity
    trust = $contractResult.value.evidence.trust
    checks = @($contractResult.value.checks)
  }
  Assert-ResearchBridge ($contractResult.exitCode -eq 0) 'canonical contract fixture did not execute successfully'
  Assert-ResearchBridge (($contractProjection | ConvertTo-Json -Depth 12 -Compress) -eq ($contractExpected | ConvertTo-Json -Depth 12 -Compress)) 'canonical contract fixture projection drifted'

  $partialRoot = Join-Path $tempRoot 'partial'
  $partialEvidence = New-ResearchBridgeEvidence -Root $partialRoot -SourceKinds @('diagnostics')
  $partial = Invoke-ResearchBridge -RequestPath $requestPath -EvidencePath $partialEvidence -OutputPath (Join-Path $tempRoot 'partial-result.json')
  Assert-ResearchBridge ($partial.exitCode -eq 0 -and $partial.value.status -eq 'PARTIAL') 'missing evidence kind did not return PARTIAL'
  Assert-ResearchBridge (@($partial.value.evidence.missingKinds) -contains 'trace') 'PARTIAL result did not list the missing trace kind'
  Assert-ResearchBridge ((@($partial.value.checks | Where-Object { $_.checkId -eq 'coverage' })[0].status) -eq 'PARTIAL') 'coverage check did not become PARTIAL'
  Assert-ResearchBridge ((@($partial.value.checks | Where-Object { $_.checkId -eq 'privacy' })[0].status) -eq 'PASS') 'privacy check did not remain PASS for valid metadata'

  $unavailable = Invoke-ResearchBridge -RequestPath $requestPath -OutputPath (Join-Path $tempRoot 'unavailable-result.json')
  Assert-ResearchBridge ($unavailable.exitCode -eq 0 -and $unavailable.value.status -eq 'UNAVAILABLE') 'missing evidence did not return UNAVAILABLE'
  Assert-ResearchBridge ($unavailable.value.handoff.nextAction -eq 'run-explicit-repro-export') 'UNAVAILABLE next action is incorrect'
  Assert-ResearchBridge (@($unavailable.value.checks).Count -eq 3 -and @($unavailable.value.checks | Where-Object { $_.status -ne 'UNAVAILABLE' }).Count -eq 0) 'UNAVAILABLE did not propagate to every requested check'

  $noManifestRoot = Join-Path $tempRoot 'manifest-absent'
  $noManifestEvidence = New-ResearchBridgeEvidence -Root $noManifestRoot
  Remove-Item -LiteralPath (Join-Path $noManifestRoot 'manifest.json') -Force
  $noManifest = Invoke-ResearchBridge -RequestPath $requestPath -EvidencePath $noManifestEvidence -OutputPath (Join-Path $tempRoot 'manifest-absent-result.json')
  Assert-ResearchBridge ($noManifest.exitCode -eq 0 -and $noManifest.value.status -eq 'PARTIAL') 'manifest absence did not lower integrity-request result to PARTIAL'
  Assert-ResearchBridge ($noManifest.value.evidence.integrity -eq 'absent') 'manifest absence was not classified as absent'
  Assert-ResearchBridge ((@($noManifest.value.checks | Where-Object { $_.checkId -eq 'integrity' })[0].status) -eq 'WARN') 'manifest absence did not produce an integrity WARN check'

  $invalidRequestPath = Join-Path $tempRoot 'invalid-request.json'
  $invalidRequest = New-ResearchBridgeRequest
  $invalidRequest.safety.networkAccessed = $true
  $invalidRequest.kind = 'not-a-research-request'
  Write-ResearchBridgeJson -Path $invalidRequestPath -Value $invalidRequest
  $invalidRequestResult = Invoke-ResearchBridge -RequestPath $invalidRequestPath -OutputPath (Join-Path $tempRoot 'invalid-request-result.json')
  Assert-ResearchBridge ($invalidRequestResult.exitCode -ne 0 -and $invalidRequestResult.value.status -eq 'FAIL') 'invalid request did not fail closed'
  Assert-ResearchBridge (@($invalidRequestResult.value.findings).code -contains 'REQUEST_KIND_INVALID') 'invalid request kind was not reported'
  Assert-ResearchBridge (@($invalidRequestResult.value.findings).code -contains 'SAFETY_NETWORKACCESSED_MUST_BE_FALSE') 'unsafe request flag was not reported'

  $unsupportedCheckPath = Join-Path $tempRoot 'unsupported-check.json'
  $unsupportedCheck = New-ResearchBridgeRequest
  $unsupportedCheck.question.requestedChecks = @('coverage', 'not-supported')
  Write-ResearchBridgeJson -Path $unsupportedCheckPath -Value $unsupportedCheck
  $unsupportedCheckResult = Invoke-ResearchBridge -RequestPath $unsupportedCheckPath -OutputPath (Join-Path $tempRoot 'unsupported-check-result.json')
  Assert-ResearchBridge ($unsupportedCheckResult.exitCode -ne 0 -and $unsupportedCheckResult.value.status -eq 'FAIL') 'unsupported requested check did not fail closed'
  Assert-ResearchBridge (@($unsupportedCheckResult.value.findings).code -contains 'QUESTION_CHECK_UNSUPPORTED') 'unsupported requested check was not reported'

  $missingShapePath = Join-Path $tempRoot 'missing-shape.json'
  Write-ResearchBridgeJson -Path $missingShapePath -Value (New-ResearchBridgeRequest -CompleteShape $false)
  $missingShape = Invoke-ResearchBridge -RequestPath $missingShapePath -OutputPath (Join-Path $tempRoot 'missing-shape-result.json')
  Assert-ResearchBridge ($missingShape.exitCode -ne 0 -and $missingShape.value.status -eq 'FAIL') 'missing optional objects caused a wrapper exception instead of a schema FAIL'
  Assert-ResearchBridge ($missingShape.text -notmatch '(?i)parameter binding|mandatory parameter') 'missing optional objects leaked a PowerShell parameter binding error'

  $privacyRoot = Join-Path $tempRoot 'privacy-invalid'
  $privacyEvidence = New-ResearchBridgeEvidence -Root $privacyRoot -Private $false
  $privacyResult = Invoke-ResearchBridge -RequestPath $requestPath -EvidencePath $privacyEvidence -OutputPath (Join-Path $tempRoot 'privacy-result.json')
  Assert-ResearchBridge ($privacyResult.exitCode -ne 0 -and $privacyResult.value.status -eq 'FAIL') 'privacy declaration violation did not fail closed'
  Assert-ResearchBridge (@($privacyResult.value.findings).code -contains 'EVIDENCE_PRIVACY_DECLARATION_INVALID') 'privacy declaration violation was not reported'

  $manifestRoot = Join-Path $tempRoot 'manifest-invalid'
  $manifestEvidence = New-ResearchBridgeEvidence -Root $manifestRoot -ValidManifest $false
  $manifestResult = Invoke-ResearchBridge -RequestPath $requestPath -EvidencePath $manifestEvidence -OutputPath (Join-Path $tempRoot 'manifest-result.json')
  Assert-ResearchBridge ($manifestResult.exitCode -ne 0 -and $manifestResult.value.status -eq 'FAIL') 'manifest hash mismatch did not fail closed'
  Assert-ResearchBridge ($manifestResult.value.evidence.integrity -eq 'mismatch') 'manifest hash mismatch was not classified as mismatch'
  Assert-ResearchBridge ((@($manifestResult.value.checks | Where-Object { $_.checkId -eq 'integrity' })[0].status) -eq 'FAIL') 'manifest hash mismatch did not fail the integrity check'

  $existingOutput = Join-Path $tempRoot 'existing-result.json'
  [IO.File]::WriteAllText($existingOutput, 'DO-NOT-OVERWRITE', [Text.UTF8Encoding]::new($false))
  $existingResult = Invoke-ResearchBridge -RequestPath $requestPath -OutputPath $existingOutput
  Assert-ResearchBridge ($existingResult.exitCode -ne 0 -and $existingResult.value.status -eq 'FAIL') 'existing output without Force did not fail closed'
  Assert-ResearchBridge ((Get-Content -LiteralPath $existingOutput -Raw -Encoding UTF8) -eq 'DO-NOT-OVERWRITE') 'existing output was overwritten without Force'

  $requestCollision = Invoke-ResearchBridge -RequestPath $requestPath -EvidencePath $completeEvidence -OutputPath $requestPath -Force
  Assert-ResearchBridge ($requestCollision.exitCode -ne 0 -and $requestCollision.value.status -eq 'FAIL') 'request/output path collision was not rejected'
  Assert-ResearchBridge ((Get-ResearchBridgeHash -Path $requestPath) -eq $requestHashBefore) 'request was modified by an output collision'

  $evidenceHashBefore = Get-ResearchBridgeHash -Path $completeEvidence
  $evidenceCollision = Invoke-ResearchBridge -RequestPath $requestPath -EvidencePath $completeEvidence -OutputPath $completeEvidence -Force
  Assert-ResearchBridge ($evidenceCollision.exitCode -ne 0 -and $evidenceCollision.value.status -eq 'FAIL') 'evidence/output path collision was not rejected'
  Assert-ResearchBridge ((Get-ResearchBridgeHash -Path $completeEvidence) -eq $evidenceHashBefore) 'evidence was modified by an output collision'

  $allOutputText = @(
    $complete.text,
    $partial.text,
    $unavailable.text,
    $invalidRequestResult.text,
    $unsupportedCheckResult.text,
    $missingShape.text,
    $privacyResult.text,
    $manifestResult.text,
    $existingResult.text,
    $requestCollision.text,
    $evidenceCollision.text,
    $dispatcher.text,
    $publicEntry.text
    $contractResult.text
  ) -join "`n"
  Assert-ResearchBridge ($allOutputText -notmatch [regex]::Escape($tempRoot)) 'bridge output leaked an absolute temporary path'
  foreach ($marker in @('RAW-PAYLOAD-MUST-NOT-APPEAR', 'TOOL-ARGUMENTS-MUST-NOT-APPEAR', 'SESSION-BODY-MUST-NOT-APPEAR')) {
    Assert-ResearchBridge ($allOutputText -notmatch [regex]::Escape($marker)) "bridge output leaked prohibited content: $marker"
  }
  Assert-ResearchBridge ((Get-ResearchBridgeHash -Path $requestPath) -eq $requestHashBefore) 'request changed during read-only bridge checks'

  $scriptText = Get-Content -LiteralPath $bridgeScript -Raw -Encoding UTF8
  Assert-ResearchBridge ($scriptText -notmatch '(?i)Invoke-WebRequest|Invoke-RestMethod|Start-BitsTransfer|curl\.exe|wget\.exe|Start-Process') 'research bridge contains a network/process execution primitive'
  $tokens = $null
  $parseErrors = $null
  [System.Management.Automation.Language.Parser]::ParseFile($bridgeScript, [ref]$tokens, [ref]$parseErrors) | Out-Null
  Assert-ResearchBridge ($parseErrors.Count -eq 0) 'research bridge has PowerShell parse errors'
} catch {
  [void]$failures.Add('research bridge fixture threw: ' + $_.Exception.Message)
} finally {
  if (Test-Path -LiteralPath $tempRoot) {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
  }
}

if ($failures.Count -gt 0) {
  [ordered]@{ result = 'FAIL'; failures = @($failures); offline = $true; networkAccessed = $false } | ConvertTo-Json -Depth 12
  exit 1
}
[ordered]@{ result = 'PASS'; offline = $true; networkAccessed = $false; inputChanged = $false; outputCollisionRejected = $true; privacyContractChecked = $true } | ConvertTo-Json -Depth 8
exit 0
