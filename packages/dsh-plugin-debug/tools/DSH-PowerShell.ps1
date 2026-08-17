Set-StrictMode -Version Latest

function Get-DshPowerShellPath {
  <#
    Resolve the PowerShell host used by nested DSH fixtures and launchers.
    The standalone harness passes DSH_STANDALONE_CHILD_HOST explicitly so a
    machine with a broken Windows PowerShell shim can still exercise the
    package with the same bundled pwsh runtime as the parent process.
  #>
  $explicit = [string]$env:DSH_STANDALONE_CHILD_HOST
  if (-not [string]::IsNullOrWhiteSpace($explicit) -and (Test-Path -LiteralPath $explicit -PathType Leaf)) {
    return $explicit
  }

  if ($PSVersionTable.PSEdition -eq 'Core') {
    $current = Join-Path $PSHOME 'pwsh.exe'
    if (Test-Path -LiteralPath $current -PathType Leaf) { return $current }
  }

  $pwsh = Get-Command pwsh.exe -ErrorAction SilentlyContinue
  if ($null -ne $pwsh -and (Test-Path -LiteralPath $pwsh.Source -PathType Leaf)) {
    return $pwsh.Source
  }

  $powershell = Get-Command powershell.exe -ErrorAction SilentlyContinue
  if ($null -ne $powershell -and (Test-Path -LiteralPath $powershell.Source -PathType Leaf)) {
    return $powershell.Source
  }

  throw 'PowerShell host is required but neither pwsh.exe nor powershell.exe was found'
}
