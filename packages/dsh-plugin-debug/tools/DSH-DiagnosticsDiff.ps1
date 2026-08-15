[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$BeforePath,
  [Parameter(Mandatory = $true)][string]$AfterPath,
  [string]$OutputPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:MaxInputBytes = 4MB
$script:MaxDepth = 32
$script:SkipScalar = [guid]::NewGuid().ToString('N')
$script:AllowedKinds = @(
  'dsh-debug-incident',
  'dsh-incident-correlation',
  'dsh-startup-incident',
  'dsh-diagnostics',
  'client-diagnostics-report'
)
$script:PrivacyFalseFields = @(
  'rawinputstored',
  'rawmessagesstored',
  'rawfailuremessagesstored',
  'rawpayloadstored',
  'rawtoolargumentsstored',
  'rawtoolresultsstored',
  'rawtoolresultbodiesstored',
  'rawsessioncontentstored',
  'envcontentsstored',
  'credentialsstored',
  'cookiesstored',
  'tokensstored',
  'toolargumentsstored',
  'toolresultsstored',
  'networkpayloadsent',
  'modelpromptsent',
  'toolexecuted'
)
$script:SafeMetadataNames = @(
  'errorcount',
  'errorresultcount',
  'errorobjectobserved',
  'argumentsobserved',
  'argumentkeysobserved',
  'sandboxpermissionobserved',
  'dispatcherrorcount',
  'turnerrorcount',
  'failurecount',
  'failedplugincount',
  'parseerrorcount',
  'invalidfragmentcount',
  'ignoredrecordcount'
)
$script:CodeArrayNames = @(
  'issuecodes',
  'issuecode',
  'conflictcodes',
  'conflictcode',
  'codes',
  'code',
  'requiredlayers',
  'observedlayers',
  'missinglayers'
)

function Get-DshDiagnosticsDiffProperty {
  param([AllowNull()]$Object, [Parameter(Mandatory = $true)][string]$Name)
  if ($null -eq $Object) { return $null }
  if ($Object -is [System.Collections.IDictionary] -and $Object.Contains($Name)) { return $Object[$Name] }
  $property = $Object.PSObject.Properties[$Name]
  if ($null -eq $property) { return $null }
  return $property.Value
}

function Get-DshDiagnosticsDiffPropertyNames {
  param([AllowNull()]$Object)
  if ($null -eq $Object) { return @() }
  if ($Object -is [System.Collections.IDictionary]) {
    return @($Object.Keys | ForEach-Object { [string]$_ } | Sort-Object)
  }
  return @($Object.PSObject.Properties | ForEach-Object { [string]$_.Name } | Sort-Object)
}

function Test-DshDiagnosticsDiffScalar {
  param([AllowNull()]$Value)
  if ($null -eq $Value -or $Value -is [bool] -or $Value -is [ValueType]) { return $true }
  return $Value -is [string]
}

function Test-DshDiagnosticsDiffSafeCode {
  param([AllowNull()][string]$Value)
  if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
  return $Value.Length -le 120 -and $Value -match '^[A-Za-z0-9_.:-]+$'
}

function Test-DshDiagnosticsDiffSafeString {
  param([AllowNull()][string]$Value)
  if ($null -eq $Value) { return $true }
  if ($Value.Length -gt 240) { return $false }
  if ($Value -match '(?i)[A-Z]:\\|\\\\|https?://|(?:authorization|bearer|api[_-]?key|access[_-]?token|refresh[_-]?token|password|secret|credential)\s*[:=]') { return $false }
  return $Value -match '^[A-Za-z0-9_.:@+% -]*$'
}

function Test-DshDiagnosticsDiffSensitiveString {
  param([AllowNull()][string]$Value)
  if ($null -eq $Value) { return $false }
  return $Value -match '(?i)[A-Z]:\\|\\\\|https?://|(?:authorization|bearer|api[_-]?key|access[_-]?token|refresh[_-]?token|password|secret|credential)\s*[:=]|-----BEGIN(?: [A-Z]+)? PRIVATE KEY-----'
}

function Test-DshDiagnosticsDiffForbiddenName {
  param([Parameter(Mandatory = $true)][string]$Name)
  $lower = $Name.ToLowerInvariant()
  if ($script:PrivacyFalseFields -contains $lower) { return $false }
  if ($script:SafeMetadataNames -contains $lower) { return $false }
  if ($lower -match '(?i)(?:path|url|cwd)$') { return $true }
  return $lower -match '(?:message|error|exception|stack|traceback|command|script|shell|arg|argument|content|body|payload|output|stdout|stderr|prompt|token|secret|password|authorization|cookie|credential|header|raw)'
}

function Add-DshDiagnosticsDiffSensitiveHit {
  param(
    [Parameter(Mandatory = $true)][AllowEmptyCollection()][System.Collections.Generic.List[string]]$Hits,
    [Parameter(Mandatory = $true)][string]$Code
  )
  if (-not $Hits.Contains($Code)) { [void]$Hits.Add($Code) }
}

function Find-DshDiagnosticsDiffSensitiveFields {
  param(
    [AllowNull()]$Object,
    [Parameter(Mandatory = $true)][AllowEmptyCollection()][System.Collections.Generic.List[string]]$Hits,
    [int]$Depth = 0
  )
  if ($Depth -gt $script:MaxDepth) {
    Add-DshDiagnosticsDiffSensitiveHit -Hits $Hits -Code 'DEPTH_LIMIT'
    return
  }
  if ($null -eq $Object) { return }
  if ($Object -is [string]) {
    if (Test-DshDiagnosticsDiffSensitiveString -Value $Object) {
      Add-DshDiagnosticsDiffSensitiveHit -Hits $Hits -Code 'UNSAFE_STRING'
    }
    return
  }
  if (Test-DshDiagnosticsDiffScalar -Value $Object) { return }
  if ($Object -is [System.Collections.IDictionary] -or $Object -is [pscustomobject]) {
    foreach ($name in @(Get-DshDiagnosticsDiffPropertyNames -Object $Object)) {
      $value = Get-DshDiagnosticsDiffProperty -Object $Object -Name $name
      $lower = $name.ToLowerInvariant()
      if (Test-DshDiagnosticsDiffForbiddenName -Name $name) {
        Add-DshDiagnosticsDiffSensitiveHit -Hits $Hits -Code 'FORBIDDEN_FIELD'
        continue
      }
      if ($script:PrivacyFalseFields -contains $lower -and $value -eq $true) {
        Add-DshDiagnosticsDiffSensitiveHit -Hits $Hits -Code 'UNSAFE_PRIVACY_FLAG'
        continue
      }
      if ($lower -in @('issuecodes', 'issuecode', 'conflictcodes', 'conflictcode', 'codes', 'code') -and $null -ne $value) {
        $codeValues = if ($value -is [System.Collections.IEnumerable] -and $value -isnot [string]) { @($value) } else { @($value) }
        foreach ($codeValue in $codeValues) {
          if ($codeValue -isnot [string] -or -not (Test-DshDiagnosticsDiffSafeCode -Value ([string]$codeValue))) {
            Add-DshDiagnosticsDiffSensitiveHit -Hits $Hits -Code 'UNSAFE_CODE_VALUE'
            break
          }
        }
      }
      Find-DshDiagnosticsDiffSensitiveFields -Object $value -Hits $Hits -Depth ($Depth + 1)
    }
    return
  }
  if ($Object -is [System.Collections.IEnumerable]) {
    foreach ($item in @($Object)) {
      Find-DshDiagnosticsDiffSensitiveFields -Object $item -Hits $Hits -Depth ($Depth + 1)
    }
  }
}

function Test-DshDiagnosticsDiffShape {
  param([AllowNull()]$Object)
  if ($null -eq $Object -or $Object -is [string] -or $Object -is [ValueType]) { return $false }
  $kind = [string](Get-DshDiagnosticsDiffProperty -Object $Object -Name 'kind')
  if (-not [string]::IsNullOrWhiteSpace($kind)) { return $script:AllowedKinds -contains $kind }
  $schema = Get-DshDiagnosticsDiffProperty -Object $Object -Name 'schemaVersion'
  $result = [string](Get-DshDiagnosticsDiffProperty -Object $Object -Name 'result')
  return ($null -ne $schema -and $result -in @('PASS', 'PARTIAL', 'FAIL', 'COMPLETE', 'UNAVAILABLE', 'WARN'))
}

function Read-DshDiagnosticsDiffJson {
  param([Parameter(Mandatory = $true)][string]$Path)
  if ([string]::IsNullOrWhiteSpace($Path)) { throw 'INPUT_INVALID' }
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw 'INPUT_INVALID' }
  $item = Get-Item -LiteralPath $Path -Force
  if ($item.Length -gt $script:MaxInputBytes) { throw 'INPUT_INVALID' }
  try {
    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    $value = $raw | ConvertFrom-Json
  } catch {
    throw 'INPUT_INVALID'
  }
  if (-not (Test-DshDiagnosticsDiffShape -Object $value)) { throw 'INPUT_INVALID' }
  return $value
}

function Get-DshDiagnosticsDiffSafeScalar {
  param([Parameter(Mandatory = $true)][string]$Name, [AllowNull()]$Value)
  $lower = $Name.ToLowerInvariant()
  if ($null -eq $Value) {
    if ($lower -eq 'kind' -or $lower -eq 'result' -or $lower -match '(?:status|state|outcome)$' -or $lower -eq 'dshversion') { return $null }
    return $script:SkipScalar
  }
  if ($Value -is [bool]) {
    if ($lower -match '(?:readonly|metadataonly|networkaccessed|toolexecuted|stored|sent|provided|observed|enabled|present|valid|matched|required|changed)$') { return [bool]$Value }
    return $script:SkipScalar
  }
  if ($Value -is [byte] -or $Value -is [int16] -or $Value -is [int32] -or $Value -is [int64] -or $Value -is [decimal] -or $Value -is [double]) {
    if ($lower -eq 'schemaversion' -or $lower -match 'count$') { return [int64]$Value }
    return $script:SkipScalar
  }
  if ($Value -is [string]) {
    $isEnum = $lower -eq 'kind' -or $lower -eq 'result' -or $lower -eq 'dshversion' -or $lower -match '(?:status|state|outcome)$'
    if ($isEnum -and (Test-DshDiagnosticsDiffSafeString -Value $Value)) { return [string]$Value }
  }
  return $script:SkipScalar
}

function Add-DshDiagnosticsDiffFlatEntries {
  param(
    [AllowNull()]$Object,
    [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Path,
    [Parameter(Mandatory = $true)][hashtable]$Map,
    [int]$Depth = 0
  )
  if ($null -eq $Object -or $Depth -gt $script:MaxDepth) { return }
  if ($Object -is [System.Collections.IDictionary] -or $Object -is [pscustomobject]) {
    foreach ($name in @(Get-DshDiagnosticsDiffPropertyNames -Object $Object)) {
      $value = Get-DshDiagnosticsDiffProperty -Object $Object -Name $name
      $nextPath = if ([string]::IsNullOrWhiteSpace($Path)) { '/' + $name } else { $Path + '/' + $name }
      $lower = $name.ToLowerInvariant()
      if ($script:CodeArrayNames -contains $lower) {
        $values = if ($value -is [System.Collections.IEnumerable] -and $value -isnot [string]) { @($value) } else { @($value) }
        $safeValues = @($values | ForEach-Object { [string]$_ } | Where-Object { Test-DshDiagnosticsDiffSafeCode -Value $_ } | Sort-Object -Unique)
        $Map[$nextPath] = @($safeValues)
        continue
      }
      $scalar = Get-DshDiagnosticsDiffSafeScalar -Name $name -Value $value
      if ($scalar -cne $script:SkipScalar) {
        $Map[$nextPath] = $scalar
        continue
      }
      if ($value -is [System.Collections.IDictionary] -or $value -is [pscustomobject]) {
        Add-DshDiagnosticsDiffFlatEntries -Object $value -Path $nextPath -Map $Map -Depth ($Depth + 1)
      }
    }
  }
}

function Get-DshDiagnosticsDiffFlatMap {
  param([Parameter(Mandatory = $true)]$Object)
  $map = @{}
  Add-DshDiagnosticsDiffFlatEntries -Object $Object -Path '' -Map $map
  return $map
}

function Test-DshDiagnosticsDiffEqual {
  param([AllowNull()]$Left, [AllowNull()]$Right)
  $leftJson = $Left | ConvertTo-Json -Depth 12 -Compress
  $rightJson = $Right | ConvertTo-Json -Depth 12 -Compress
  return $leftJson -ceq $rightJson
}

function Compare-DshDiagnosticsDiffMaps {
  param([Parameter(Mandatory = $true)][hashtable]$Before, [Parameter(Mandatory = $true)][hashtable]$After)
  $changes = [System.Collections.Generic.List[object]]::new()
  $paths = @($Before.Keys + $After.Keys | Sort-Object -Unique)
  foreach ($path in $paths) {
    $hasBefore = $Before.ContainsKey($path)
    $hasAfter = $After.ContainsKey($path)
    if (-not $hasBefore) {
      [void]$changes.Add([ordered]@{ path = [string]$path; change = 'added'; before = $null; after = $After[$path] })
    } elseif (-not $hasAfter) {
      [void]$changes.Add([ordered]@{ path = [string]$path; change = 'removed'; before = $Before[$path]; after = $null })
    } elseif (-not (Test-DshDiagnosticsDiffEqual -Left $Before[$path] -Right $After[$path])) {
      [void]$changes.Add([ordered]@{ path = [string]$path; change = 'changed'; before = $Before[$path]; after = $After[$path] })
    }
  }
  return @($changes)
}

function Add-DshDiagnosticsDiffCodeValues {
  param([AllowNull()]$Object, [Parameter(Mandatory = $true)][hashtable]$Sets, [int]$Depth = 0)
  if ($null -eq $Object -or $Depth -gt $script:MaxDepth) { return }
  if ($Object -is [System.Collections.IDictionary] -or $Object -is [pscustomobject]) {
    foreach ($name in @(Get-DshDiagnosticsDiffPropertyNames -Object $Object)) {
      $value = Get-DshDiagnosticsDiffProperty -Object $Object -Name $name
      $lower = $name.ToLowerInvariant()
      if ($lower -in @('issuecodes', 'issuecode', 'codes', 'code')) { $bucket = 'issueCodes' }
      elseif ($lower -in @('conflictcodes', 'conflictcode')) { $bucket = 'conflictCodes' }
      else { $bucket = $null }
      if ($null -ne $bucket) {
        $values = if ($value -is [System.Collections.IEnumerable] -and $value -isnot [string]) { @($value) } else { @($value) }
        foreach ($code in @($values)) {
          if ($code -is [string] -and (Test-DshDiagnosticsDiffSafeCode -Value $code)) { [void]$Sets[$bucket].Add([string]$code) }
        }
      }
      if ($value -is [System.Collections.IDictionary] -or $value -is [pscustomobject]) {
        Add-DshDiagnosticsDiffCodeValues -Object $value -Sets $Sets -Depth ($Depth + 1)
      }
    }
  }
}

function Get-DshDiagnosticsDiffCodeSet {
  param([AllowNull()]$Object, [Parameter(Mandatory = $true)][string]$Bucket)
  $sets = @{
    issueCodes = [System.Collections.Generic.List[string]]::new()
    conflictCodes = [System.Collections.Generic.List[string]]::new()
  }
  Add-DshDiagnosticsDiffCodeValues -Object $Object -Sets $sets
  return @($sets[$Bucket].ToArray() | Sort-Object -Unique)
}

function Get-DshDiagnosticsDiffSetDelta {
  param([AllowEmptyCollection()][object[]]$Before, [AllowEmptyCollection()][object[]]$After)
  $beforeSet = @($Before | ForEach-Object { [string]$_ } | Sort-Object -Unique)
  $afterSet = @($After | ForEach-Object { [string]$_ } | Sort-Object -Unique)
  return [ordered]@{
    before = @($beforeSet)
    after = @($afterSet)
    added = @($afterSet | Where-Object { $_ -notin $beforeSet })
    removed = @($beforeSet | Where-Object { $_ -notin $afterSet })
    changed = (@($afterSet | Where-Object { $_ -notin $beforeSet }).Count -gt 0 -or @($beforeSet | Where-Object { $_ -notin $afterSet }).Count -gt 0)
  }
}

function New-DshDiagnosticsDiffManualReview {
  param([AllowNull()]$Before, [AllowNull()]$After, [int]$SensitiveCount = 0)
  return [ordered]@{
    kind = 'dsh-diagnostics-diff'
    schemaVersion = 1
    result = 'MANUAL_REVIEW'
    comparisonStatus = 'MANUAL_REVIEW'
    inputSummary = [ordered]@{
      beforeKind = if ($null -eq $Before) { $null } else { [string](Get-DshDiagnosticsDiffProperty -Object $Before -Name 'kind') }
      afterKind = if ($null -eq $After) { $null } else { [string](Get-DshDiagnosticsDiffProperty -Object $After -Name 'kind') }
      sensitiveInputObserved = $true
    }
    summary = [ordered]@{ changedCount = 0; addedCount = 0; removedCount = 0; statusChangeCount = 0; issueCodeChangeCount = 0 }
    changes = @()
    statusChanges = @()
    issueChanges = [ordered]@{
      issueCodes = [ordered]@{ before = @(); after = @(); added = @(); removed = @(); changed = $false }
      conflictCodes = [ordered]@{ before = @(); after = @(); added = @(); removed = @(); changed = $false }
    }
    issueCodes = @('SENSITIVE_FIELD_OBSERVED')
    sensitiveFieldCount = $SensitiveCount
    offline = $true
    networkAccessed = $false
    readOnly = $true
    writesReport = $false
    privacy = [ordered]@{
      metadataOnly = $true
      rawMessagesStored = $false
      pathsStored = $false
      rawToolArgumentsStored = $false
      rawToolResultsStored = $false
      credentialsStored = $false
    }
  }
}

function New-DshDiagnosticsDiffInvalid {
  return [ordered]@{
    kind = 'dsh-diagnostics-diff'
    schemaVersion = 1
    result = 'FAIL'
    comparisonStatus = 'INVALID'
    issueCodes = @('INPUT_INVALID')
    changes = @()
    offline = $true
    networkAccessed = $false
    readOnly = $true
    writesReport = $false
    privacy = [ordered]@{ metadataOnly = $true; rawMessagesStored = $false; pathsStored = $false; rawToolArgumentsStored = $false; rawToolResultsStored = $false; credentialsStored = $false }
  }
}

function Write-DshDiagnosticsDiffReport {
  param([Parameter(Mandatory = $true)]$Report, [string]$Path = '')
  $json = $Report | ConvertTo-Json -Depth 30
  if (-not [string]::IsNullOrWhiteSpace($Path)) {
    $parent = Split-Path -Parent ([IO.Path]::GetFullPath($Path))
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    Set-Content -LiteralPath $Path -Value $json -Encoding UTF8
  }
  return $json
}

try {
  $before = Read-DshDiagnosticsDiffJson -Path $BeforePath
  $after = Read-DshDiagnosticsDiffJson -Path $AfterPath
  $hits = [System.Collections.Generic.List[string]]::new()
  Find-DshDiagnosticsDiffSensitiveFields -Object $before -Hits $hits
  Find-DshDiagnosticsDiffSensitiveFields -Object $after -Hits $hits
  if ($hits.Count -gt 0) {
    $manual = New-DshDiagnosticsDiffManualReview -Before $before -After $after -SensitiveCount $hits.Count
    Write-DshDiagnosticsDiffReport -Report $manual -Path $OutputPath
    exit 0
  }

  $beforeMap = Get-DshDiagnosticsDiffFlatMap -Object $before
  $afterMap = Get-DshDiagnosticsDiffFlatMap -Object $after
  $changes = @(Compare-DshDiagnosticsDiffMaps -Before $beforeMap -After $afterMap)
  $statusChanges = @($changes | Where-Object { [string]$_.path -match '(?i)/(?:status|result|state|outcome|startupStatus|correlationStatus)$' })
  $issueBefore = Get-DshDiagnosticsDiffCodeSet -Object $before -Bucket 'issueCodes'
  $issueAfter = Get-DshDiagnosticsDiffCodeSet -Object $after -Bucket 'issueCodes'
  $conflictBefore = Get-DshDiagnosticsDiffCodeSet -Object $before -Bucket 'conflictCodes'
  $conflictAfter = Get-DshDiagnosticsDiffCodeSet -Object $after -Bucket 'conflictCodes'
  $issueDelta = Get-DshDiagnosticsDiffSetDelta -Before $issueBefore -After $issueAfter
  $conflictDelta = Get-DshDiagnosticsDiffSetDelta -Before $conflictBefore -After $conflictAfter
  $issueChangeCount = @($issueDelta.added).Count + @($issueDelta.removed).Count + @($conflictDelta.added).Count + @($conflictDelta.removed).Count
  $changedCount = @($changes | Where-Object { $_.change -eq 'changed' }).Count
  $addedCount = @($changes | Where-Object { $_.change -eq 'added' }).Count
  $removedCount = @($changes | Where-Object { $_.change -eq 'removed' }).Count
  $report = [ordered]@{
    kind = 'dsh-diagnostics-diff'
    schemaVersion = 1
    result = 'PASS'
    comparisonStatus = if ($changes.Count -gt 0) { 'CHANGED' } else { 'UNCHANGED' }
    inputSummary = [ordered]@{
      beforeKind = [string](Get-DshDiagnosticsDiffProperty -Object $before -Name 'kind')
      afterKind = [string](Get-DshDiagnosticsDiffProperty -Object $after -Name 'kind')
      beforeSchemaVersion = Get-DshDiagnosticsDiffProperty -Object $before -Name 'schemaVersion'
      afterSchemaVersion = Get-DshDiagnosticsDiffProperty -Object $after -Name 'schemaVersion'
      sensitiveInputObserved = $false
    }
    summary = [ordered]@{
      changedCount = $changedCount
      addedCount = $addedCount
      removedCount = $removedCount
      statusChangeCount = $statusChanges.Count
      issueCodeChangeCount = $issueChangeCount
    }
    changes = @($changes)
    statusChanges = @($statusChanges)
    issueChanges = [ordered]@{ issueCodes = $issueDelta; conflictCodes = $conflictDelta }
    issueCodes = @()
    sensitiveFieldCount = 0
    offline = $true
    networkAccessed = $false
    readOnly = $true
    writesReport = -not [string]::IsNullOrWhiteSpace($OutputPath)
    privacy = [ordered]@{
      metadataOnly = $true
      rawMessagesStored = $false
      pathsStored = $false
      rawToolArgumentsStored = $false
      rawToolResultsStored = $false
      credentialsStored = $false
    }
  }
  Write-DshDiagnosticsDiffReport -Report $report -Path $OutputPath
  exit 0
} catch {
  $invalid = New-DshDiagnosticsDiffInvalid
  try { Write-DshDiagnosticsDiffReport -Report $invalid -Path $OutputPath } catch { $invalid | ConvertTo-Json -Depth 20 }
  exit 1
}
