[CmdletBinding()]
param(
  [ValidateSet('public', 'private')]
  [string]$Visibility = '',
  [string]$RepositoryName = 'dsh-plugin-debug',
  [switch]$SkipPush
)

$ErrorActionPreference = 'Stop'
Set-Location -LiteralPath $PSScriptRoot

function Require-Command {
  param([Parameter(Mandatory = $true)][string]$Name)
  if ($null -eq (Get-Command $Name -ErrorAction SilentlyContinue)) {
    throw "Required command is missing: $Name"
  }
}

function Ask-Yes {
  param([Parameter(Mandatory = $true)][string]$Question)
  $answer = Read-Host "$Question (yes/no)"
  return $answer.Trim().ToLowerInvariant() -eq 'yes'
}

function Invoke-CheckedNative {
  param(
    [Parameter(Mandatory = $true)][string]$Command,
    [Parameter(Mandatory = $true)][string[]]$Arguments
  )
  & $Command @Arguments
  if ($LASTEXITCODE -ne 0) {
    throw "$Command failed with exit code $LASTEXITCODE"
  }
}

Require-Command 'git'
Require-Command 'gh'

gh auth status --hostname github.com *> $null
if ($LASTEXITCODE -ne 0) {
  Write-Host 'GitHub CLI is not authenticated. A browser login will be opened; do not enter a GitHub password into this terminal.' -ForegroundColor Yellow
  & gh auth login --hostname github.com --git-protocol https --web
  if ($LASTEXITCODE -ne 0) { throw "gh auth login failed with exit code $LASTEXITCODE" }
}

Invoke-CheckedNative -Command 'gh' -Arguments @('auth', 'status', '--hostname', 'github.com')
$account = (& gh api user --jq '.login').Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($account)) {
  throw 'Could not determine the authenticated GitHub account.'
}
Write-Host "Authenticated GitHub account: $account" -ForegroundColor Cyan

if (-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot '.git') -PathType Container)) {
  Invoke-CheckedNative -Command 'git' -Arguments @('init')
  Invoke-CheckedNative -Command 'git' -Arguments @('branch', '-M', 'main')
}

$configuredName = (git config --local user.name 2>$null).Trim()
if ([string]::IsNullOrWhiteSpace($configuredName)) {
  $configuredName = Read-Host "Git commit display name (default: $account)"
  if ([string]::IsNullOrWhiteSpace($configuredName)) { $configuredName = $account }
  Invoke-CheckedNative -Command 'git' -Arguments @('config', '--local', 'user.name', $configuredName)
}

$configuredEmail = (git config --local user.email 2>$null).Trim()
if ([string]::IsNullOrWhiteSpace($configuredEmail)) {
  $configuredEmail = Read-Host 'Git commit email (a GitHub noreply address is acceptable)'
  if ([string]::IsNullOrWhiteSpace($configuredEmail)) { throw 'A Git commit email is required.' }
  Invoke-CheckedNative -Command 'git' -Arguments @('config', '--local', 'user.email', $configuredEmail)
}

Write-Host 'Running local build and tests...' -ForegroundColor Cyan
Invoke-CheckedNative -Command 'npm' -Arguments @('run', 'check')

Invoke-CheckedNative -Command 'git' -Arguments @('add', '-A')
$stagedFiles = @(git diff --cached --name-only)
if ($stagedFiles.Count -eq 0) { throw 'There are no staged changes to publish.' }

Write-Host ''
Write-Host 'The following files are staged for the first or next local commit:' -ForegroundColor Cyan
git status --short
Invoke-CheckedNative -Command 'git' -Arguments @('diff', '--cached', '--check')
git diff --cached --stat

if (-not (Ask-Yes 'Confirm the staged content contains no passwords, tokens, private logs, or temporary files and create a local commit')) {
  Write-Host 'Stopped before commit. Staged content remains local.' -ForegroundColor Yellow
  exit 0
}

$commitMessage = if ([string]::IsNullOrWhiteSpace((git log -1 --format='%H' 2>$null))) {
  'feat: combine DSH debug plugin'
} else {
  'chore: update DSH debug plugin'
}
Invoke-CheckedNative -Command 'git' -Arguments @('commit', '-m', $commitMessage)

if ([string]::IsNullOrWhiteSpace($Visibility)) {
  $Visibility = Read-Host 'GitHub repository visibility (public/private)'
}
if ($Visibility -notin @('public', 'private')) { throw 'Visibility must be public or private.' }
if ($RepositoryName -notmatch '^[A-Za-z0-9_.-]+$') { throw 'RepositoryName contains unsupported characters.' }

$origin = (git remote get-url origin 2>$null).Trim()
if (-not [string]::IsNullOrWhiteSpace($origin)) {
  Write-Host "Using existing origin: $origin" -ForegroundColor Yellow
} else {
  if (-not (Ask-Yes "Create a $Visibility GitHub repository named $RepositoryName under $account")) {
    Write-Host 'Stopped before creating a remote repository. The local commit is retained.' -ForegroundColor Yellow
    exit 0
  }
  Invoke-CheckedNative -Command 'gh' -Arguments @('repo', 'create', $RepositoryName, "--$Visibility", '--source', '.', '--remote', 'origin')
}

git remote -v
Invoke-CheckedNative -Command 'gh' -Arguments @('repo', 'view', "$account/$RepositoryName")

if ($SkipPush) {
  Write-Host 'Skipped push because -SkipPush was supplied.' -ForegroundColor Yellow
  exit 0
}
if (-not (Ask-Yes 'Confirm the remote account, repository name, and visibility are correct and push main')) {
  Write-Host 'Stopped before push. The local commit and remote repository, if created, remain unchanged.' -ForegroundColor Yellow
  exit 0
}

Invoke-CheckedNative -Command 'git' -Arguments @('push', '-u', 'origin', 'main')
Write-Host "Published $RepositoryName to GitHub." -ForegroundColor Green
