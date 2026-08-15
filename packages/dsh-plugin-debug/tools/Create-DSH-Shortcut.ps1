[CmdletBinding()]
param([switch]$BaseOnly)

$ErrorActionPreference = 'Stop'
$LauncherRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$PackageRoot = Split-Path -Parent $LauncherRoot
$desktop = [Environment]::GetFolderPath('Desktop')
$shortcutPath = Join-Path $desktop 'DSH Web.lnk'
$scriptPath = Join-Path $PackageRoot 'Start-DSH-Debug.vbs'

if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
  throw "找不到启动入口：$scriptPath"
}
if (Test-Path -LiteralPath $shortcutPath) {
  throw "桌面快捷方式已存在，为避免覆盖没有修改：$shortcutPath"
}

$wsh = New-Object -ComObject WScript.Shell
$shortcut = $wsh.CreateShortcut($shortcutPath)
$shortcut.TargetPath = Join-Path $env:WINDIR 'System32\wscript.exe'
$shortcut.Arguments = "`"$scriptPath`""
$shortcut.WorkingDirectory = $LauncherRoot
$shortcut.Description = '启动 DeepSeek Harness Debug Plugin Web'
$shortcut.IconLocation = "$env:WINDIR\System32\wscript.exe,0"
$shortcut.Save()
Write-Host "已创建桌面快捷方式：$shortcutPath"
