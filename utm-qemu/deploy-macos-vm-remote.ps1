# Written with AI assistance: Claude Opus 5.5 (Anthropic), using Claude Code.

# Runs deploy-macos-vm.zsh on the lab Mac from Windows, over SSH. The menus,
# prompts and spinners appear in this window. The VM's own window opens on
# the Mac's screen.
#
# Needs the OpenSSH client that ships with Windows 10/11 and Windows Server
# 2019 or later, nothing else. On the Mac: automatic login, Remote Login
# (System Settings > General > Sharing), and a clone of this repo.
#
# The first run makes macOS ask whether SSH may control UTM. That prompt
# appears on the Mac's screen, so click Allow there once. Until then the
# script fails with "Not authorized to send Apple events" (-1743).
#
# It remembers the Mac, the account and the repo path for next time in
# %APPDATA%\JumpCloud-Seeding\utm-remote.json. ssh asks for the password
# itself, and it is never saved.
#
#   .\deploy-macos-vm-remote.ps1
#   .\deploy-macos-vm-remote.ps1 -ComputerName mac-mini.local -User labadmin -UserName jdoe
param(
  [string]$ComputerName,
  # Account on the Mac
  [string]$User,
  # Where the repo is cloned on the Mac, relative to the account's home folder
  # or absolute
  [string]$RepoPath,
  # Passed to the zsh script as -n and -g. It asks for them if omitted.
  [string]$UserName,
  [string]$Golden
)
$ErrorActionPreference = 'Stop'

$recentFile = Join-Path $env:APPDATA 'JumpCloud-Seeding\utm-remote.json'
$recent = try { Get-Content $recentFile -Raw | ConvertFrom-Json } catch { $null }

# Press Enter to keep the value in brackets
function Read-WithDefault($prompt, $default) {
  if ($default) { $prompt += " [$default]" }
  $answer = Read-Host $prompt
  if ($answer) { $answer } else { $default }
}
if (-not $ComputerName) { $ComputerName = Read-WithDefault 'Mac host name or IP' $recent.ComputerName }
if (-not $User) { $User = Read-WithDefault 'Account on the Mac' $recent.User }
if (-not $RepoPath) { $RepoPath = Read-WithDefault 'Repo path on the Mac' $(if ($recent.RepoPath) { $recent.RepoPath } else { 'JumpCloud-Seeding' }) }
if (-not ($ComputerName -and $User -and $RepoPath)) { throw 'Enter the Mac, the account and the repo path.' }

New-Item -ItemType Directory -Force (Split-Path $recentFile) | Out-Null
@{ ComputerName = $ComputerName; User = $User; RepoPath = $RepoPath } | ConvertTo-Json | Set-Content $recentFile

# Single-quote each value for the Mac's shell. SSH commands start in the
# account's home folder, so a relative repo path works as is.
function Quote($s) { "'" + ($s -replace "'", "'\''") + "'" }
$command = @(Quote "$RepoPath/utm-qemu/deploy-macos-vm.zsh")
if ($UserName) { $command += '-n', (Quote $UserName) }
if ($Golden) { $command += '-g', (Quote $Golden) }

# -t gives the script a terminal, which gum needs for its menus and spinners
ssh -t "$User@$ComputerName" ($command -join ' ')
if ($LASTEXITCODE -ne 0) {
  Write-Warning "The script on the Mac exited with code $LASTEXITCODE. If it says -1743, click Allow on the Mac's screen, then run this again."
}
exit $LASTEXITCODE
