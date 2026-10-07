# Written with AI assistance: Claude Opus 5.5 (Anthropic), using Claude Code.

# Runs deploy-macos-vm.zsh on the lab Mac from Windows, over SSH. The menus,
# prompts and spinners appear in this window. The VM's own window opens on
# the Mac's screen.
#
# The Mac needs no copy of this repo. The launcher sends the script, and the
# pop-culture facts it shows, inside the SSH command. The Mac writes them to
# a temporary folder, runs the script and deletes the folder.
#
# Needs the OpenSSH client that ships with Windows 10/11 and Windows Server
# 2019 or later, nothing else. On the Mac: automatic login, Remote Login with
# full disk access for remote users (System Settings > General > Sharing),
# UTM and gum.
#
# The first run makes macOS ask whether SSH may control UTM. That prompt
# appears on the Mac's screen, so click Allow there once. Until then the
# script fails with "Not authorized to send Apple events" (-1743).
#
# Sign-in uses an SSH key from %USERPROFILE%\.ssh. The launcher lists the key
# pairs there. If the Mac doesn't
# accept the key yet, it offers to add the public key to the Mac's
# ~/.ssh/authorized_keys, which asks for the Mac password once. Choose
# "Password only" to skip keys. ssh asks for any password or passphrase
# itself, and the launcher never saves one.
#
# It remembers the Mac, the account and the key for next time in
# %APPDATA%\JumpCloud-Seeding\utm-remote.json.
#
#   .\deploy-macos-vm-remote.ps1
#   .\deploy-macos-vm-remote.ps1 -ComputerName mac-mini.local -User labadmin -UserName jdoe
#   .\deploy-macos-vm-remote.ps1 -IdentityFile $HOME\.ssh\id_ed25519
param(
  [string]$ComputerName,
  # Account on the Mac
  [string]$User,
  # Private key to sign in with. Asks if omitted.
  [string]$IdentityFile,
  # Sign in with the Mac password instead of a key
  [switch]$PasswordOnly,
  # Passed to the zsh script as -n and -g. It asks for them if omitted.
  [string]$UserName,
  [string]$Golden
)
$ErrorActionPreference = 'Stop'

$recentFile = Join-Path $env:APPDATA 'JumpCloud-Seeding\utm-remote.json'
$recent = try { Get-Content $recentFile -Raw | ConvertFrom-Json } catch { $null }
# Site values: the Mac, its account and the golden VM, from settings.json next
# to this script (copy settings.example.json). The last run's answers win.
$settings = try { Get-Content (Join-Path $PSScriptRoot 'settings.json') -Raw | ConvertFrom-Json } catch { $null }
if (-not $Golden) { $Golden = $settings.GoldenVM }

# Press Enter to keep the value in brackets
function Read-WithDefault($prompt, $default) {
  if ($default) { $prompt += " [$default]" }
  $answer = Read-Host $prompt
  if ($answer) { $answer } else { $default }
}
if (-not $ComputerName) { $ComputerName = Read-WithDefault 'Mac host name or IP' $(if ($recent.ComputerName) { $recent.ComputerName } else { $settings.ComputerName }) }
if (-not $User) { $User = Read-WithDefault 'Account on the Mac' $(if ($recent.User) { $recent.User } else { $settings.User }) }
if (-not ($ComputerName -and $User)) { throw 'Enter the Mac and the account.' }
$target = "$User@$ComputerName"

# Pick a key pair from ~/.ssh: a private key with its .pub next to it
$sshDir = Join-Path $HOME '.ssh'
if (-not ($IdentityFile -or $PasswordOnly)) {
  $keys = @(Get-ChildItem (Join-Path $sshDir '*.pub') -ErrorAction SilentlyContinue |
    ForEach-Object { $_.FullName -replace '\.pub$', '' } | Where-Object { Test-Path $_ })
  $choices = @($keys) + 'Password only'
  Write-Host 'Sign in to the Mac with:'
  for ($i = 0; $i -lt $choices.Count; $i++) { Write-Host "  $($i + 1)) $($choices[$i])" }
  $default = [Math]::Max(0, [Array]::IndexOf($choices, $(if ($recent.IdentityFile) { $recent.IdentityFile } else { $choices[0] })))
  $pick = Read-WithDefault 'Number' ($default + 1)
  if ($pick -notmatch '^\d+$' -or [int]$pick -lt 1 -or [int]$pick -gt $choices.Count) { throw "Pick a number from 1 to $($choices.Count)." }
  if ([int]$pick -eq $choices.Count) { $PasswordOnly = $true } else { $IdentityFile = $choices[[int]$pick - 1] }
}

$sshKey = @()
if (-not $PasswordOnly) {
  # Only this key, so ssh doesn't try others first and hit the Mac's limit
  $sshKey = '-i', $IdentityFile, '-o', 'IdentitiesOnly=yes'

  # BatchMode fails instead of prompting, so this only succeeds if the Mac
  # already accepts the key (or the key needs a passphrase ssh can't ask for)
  # (Windows PowerShell 5.1 treats redirected stderr as an error under Stop)
  & { $ErrorActionPreference = 'Continue'; ssh @sshKey -o BatchMode=yes -o ConnectTimeout=15 $target exit 2>$null }
  if ($LASTEXITCODE -ne 0 -and (Read-Host "The Mac didn't accept $IdentityFile. Add its public key to the Mac now? You enter the Mac password once. [Y/n]") -notmatch '^n') {
    # No double quotes (Windows PowerShell 5.1 doesn't escape them for ssh).
    # tr drops the CR that Windows adds to piped lines. grep -xFf skips the
    # key if authorized_keys already has it.
    Get-Content "$IdentityFile.pub" | ssh $target 'umask 077; mkdir -p .ssh; touch .ssh/authorized_keys; tr -d ''\r'' > .ssh/jclab-key.pub; grep -qxFf .ssh/jclab-key.pub .ssh/authorized_keys || cat .ssh/jclab-key.pub >> .ssh/authorized_keys; rm .ssh/jclab-key.pub'
    if ($LASTEXITCODE -ne 0) { throw "Couldn't add the key to the Mac (exit code $LASTEXITCODE)." }
    Write-Host "Added $IdentityFile.pub to ~/.ssh/authorized_keys on the Mac."
  }
}

New-Item -ItemType Directory -Force (Split-Path $recentFile) | Out-Null
@{ ComputerName = $ComputerName; User = $User; IdentityFile = $(if ($PasswordOnly) { 'Password only' } else { $IdentityFile }) } |
  ConvertTo-Json | Set-Content $recentFile

# Base64 of a repo file with Unix line endings. A Windows clone may store
# CRLF, which zsh on the Mac rejects.
function Get-Base64($path) {
  $text = [IO.File]::ReadAllText((Join-Path $PSScriptRoot $path)) -replace "`r`n", "`n"
  [Convert]::ToBase64String([Text.UTF8Encoding]::new($false).GetBytes($text))
}
# Single-quote each value for the Mac's shell
function Quote($s) { "'" + ($s -replace "'", "'\''") + "'" }

$options = @()
if ($UserName) { $options += '-n', (Quote $UserName) }
if ($Golden) { $options += '-g', (Quote $Golden) }

# The same layout as the repo, so the script finds ../hyper-v/pop-culture-facts.txt.
# The folder is deleted whether the script succeeds or not, and its exit code
# comes back through ssh. No double quotes: Windows PowerShell 5.1 doesn't
# escape them for ssh, and mktemp's folder path has no spaces.
$command = @(
  'd=$(mktemp -d) && mkdir $d/utm-qemu $d/hyper-v'
  "printf %s $(Get-Base64 'deploy-macos-vm.zsh') | base64 -D > `$d/utm-qemu/deploy-macos-vm.zsh"
  "printf %s $(Get-Base64 '..\hyper-v\pop-culture-facts.txt') | base64 -D > `$d/hyper-v/pop-culture-facts.txt"
  "zsh `$d/utm-qemu/deploy-macos-vm.zsh $($options -join ' ')"
) -join ' && '
$command += '; s=$?; rm -rf $d; exit $s'

# -t gives the script a terminal, which gum needs for its menus and spinners
ssh -t @sshKey $target $command
if ($LASTEXITCODE -ne 0) {
  Write-Warning "The script on the Mac exited with code $LASTEXITCODE. If it says -1743, click Allow on the Mac's screen, then run this again."
}
exit $LASTEXITCODE
