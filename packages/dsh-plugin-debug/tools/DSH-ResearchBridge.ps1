[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$RequestPath,
  [string]$EvidencePath = '',
  [string]$OutputPath = '',
  [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:BridgeSchemaVersion = 1
$script:BridgeRequestKind = 'dsh-research-diagnostic-request'
$script:BridgeResultKind = 'dsh-research-diagnostic-result'
$script:BridgeEvidenceKind = 'dsh-debug-repro'
$script:BridgeMaxRequestBytes = 512KB
$script:BridgeMaxEvidenceBytes = 2MB
$script:BridgeMaxSources = 32
$script:BridgeAllowedSourceKinds = @('incident', 'trace', 'pointer', 'diagnostics', 'receipt', 'unknown')
$script:BridgeAllowedChecks = @('coverage', 'privacy', 'integrity')
$script:BridgeCheckStatuses = @('PASS', 'PARTIAL', 'WARN', 'UNAVAILABLE', 'FAIL')
$script:BridgePrivacyKeys = @(
  'toolArgumentsStored',
  'toolResultBodiesStored',
  'sessionContentStored',
  'workspaceContentStored',
  'envContentsStored',
  'credentialsStored',
  'absolutePathsStored',
  'networkAccessed'
)

function Get-BridgeProperty {
  param(
    [Parameter(Mandatory = $true)][AllowNull()]$Object,
    [Parameter(Mandatory = $true)][string]$Name
  )
  if ($null -eq $Object) { return $null }
  $property = $Object.PSObject.Properties[$Name]
  if ($null -eq $property) { return $null }
  return $property.Value
}

function Get-BridgeArray {
  param($Value)
  if ($null -eq $Value) { return @() }
  if ($Value -is [System.Array]) { return @($Value) }
  return @($Value)
}

function Get-BridgeText {
  param($Value, [int]$MaxLength = 200)
  if ($null -eq $Value) { return '' }
  $text = ([string]$Value).Trim()
  if ($text.Length -gt $MaxLength) { return $text.Substring(0, $MaxLength) }
  return $text
}

function Test-BridgeId {
  param([string]$Value)
  return -not [string]::IsNullOrWhiteSpace($Value) -and $Value -match '^[A-Za-z0-9][A-Za-z0-9._:-]{0,119}$'
}

function Test-BridgeFalse {
  param($Value)
  return $Value -is [bool] -and $Value -eq $false
}

function Resolve-BridgeJsonFile {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][int64]$MaxBytes
  )
  try { $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop } catch { throw 'input file is unavailable' }
  if ($item.PSIsContainer -or (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
    throw 'input must be a regular JSON file'
  }
  if ([IO.Path]::GetExtension($item.FullName).ToLowerInvariant() -ne '.json') {
    throw 'input must use the JSON format'
  }
  if ([int64]$item.Length -gt $MaxBytes) { throw 'input exceeds the bounded bridge limit' }
  return [IO.Path]::GetFullPath($item.FullName)
}

function Read-BridgeJson {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][int64]$MaxBytes
  )
  $resolved = Resolve-BridgeJsonFile -Path $Path -MaxBytes $MaxBytes
  try {
    $value = Get-Content -LiteralPath $resolved -Raw -Encoding UTF8 | ConvertFrom-Json
  } catch {
    throw 'input JSON is malformed'
  }
  if ($null -eq $value) { throw 'input JSON is empty' }
  return [ordered]@{ path = $resolved; value = $value }
}

function Get-BridgeHash {
  param([Parameter(Mandatory = $true)][string]$Path)
  $sha = [Security.Cryptography.SHA256]::Create()
  try {
    return ([BitConverter]::ToString($sha.ComputeHash([IO.File]::ReadAllBytes($Path)))).Replace('-', '').ToLowerInvariant()
  } finally {
    $sha.Dispose()
  }
}

function Get-BridgeSourceKind {
  param($Value)
  $kind = ([string](Get-BridgeProperty -Object $Value -Name 'kind')).Trim()
  if ($kind -match '(?i)incident') { return 'incident' }
  if ($kind -match '(?i)trace|tool.?call') { return 'trace' }
  if ($kind -match '(?i)pointer|provenance') { return 'pointer' }
  if ($kind -match '(?i)health|diagnostic') { return 'diagnostics' }
  if ($kind -match '(?i)receipt|repair') { return 'receipt' }
  return 'unknown'
}

function Get-BridgeStatus {
  param($Value)
  foreach ($name in @('result', 'status', 'verdict')) {
    $candidate = Get-BridgeText (Get-BridgeProperty -Object $Value -Name $name) 40
    if (-not [string]::IsNullOrWhiteSpace($candidate)) { return $candidate }
  }
  return 'UNKNOWN'
}

function New-BridgeFinding {
  param(
    [Parameter(Mandatory = $true)][string]$Code,
    [Parameter(Mandatory = $true)][ValidateSet('info', 'warning', 'error')][string]$Severity,
    [Parameter(Mandatory = $true)][string]$Message
  )
  return [ordered]@{ code = $Code; severity = $Severity; message = $Message }
}

function Get-BridgeRequestInfo {
  param([Parameter(Mandatory = $true)]$Request)
  $errors = [System.Collections.Generic.List[string]]::new()
  $requestId = Get-BridgeText (Get-BridgeProperty -Object $Request -Name 'requestId') 120
  if (-not (Test-BridgeId $requestId)) { [void]$errors.Add('REQUEST_ID_INVALID') }

  $schemaValue = Get-BridgeProperty -Object $Request -Name 'schemaVersion'
  $schema = 0
  try { $schema = [int]$schemaValue } catch { }
  if ($schema -ne $script:BridgeSchemaVersion) { [void]$errors.Add('REQUEST_SCHEMA_UNSUPPORTED') }
  if (([string](Get-BridgeProperty -Object $Request -Name 'kind')) -ne $script:BridgeRequestKind) {
    [void]$errors.Add('REQUEST_KIND_INVALID')
  }

  $course = Get-BridgeProperty -Object $Request -Name 'course'
  $courseIds = [ordered]@{
    siteId = Get-BridgeText (Get-BridgeProperty -Object $course -Name 'siteId') 120
    courseId = Get-BridgeText (Get-BridgeProperty -Object $course -Name 'courseId') 120
    lessonId = Get-BridgeText (Get-BridgeProperty -Object $course -Name 'lessonId') 120
    questionId = Get-BridgeText (Get-BridgeProperty -Object $course -Name 'questionId') 120
  }
  foreach ($name in $courseIds.Keys) {
    if (-not (Test-BridgeId ([string]$courseIds[$name]))) { [void]$errors.Add("COURSE_$($name.ToUpperInvariant())_INVALID") }
  }

  $question = Get-BridgeProperty -Object $Request -Name 'question'
  $title = Get-BridgeText (Get-BridgeProperty -Object $question -Name 'title') 240
  if ([string]::IsNullOrWhiteSpace($title)) { [void]$errors.Add('QUESTION_TITLE_MISSING') }
  $required = [System.Collections.Generic.List[string]]::new()
  foreach ($rawKind in @(Get-BridgeArray (Get-BridgeProperty -Object $question -Name 'requiredSourceKinds'))) {
    $kind = ([string]$rawKind).Trim().ToLowerInvariant()
    if ($script:BridgeAllowedSourceKinds -notcontains $kind) {
      [void]$errors.Add('QUESTION_SOURCE_KIND_INVALID')
    } elseif (-not $required.Contains($kind)) {
      [void]$required.Add($kind)
    }
  }
  if ($required.Count -eq 0) { [void]$errors.Add('QUESTION_SOURCE_KINDS_MISSING') }

  $requestedChecks = [System.Collections.Generic.List[string]]::new()
  foreach ($rawCheck in @(Get-BridgeArray (Get-BridgeProperty -Object $question -Name 'requestedChecks'))) {
    $check = ([string]$rawCheck).Trim().ToLowerInvariant()
    if ($script:BridgeAllowedChecks -notcontains $check) {
      [void]$errors.Add('QUESTION_CHECK_UNSUPPORTED')
    } elseif ($requestedChecks.Contains($check)) {
      [void]$errors.Add('QUESTION_CHECK_DUPLICATE')
    } else {
      [void]$requestedChecks.Add($check)
    }
  }
  if ($requestedChecks.Count -eq 0) { [void]$errors.Add('QUESTION_CHECKS_MISSING') }

  $safety = Get-BridgeProperty -Object $Request -Name 'safety'
  foreach ($name in @('inputMode', 'networkAccessed', 'commandsExecuted', 'targetMutated', 'uploads')) {
    $value = Get-BridgeProperty -Object $safety -Name $name
    if ($name -eq 'inputMode') {
      if (([string]$value) -ne 'explicit-file-only') { [void]$errors.Add('SAFETY_INPUT_MODE_INVALID') }
    } elseif (-not (Test-BridgeFalse $value)) {
      [void]$errors.Add("SAFETY_$($name.ToUpperInvariant())_MUST_BE_FALSE")
    }
  }

  return [ordered]@{
    valid = $errors.Count -eq 0
    errors = @($errors)
    requestId = $requestId
    course = $courseIds
    question = [ordered]@{
      title = $title
      requiredSourceKinds = @($required)
      requestedChecks = @($requestedChecks)
    }
  }
}

function Test-BridgePrivacyDeclaration {
  param($Repro)
  if (-not (Test-BridgeFalse (Get-BridgeProperty -Object $Repro -Name 'rawPayloadStored'))) { return $false }
  $privacy = Get-BridgeProperty -Object $Repro -Name 'privacy'
  foreach ($name in $script:BridgePrivacyKeys) {
    if (-not (Test-BridgeFalse (Get-BridgeProperty -Object $privacy -Name $name))) { return $false }
  }
  return $true
}

function Get-BridgeManifestStatus {
  param([Parameter(Mandatory = $true)][string]$ReproPath)
  $manifestPath = Join-Path (Split-Path -Parent $ReproPath) 'manifest.json'
  if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { return 'absent' }
  try {
    $manifestItem = Get-Item -LiteralPath $manifestPath -Force -ErrorAction Stop
    if (($manifestItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return 'invalid' }
    $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if (([string](Get-BridgeProperty -Object $manifest -Name 'kind')) -ne 'dsh-debug-repro-manifest') { return 'invalid' }
    $artifact = @(Get-BridgeArray (Get-BridgeProperty -Object $manifest -Name 'artifacts') | Where-Object { ([string](Get-BridgeProperty -Object $_ -Name 'name')) -eq 'repro.json' }) | Select-Object -First 1
    if ($null -eq $artifact) { return 'invalid' }
    $declared = ([string](Get-BridgeProperty -Object $artifact -Name 'sha256')).ToLowerInvariant()
    if ($declared -notmatch '^[0-9a-f]{64}$') { return 'invalid' }
    if ($declared -ne (Get-BridgeHash -Path $ReproPath)) { return 'mismatch' }
    return 'verified'
  } catch {
    return 'invalid'
  }
}

function Get-BridgeEvidenceInfo {
  param([string]$Path)
  if ([string]::IsNullOrWhiteSpace($Path)) {
    return [ordered]@{
      present = $false
      valid = $true
      artifactKind = $null
      sourceCount = 0
      sourceKinds = @()
      sourceStatuses = @()
      integrity = 'absent'
      errors = @()
    }
  }

  $read = Read-BridgeJson -Path $Path -MaxBytes $script:BridgeMaxEvidenceBytes
  $repro = $read.value
  $errors = [System.Collections.Generic.List[string]]::new()
  if (([string](Get-BridgeProperty -Object $repro -Name 'kind')) -ne $script:BridgeEvidenceKind) {
    [void]$errors.Add('EVIDENCE_KIND_INVALID')
  }
  $schema = 0
  try { $schema = [int](Get-BridgeProperty -Object $repro -Name 'schemaVersion') } catch { }
  if ($schema -ne $script:BridgeSchemaVersion) { [void]$errors.Add('EVIDENCE_SCHEMA_UNSUPPORTED') }
  if (-not (Test-BridgePrivacyDeclaration -Repro $repro)) { [void]$errors.Add('EVIDENCE_PRIVACY_DECLARATION_INVALID') }

  $sources = @(Get-BridgeArray (Get-BridgeProperty -Object $repro -Name 'sources'))
  if ($sources.Count -gt $script:BridgeMaxSources) { [void]$errors.Add('EVIDENCE_SOURCE_LIMIT_EXCEEDED') }
  $declaredCountRaw = Get-BridgeProperty -Object $repro -Name 'sourceCount'
  $declaredCount = 0
  $declaredCountValid = $null -ne $declaredCountRaw -and $declaredCountRaw -isnot [bool]
  if ($declaredCountValid) {
    try { $declaredCount = [int]$declaredCountRaw } catch { $declaredCountValid = $false }
  }
  if (-not $declaredCountValid -or $declaredCount -ne $sources.Count) { [void]$errors.Add('EVIDENCE_SOURCE_COUNT_MISMATCH') }

  $kinds = [System.Collections.Generic.List[string]]::new()
  $statuses = [System.Collections.Generic.List[object]]::new()
  foreach ($source in $sources) {
    $kind = ([string](Get-BridgeProperty -Object $source -Name 'sourceKind')).Trim().ToLowerInvariant()
    if ($script:BridgeAllowedSourceKinds -notcontains $kind) {
      [void]$errors.Add('EVIDENCE_SOURCE_KIND_INVALID')
      continue
    }
    if (-not $kinds.Contains($kind)) { [void]$kinds.Add($kind) }
    $evidence = Get-BridgeProperty -Object $source -Name 'evidence'
    [void]$statuses.Add([ordered]@{ sourceKind = $kind; status = Get-BridgeStatus -Value $evidence })
  }
  $integrity = Get-BridgeManifestStatus -ReproPath $read.path
  if ($integrity -in @('invalid', 'mismatch')) { [void]$errors.Add('EVIDENCE_MANIFEST_INVALID') }

  return [ordered]@{
    present = $true
    valid = $errors.Count -eq 0
    artifactKind = $script:BridgeEvidenceKind
    sourceCount = $sources.Count
    sourceKinds = @($kinds | Sort-Object)
    sourceStatuses = @($statuses)
    integrity = $integrity
    errors = @($errors)
  }
}

function Get-BridgeCheckResults {
  param(
    [Parameter(Mandatory = $true)]$RequestInfo,
    [Parameter(Mandatory = $true)]$EvidenceInfo,
    [Parameter(Mandatory = $true)][AllowEmptyCollection()][System.Collections.Generic.List[string]]$MissingKinds
  )
  $results = [System.Collections.Generic.List[object]]::new()
  foreach ($checkId in @($RequestInfo.question.requestedChecks)) {
    $status = 'FAIL'
    $codes = [System.Collections.Generic.List[string]]::new()
    if (-not $EvidenceInfo.present) {
      $status = 'UNAVAILABLE'
      [void]$codes.Add('EVIDENCE_NOT_SUPPLIED')
    } elseif (-not $EvidenceInfo.valid) {
      $status = 'FAIL'
      [void]$codes.Add('EVIDENCE_ARTIFACT_INVALID')
      if ($checkId -eq 'privacy' -and @($EvidenceInfo.errors) -contains 'EVIDENCE_PRIVACY_DECLARATION_INVALID') {
        [void]$codes.Add('EVIDENCE_PRIVACY_DECLARATION_INVALID')
      }
      if ($checkId -eq 'integrity' -and @($EvidenceInfo.errors) -contains 'EVIDENCE_MANIFEST_INVALID') {
        [void]$codes.Add('EVIDENCE_MANIFEST_INVALID')
      }
    } else {
      switch ($checkId) {
        'coverage' {
          if ($MissingKinds.Count -gt 0) {
            $status = 'PARTIAL'
            [void]$codes.Add('EVIDENCE_KIND_MISSING')
          } else {
            $status = 'PASS'
            [void]$codes.Add('REQUIRED_EVIDENCE_PRESENT')
          }
        }
        'privacy' {
          $status = 'PASS'
          [void]$codes.Add('EVIDENCE_PRIVACY_DECLARATION_VALID')
        }
        'integrity' {
          switch ([string]$EvidenceInfo.integrity) {
            'verified' {
              $status = 'PASS'
              [void]$codes.Add('EVIDENCE_MANIFEST_VERIFIED')
            }
            'absent' {
              $status = 'WARN'
              [void]$codes.Add('EVIDENCE_MANIFEST_NOT_FOUND')
            }
            'invalid' {
              $status = 'FAIL'
              [void]$codes.Add('EVIDENCE_MANIFEST_INVALID')
            }
            'mismatch' {
              $status = 'FAIL'
              [void]$codes.Add('EVIDENCE_MANIFEST_INVALID')
            }
            default {
              $status = 'UNAVAILABLE'
              [void]$codes.Add('EVIDENCE_INTEGRITY_NOT_CHECKED')
            }
          }
        }
      }
    }
    [void]$results.Add([ordered]@{
        checkId = [string]$checkId
        status = $status
        findingCodes = @($codes)
      })
  }
  return @($results)
}

function Add-BridgeFindingUnique {
  param(
    [Parameter(Mandatory = $true)][AllowEmptyCollection()][System.Collections.Generic.List[object]]$Findings,
    [Parameter(Mandatory = $true)][string]$Code,
    [Parameter(Mandatory = $true)][ValidateSet('info', 'warning', 'error')][string]$Severity,
    [Parameter(Mandatory = $true)][string]$Message
  )
  foreach ($finding in @($Findings)) {
    if ([string](Get-BridgeProperty -Object $finding -Name 'code') -eq $Code) { return }
  }
  [void]$Findings.Add((New-BridgeFinding -Code $Code -Severity $Severity -Message $Message))
}

function Add-BridgeCheckFindings {
  param(
    [Parameter(Mandatory = $true)][AllowEmptyCollection()][System.Collections.Generic.List[object]]$Findings,
    [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Checks,
    [Parameter(Mandatory = $true)][AllowEmptyCollection()][System.Collections.Generic.List[string]]$MissingKinds
  )
  foreach ($check in @($Checks)) {
    foreach ($code in @((Get-BridgeProperty -Object $check -Name 'findingCodes'))) {
      switch ([string]$code) {
        'REQUIRED_EVIDENCE_PRESENT' {
          Add-BridgeFindingUnique -Findings $Findings -Code $code -Severity 'info' -Message 'All requested evidence kinds are present in the explicit repro artifact.'
        }
        'EVIDENCE_KIND_MISSING' {
          $missingText = (@($MissingKinds) -join ', ')
          Add-BridgeFindingUnique -Findings $Findings -Code $code -Severity 'warning' -Message "Required evidence kind is missing: $missingText."
        }
        'EVIDENCE_NOT_SUPPLIED' {
          Add-BridgeFindingUnique -Findings $Findings -Code $code -Severity 'info' -Message 'No explicit metadata-only repro artifact was supplied.'
        }
        'EVIDENCE_PRIVACY_DECLARATION_VALID' {
          Add-BridgeFindingUnique -Findings $Findings -Code $code -Severity 'info' -Message 'The supplied repro declares the required metadata-only privacy fields.'
        }
        'EVIDENCE_MANIFEST_VERIFIED' {
          Add-BridgeFindingUnique -Findings $Findings -Code $code -Severity 'info' -Message 'The sibling manifest hash matches repro.json.'
        }
        'EVIDENCE_MANIFEST_NOT_FOUND' {
          Add-BridgeFindingUnique -Findings $Findings -Code $code -Severity 'warning' -Message 'The repro artifact was read, but its sibling manifest was not available for hash verification.'
        }
        'EVIDENCE_ARTIFACT_INVALID' {
          Add-BridgeFindingUnique -Findings $Findings -Code $code -Severity 'error' -Message 'The evidence artifact failed the metadata-only repro contract.'
        }
        'EVIDENCE_PRIVACY_DECLARATION_INVALID' {
          Add-BridgeFindingUnique -Findings $Findings -Code $code -Severity 'error' -Message 'The evidence privacy declaration was not fail-closed.'
        }
        'EVIDENCE_MANIFEST_INVALID' {
          Add-BridgeFindingUnique -Findings $Findings -Code $code -Severity 'error' -Message 'The sibling manifest was invalid or did not match repro.json.'
        }
        'EVIDENCE_INTEGRITY_NOT_CHECKED' {
          Add-BridgeFindingUnique -Findings $Findings -Code $code -Severity 'warning' -Message 'Evidence integrity could not be checked.'
        }
      }
    }
  }
}

function Write-BridgeResult {
  param(
    [Parameter(Mandatory = $true)]$Result,
    [string]$Path,
    [string[]]$ForbiddenPaths = @(),
    [switch]$AllowOverwrite
  )
  if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
  $resolved = [IO.Path]::GetFullPath($Path)
  if ([IO.Path]::GetExtension($resolved).ToLowerInvariant() -ne '.json') { throw 'output must use the JSON format' }
  foreach ($forbiddenPath in @($ForbiddenPaths)) {
    if ([string]::IsNullOrWhiteSpace($forbiddenPath)) { continue }
    $normalizedForbidden = [IO.Path]::GetFullPath($forbiddenPath)
    if ([StringComparer]::OrdinalIgnoreCase.Equals($resolved, $normalizedForbidden)) {
      throw 'output must not overwrite a request or evidence input'
    }
  }
  if (Test-Path -LiteralPath $resolved) {
    $item = Get-Item -LiteralPath $resolved -Force -ErrorAction Stop
    if ($item.PSIsContainer -or (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) { throw 'output is not a regular file' }
    if (-not $AllowOverwrite) { throw 'output already exists; pass Force to replace it' }
  }
  $parent = Split-Path -Parent $resolved
  if (-not (Test-Path -LiteralPath $parent -PathType Container)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
  [IO.File]::WriteAllText($resolved, ($Result | ConvertTo-Json -Depth 30), [Text.UTF8Encoding]::new($false))
  return $true
}

$result = $null
$exitCode = 0
$requestRead = $null
$evidenceInfo = $null
try {
  $requestRead = Read-BridgeJson -Path $RequestPath -MaxBytes $script:BridgeMaxRequestBytes
  $requestInfo = Get-BridgeRequestInfo -Request $requestRead.value
  $findings = [System.Collections.Generic.List[object]]::new()
  if (-not $requestInfo.valid) {
    foreach ($errorCode in @($requestInfo.errors)) {
      [void]$findings.Add((New-BridgeFinding -Code ([string]$errorCode) -Severity 'error' -Message 'The research request did not satisfy the bridge schema.'))
    }
  }

  $evidenceInfo = if ($requestInfo.valid) { Get-BridgeEvidenceInfo -Path $EvidencePath } else {
    [ordered]@{ present = $false; valid = $true; artifactKind = $null; sourceCount = 0; sourceKinds = @(); sourceStatuses = @(); integrity = 'not-checked'; errors = @() }
  }
  if ($evidenceInfo.present -and -not $evidenceInfo.valid) {
    foreach ($errorCode in @($evidenceInfo.errors)) {
      [void]$findings.Add((New-BridgeFinding -Code ([string]$errorCode) -Severity 'error' -Message 'The evidence artifact did not satisfy the metadata-only repro contract.'))
    }
  }

  $missingKinds = [System.Collections.Generic.List[string]]::new()
  if ($requestInfo.valid -and $evidenceInfo.present) {
    foreach ($requiredKind in @($requestInfo.question.requiredSourceKinds)) {
      if (@($evidenceInfo.sourceKinds) -notcontains $requiredKind) { [void]$missingKinds.Add($requiredKind) }
    }
  }

  $checkResults = @()
  if ($requestInfo.valid) {
    $checkResults = @(Get-BridgeCheckResults -RequestInfo $requestInfo -EvidenceInfo $evidenceInfo -MissingKinds $missingKinds)
    Add-BridgeCheckFindings -Findings $findings -Checks $checkResults -MissingKinds $missingKinds
  }

  $status = 'FAIL'
  if ($requestInfo.valid -and $evidenceInfo.valid) {
    if (-not $evidenceInfo.present) {
      $status = 'UNAVAILABLE'
    } elseif (@($checkResults | Where-Object { $_.status -eq 'FAIL' }).Count -gt 0) {
      $status = 'FAIL'
    } elseif ($missingKinds.Count -gt 0 -or @($checkResults | Where-Object { $_.status -ne 'PASS' }).Count -gt 0) {
      $status = 'PARTIAL'
    } else {
      $status = 'COMPLETE'
    }
  }

  $nextAction = switch ($status) {
    'COMPLETE' { 'return-to-course' }
    'PARTIAL' { 'supply-missing-evidence' }
    'UNAVAILABLE' { 'run-explicit-repro-export' }
    default { 'fix-request-or-artifact' }
  }
  $result = [ordered]@{
    schemaVersion = $script:BridgeSchemaVersion
    kind = $script:BridgeResultKind
    requestId = [string]$requestInfo.requestId
    generatedAt = (Get-Date).ToUniversalTime().ToString('o')
    status = $status
    result = $status
    course = $requestInfo.course
    question = $requestInfo.question
    evidence = [ordered]@{
      artifactPresent = [bool]$evidenceInfo.present
      artifactKind = $evidenceInfo.artifactKind
      sourceCount = [int]$evidenceInfo.sourceCount
      sourceKinds = @($evidenceInfo.sourceKinds)
      sourceStatuses = @($evidenceInfo.sourceStatuses)
      missingKinds = @($missingKinds)
      integrity = [string]$evidenceInfo.integrity
      trust = 'declared-metadata-only'
    }
    checks = @($checkResults)
    findings = @($findings)
    privacy = [ordered]@{
      inputMode = 'explicit-file-only'
      networkAccessed = $false
      commandsExecuted = $false
      targetMutated = $false
      uploads = $false
      rawPayloadStored = $false
      absolutePathsStored = $false
    }
    handoff = [ordered]@{
      returnToCourse = $status -ne 'FAIL'
      requiresManualReview = $status -in @('PARTIAL', 'UNAVAILABLE')
      nextAction = $nextAction
    }
  }
  if (-not $requestInfo.valid -or ($evidenceInfo.present -and -not $evidenceInfo.valid)) { $exitCode = 1 }
} catch {
  $result = [ordered]@{
    schemaVersion = $script:BridgeSchemaVersion
    kind = $script:BridgeResultKind
    requestId = ''
    generatedAt = (Get-Date).ToUniversalTime().ToString('o')
    status = 'FAIL'
    result = 'FAIL'
    errorCode = 'BRIDGE_INPUT_OR_OUTPUT_ERROR'
    checks = @()
    findings = @([ordered]@{ code = 'BRIDGE_INPUT_OR_OUTPUT_ERROR'; severity = 'error'; message = 'The bridge could not read the explicit request/evidence or write the requested result.' })
    privacy = [ordered]@{
      inputMode = 'explicit-file-only'
      networkAccessed = $false
      commandsExecuted = $false
      targetMutated = $false
      uploads = $false
      rawPayloadStored = $false
      absolutePathsStored = $false
    }
    handoff = [ordered]@{ returnToCourse = $false; requiresManualReview = $true; nextAction = 'fix-request-or-artifact' }
  }
  $exitCode = 1
}

try {
  $forbiddenPaths = @()
  if ($null -ne $requestRead -and $null -ne $requestRead.path) { $forbiddenPaths += [string]$requestRead.path }
  if (-not [string]::IsNullOrWhiteSpace($EvidencePath)) {
    try { $forbiddenPaths += [IO.Path]::GetFullPath($EvidencePath) } catch { }
  }
  # Set this before serializing so the file and stdout carry the same result.
  $result.outputWritten = -not [string]::IsNullOrWhiteSpace($OutputPath)
  $outputWritten = Write-BridgeResult -Result $result -Path $OutputPath -ForbiddenPaths $forbiddenPaths -AllowOverwrite:$Force
  $result.outputWritten = [bool]$outputWritten
} catch {
  $result.outputWritten = $false
  $result.status = 'FAIL'
  $result.result = 'FAIL'
  $result.errorCode = 'OUTPUT_REJECTED'
  $result.findings = @([ordered]@{ code = 'OUTPUT_REJECTED'; severity = 'error'; message = 'The requested result path was rejected; no source input was changed.' })
  $result.handoff = [ordered]@{ returnToCourse = $false; requiresManualReview = $true; nextAction = 'fix-request-or-artifact' }
  $exitCode = 1
}

$result | ConvertTo-Json -Depth 30
exit $exitCode
