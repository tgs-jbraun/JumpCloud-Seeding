# Written with AI assistance: Claude Opus 5.5 (Anthropic), using Claude Code.

#Requires -Version 7.4
#Requires -Modules PwshSpectreConsole

# Remote-run copy of import-golden-vms.ps1 with a richer terminal UI. Run it
# on your workstation. It connects to the Hyper-V host over WinRM HTTPS, then
# imports every VM exported under C:\Users\Public\Documents\Hyper-V\Golden on the host, renames it to
# <your name>_JCLab_<name>, and starts it. The golden exports stay
# untouched.
#
# The UI comes from PwshSpectreConsole (MIT license, wraps Spectre.Console).
# It needs PowerShell 7.4 or later on your workstation only. The host needs
# nothing new. One-time setup on the workstation:
#   Install-Module PwshSpectreConsole -Scope CurrentUser
#
# Before it asks for credentials, the script validates the host's SSL
# certificate on the WinRM HTTPS listener (port 5986).
#
# Credentials: the script asks with Get-Credential, which keeps the password
# in a SecureString inside a PSCredential. It never converts the password to
# plain text, writes it anywhere, or accepts it as a plain-text parameter.
# It connects over HTTPS only, and drops its reference to the credential
# once connected.
#
# Examples:
#   .\import-golden-vms-remote.ps1
#   .\import-golden-vms-remote.ps1 -ComputerName hyperv01 -UserName jdoe
#   .\import-golden-vms-remote.ps1 -ComputerName hyperv01.example.local -SkipCertificateCheck   # self-signed cert, no prompt
#   .\import-golden-vms-remote.ps1 -ThrottleLimit 1   # one VM at a time, for spinning disks
#
# If the host's certificate isn't trusted (for example, self-signed), the
# script explains the error and asks whether to skip certificate checks.
# The default answer is No.
param(
  [string]$ComputerName,
  # Pass a PSCredential, or a user name to be prompted for its password
  [pscredential][System.Management.Automation.Credential()]$Credential = [pscredential]::Empty,
  [switch]$SkipCertificateCheck,
  [string]$UserName,
  [string]$Source = 'C:\Users\Public\Documents\Hyper-V\Golden',
  [string]$Destination = 'C:\ProgramData\Microsoft\Windows\Hyper-V',
  # VMs imported at once. Lower it if the host's disks are spinning disks.
  [ValidateRange(1, 16)][int]$ThrottleLimit = 3
)
$ErrorActionPreference = 'Stop'

function Esc($text) { Get-SpectreEscapedText -Text "$text" }

# Pop-culture facts shown in a box below the VM table during the copy, in random
# order. Each line of the file is "sentence | sentence | source".
$factsFile = Join-Path $PSScriptRoot 'pop-culture-facts.txt'
$facts = @(if (Test-Path $factsFile) {
  Get-Content $factsFile | Where-Object { $_ -and $_ -notmatch '^\s*#' } |
    ForEach-Object { $s = $_ -split '\s*\|\s*'; [pscustomobject]@{ One = $s[0]; Two = $s[1] } }
})
if ($facts) { $facts = @($facts | Get-Random -Count $facts.Count) }
$nextFact = 0

# --- Local UI ---------------------------------------------------------------

Write-SpectreFigletText -Text 'JumpCloud Lab' -Alignment Center -Color DeepSkyBlue1
Write-SpectreRule -Title 'Hyper-V golden VM import (remote)' -Alignment Center -Color Grey

# The last technician name and connected host, offered as defaults next run.
# Stored per user on this workstation. No credentials are saved.
$recentFile = Join-Path $env:APPDATA 'JumpCloud-Seeding\remote-import.json'
$recent = try { Get-Content $recentFile -Raw | ConvertFrom-Json } catch { $null }

# Plain text prompts use Read-Host, as the PwshSpectreConsole docs advise.
# Press Enter to keep the value in brackets.
function Read-WithDefault($prompt, $default) {
  if ($default) { $prompt += " [$default]" }
  $answer = Read-Host $prompt
  if ($answer) { $answer } else { $default }
}
if (-not $UserName) { $UserName = Read-WithDefault 'Your name (added to each VM name)' $recent.UserName }
$UserName = $UserName.Trim() -replace '\s+', '-'
if (-not $UserName) { throw 'No name given. Enter a name or pass -UserName.' }
if ($UserName.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0) { throw "Name '$UserName' contains characters not allowed in folder names" }

if (-not $ComputerName) { $ComputerName = Read-WithDefault 'Hyper-V host name or IP' $recent.ComputerName }
if (-not $ComputerName) { throw 'No host given. Enter a host or pass -ComputerName.' }

# 1. Validate the host's SSL certificate before asking for credentials.
# Test-WSMan -UseSSL makes a TLS connection to the WinRM HTTPS listener
# (port 5986) without logging in. Windows rejects the certificate if it's
# self-signed or from an untrusted authority, expired, revoked or
# unverifiable, or issued for a different host name.
$certError = $null
Invoke-SpectreCommandWithStatus -Spinner Dots2 -Title "Checking the SSL certificate on $(Esc $ComputerName):5986" -ScriptBlock {
  try { Test-WSMan -ComputerName $ComputerName -UseSSL | Out-Null }
  catch { $script:certError = ($_ | Out-String).Trim() }
}
$certInvalid = $certError -match 'certificate'
# Any other failure (except "access denied", which comes after the TLS
# handshake) means no certificate could be checked at all
if ($certError -and -not $certInvalid -and $certError -notmatch 'Access is denied') {
  Write-SpectreHost "[red]Couldn't reach a WinRM HTTPS listener on $(Esc $ComputerName):5986 to check its certificate.[/]"
  Write-SpectreHost "[grey]$(Esc $certError)[/]"
  throw 'Not connected. Enable WinRM over HTTPS on the host (see the README), then run the script again.'
}
if (-not $certInvalid) { Write-SpectreHost "[green]SSL certificate is valid[/] for $(Esc $ComputerName)" }

# 2. Invalid certificate: show why and offer to skip the checks, default No
if ($certInvalid -and -not $SkipCertificateCheck) {
  Write-SpectreHost "[yellow]The SSL certificate on $(Esc $ComputerName) isn't valid[/] (usually because it's self-signed):"
  Write-SpectreHost "[grey]$(Esc $certError)[/]"
  Write-SpectreHost 'Skipping the checks keeps the connection encrypted, but no longer verifies that you reached the right host.'
  if ((Read-SpectreConfirm -Message 'Skip certificate checks for this connection?' -DefaultAnswer n) -ne $true) {
    throw 'Not connected: the certificate is not valid. Install a trusted certificate on the host, or rerun with -SkipCertificateCheck.'
  }
  $SkipCertificateCheck = $true
}

# 3. Only now ask for the host's administrator account
if ($Credential -eq [pscredential]::Empty) {
  $Credential = Get-Credential -Message "Administrator account on $ComputerName"
}
$connect = @{ ComputerName = $ComputerName; UseSSL = $true; Credential = $Credential }
if ($SkipCertificateCheck) { $connect.SessionOption = New-PSSessionOption -SkipCACheck -SkipCNCheck -SkipRevocationCheck }
$Session = Invoke-SpectreCommandWithStatus -Spinner Dots2 -Title "Connecting to $(Esc $ComputerName) over HTTPS" -ScriptBlock {
  New-PSSession @connect
}
# The session is authenticated. Drop the credential so it isn't kept around.
# Remove the variable instead of assigning $null: the [Credential()]
# attribute stays on $Credential, and assigning $null prompts again.
Remove-Variable -Name Credential, connect

try {
  # Load the shared host steps into the session. Remote commands run at the
  # session's global scope, so the functions stay defined for later calls.
  Invoke-Command -Session $Session -ScriptBlock ([scriptblock]::Create((Get-Content -Raw (Join-Path $PSScriptRoot 'JCLab.Host.ps1'))))

  $info = $Session.Runspace.ConnectionInfo
  Write-SpectreHost "[green]Connected[/] to [bold]$(Esc $Session.ComputerName)[/] ($(Esc $info.Scheme), $(Esc $info.AuthenticationMechanism))"

  try {
    New-Item -ItemType Directory -Force (Split-Path $recentFile) | Out-Null
    @{ UserName = $UserName; ComputerName = $Session.ComputerName } | ConvertTo-Json | Set-Content $recentFile
  } catch { Write-SpectreHost "[grey]Couldn't save the name and host for next time: $(Esc $_)[/]" }

  $state = Invoke-SpectreCommandWithStatus -Spinner Dots2 -Title 'Reading golden exports on the host' -ScriptBlock {
    Invoke-Command -Session $Session { Get-LabState @args } -ArgumentList $Source, $Destination, $UserName
  }
  $plan = @($state.Plan)
  $missing = @($state.Missing)
  if ($state.Skipped) {
    $state.Skipped | Select-Object Export, Reason | Format-SpectreTable -Title 'Not part of the lab (skipped)' -Color Grey
  }
  $plan | ForEach-Object { [pscustomobject]@{ 'Golden VM' = $_.Name; 'Deploys as' = $_.NewName; 'Folder' = $_.Dir } } |
    Format-SpectreTable -Title 'Deployment plan' -Color DeepSkyBlue1

  # Pre-deployment check
  if ($state.Existing -or $state.Folders) {
    if ($state.Existing) {
      $state.Existing | Select-Object Name, State, Checkpoints, Path | Format-SpectreTable -Title 'You already have these VMs' -Color Yellow
    }
    if ($state.Folders) {
      $state.Folders | ForEach-Object { [pscustomobject]@{ Folder = $_ } } | Format-SpectreTable -Title 'These folders already exist' -Color Yellow
    }

    $cancel = 'Cancel: change nothing'
    $redeploy = 'Redeploy: delete these VMs, disks and folders, then import fresh copies'
    $deployMissing = "Deploy missing: keep the VMs you have, import only the $($missing.Count) missing"
    $delete = 'Delete: delete these VMs, disks and folders, then stop'
    $choices = @($cancel, $redeploy)
    # Offer "Deploy missing" only when you have some of the lab but not all of it
    if ($state.Existing -and $missing) {
      $missing | ForEach-Object { [pscustomobject]@{ 'Missing VM' = $_.NewName } } |
        Format-SpectreTable -Title "Missing from your lab ($($missing.Count) of $($plan.Count))" -Color Yellow
      $choices += $deployMissing
    }
    $choices += $delete
    $answer = Read-SpectreSelection -Message 'Existing lab found. What do you want to do?' -Choices $choices -Color Yellow
    if (-not $answer -or $answer -eq $cancel) { Write-SpectreHost '[grey]Cancelled. Nothing changed.[/]'; return }

    if ($answer -eq $deployMissing) {
      # Keep the existing VMs. Clear only the leftover folders, which belong to
      # missing VMs, so their imports start clean.
      Invoke-Command -Session $Session { Remove-LabFolder @args } -ArgumentList (, @($state.Folders))
      $plan = $missing
      Write-SpectreHost "[green]Keeping your existing VMs.[/] Importing $($missing.Count) missing."
    }
    else {
      Invoke-SpectreCommandWithStatus -Spinner Dots2 -Title 'Deleting existing VMs through Hyper-V' -ScriptBlock {
        foreach ($vm in $state.Existing) {
          Invoke-Command -Session $Session { Remove-LabVM @args } -ArgumentList $vm.Id
          Write-SpectreHost "[red]Deleted[/] $(Esc $vm.Name)"
        }
        Invoke-Command -Session $Session { Remove-LabFolder @args } -ArgumentList (, @($plan.Dir))
      }
      Write-SpectreHost '[green]Existing lab removed.[/]'
      if ($answer -eq $delete) { return }
    }
  }

  # Import. A live view shows the VMs in their own table and the pop-culture
  # fact in a separate box below it, so the fact can't be mistaken for a VM.
  # Results print after the live view ends.
  $results = [System.Collections.Generic.List[object]]::new()
  $vmState = @{}
  foreach ($p in $plan) { $vmState[$p.NewName] = @{ Percent = 0; Status = '[grey]Queued[/]' } }
  $factSeconds = 15
  $fact = $null
  $factShownAt = Get-Date

  # Text progress bar: a line of box-drawing characters filled to the percent
  function Get-Bar($percent, $width) {
    $filled = [int][Math]::Round($width * $percent / 100)
    $line = [string][char]0x2501
    "[deepskyblue1]$($line * $filled)[/][grey]$($line * ($width - $filled))[/] $([int]$percent)%"
  }
  function Show-Fact {
    if (-not $facts) { return }
    $script:fact = $facts[$script:nextFact++ % $facts.Count]
    $script:factShownAt = Get-Date
  }
  function Get-LiveView {
    $table = @(foreach ($p in $plan) {
      $s = $vmState[$p.NewName]
      [pscustomobject]@{ 'Lab VM' = (Esc $p.NewName); Progress = (Get-Bar $s.Percent 30); Status = $s.Status }
    }) | Format-SpectreTable -AllowMarkup -Title 'Deploying lab VMs' -Color DeepSkyBlue1
    if (-not $fact) { return $table }
    # The box's bar counts up to the next fact, 0% to 100% in $factSeconds
    $elapsed = [Math]::Min($factSeconds, ((Get-Date) - $factShownAt).TotalSeconds)
    $factBox = "$(Esc $fact.One)`n[grey]$(Esc $fact.Two)[/]`n`n[grey]Next fact[/]  $(Get-Bar (100 * $elapsed / $factSeconds) 20)" |
      Format-SpectrePanel -Header 'While you wait: did you know?' -Border Rounded -Color Grey
    @($table, $factBox) | Format-SpectreRows
  }

  Show-Fact
  Invoke-SpectreLive -Data (Get-LiveView) -ScriptBlock {
    param([Spectre.Console.LiveDisplayContext]$Context)
    # Sets one VM's row (if named), moves to the next fact when its time is
    # up, and redraws
    function Update-View($name, $percent, $status) {
      if ($name) { $vmState[$name].Percent = $percent; $vmState[$name].Status = $status }
      if ($fact -and ((Get-Date) - $factShownAt).TotalSeconds -ge $factSeconds) { Show-Fact }
      $Context.UpdateTarget((Get-LiveView))
      $Context.Refresh()
    }

    function Add-Failure($n, $err) {
      Update-View $n 100 '[red]Failed[/]'
      $results.Add([pscustomobject]@{ VM = (Esc $n); Result = "[red]Failed[/]: $(Esc $err.Exception.Message)" })
    }

    # Up to $ThrottleLimit imports run on the host at once. The session runs
    # one command at a time, so the script starts each import as a job on the
    # host, then checks every second which ones have finished.
    $queue = [System.Collections.Queue]::new(@($plan))
    $running = @{}   # host job ID -> plan entry
    while ($queue.Count -or $running.Count) {
      while ($queue.Count -and $running.Count -lt $ThrottleLimit) {
        $p = $queue.Dequeue()
        $n = $p.NewName
        try {
          $running[(Invoke-Command -Session $Session { Start-LabImport @args } -ArgumentList $p.ConfigPath, $p.Dir)] = $p
          Update-View $n 10 '[deepskyblue1]Copying VM and disks[/]'
        }
        catch { Add-Failure $n $_ }
      }

      Start-Sleep -Seconds 1
      Update-View
      if (-not $running.Count) { continue }
      $finished = @(Invoke-Command -Session $Session { Get-FinishedLabImport @args } -ArgumentList (, @($running.Keys)))
      foreach ($jobId in $finished) {
        $p = $running[$jobId]
        $running.Remove($jobId)
        $n = $p.NewName
        try {
          Update-View $n 90 '[deepskyblue1]Starting[/]'
          Invoke-Command -Session $Session { Complete-LabImport @args } -ArgumentList $jobId, $n
          Update-View $n 100 '[green]Imported and started[/]'
          $results.Add([pscustomobject]@{ VM = (Esc $n); Result = '[green]Imported and started[/]' })
        }
        catch { Add-Failure $n $_ }
      }
    }
    # Final frame: the VM table only
    $script:fact = $null
    Update-View
  }
  $results | Format-SpectreTable -Title 'Results' -AllowMarkup -Color DeepSkyBlue1
}
finally {
  Remove-PSSession $Session
}
