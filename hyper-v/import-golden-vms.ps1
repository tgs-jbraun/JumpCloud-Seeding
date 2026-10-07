# Written with AI assistance: Claude Opus 5.5 (Anthropic), using Claude Code.

# Imports every Hyper-V VM exported under -Source, renames it to
# <your name>_JCLab_<name>, then starts it. It imports each VM as a copy
# with a new ID, so the golden exports stay untouched.
#
# If you already have VMs with those names, it asks whether to redeploy them,
# delete them, deploy only the missing ones, or cancel before it changes
# anything.
#
# Each technician's lab gets a Private vSwitch, <your name>_JCLab_vSwitch.
# Before first boot, every adapter a golden VM had on the golden lab switch
# (-LabSwitch) moves there, so different technicians' VMs never share L2.
# Adapters on other switches stay put. Delete removes the Private switch.
#
# Run it on the Hyper-V host in an elevated PowerShell, with JCLab.Host.ps1
# next to it. To run from your workstation, use jclab.py in the repo root.
# It prompts for your name unless you pass -UserName. -Source, -Destination
# and -LabSwitch default to hyper-v\settings.json (copy settings.example.json).
#
#   .\import-golden-vms.ps1
#   .\import-golden-vms.ps1 -UserName jdoe -LabSwitch JCLab-Golden -Source C:\Users\Public\Documents\Hyper-V\Golden -Destination C:\ProgramData\Microsoft\Windows\Hyper-V
#   .\import-golden-vms.ps1 -ThrottleLimit 1   # one VM at a time, for spinning disks
param(
  [string]$UserName = (Read-Host 'Your name (added to each VM name)'),
  # The vSwitch the golden VMs' lab adapters use
  [string]$LabSwitch,
  # Folder of golden exports, and folder for the lab VMs
  [string]$Source,
  [string]$Destination,
  # VMs imported at once. Lower it on spinning disks.
  [ValidateRange(1, 16)][int]$ThrottleLimit = 3
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'JCLab.Host.ps1')

# Site values not passed as parameters come from settings.json
$settingsFile = Join-Path $PSScriptRoot 'settings.json'
$settings = Read-LabSettings $settingsFile 'Source', 'Destination', 'LabSwitch', 'ComputerName', 'AdminUser'
$Source, $Destination, $LabSwitch = foreach ($name in 'Source', 'Destination', 'LabSwitch') {
  $value = (Get-Variable $name).Value
  if (-not $value) { $value = $settings.$name }
  if (-not $value) { throw "Set $name in $settingsFile (copy settings.example.json), or pass -$name." }
  $value
}

# The name also becomes part of each VM's folder, so keep it path-safe
$UserName = $UserName.Trim() -replace '\s+', '-'
if (-not $UserName) { throw 'No name given. Enter a name or pass -UserName.' }
if ($UserName.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0) { throw "Name '$UserName' contains characters not allowed in folder names" }

$state = Get-LabState $Source $Destination $UserName $LabSwitch
$state.Skipped | ForEach-Object { Write-Host "Skipping $($_.Export): $($_.Reason)" }
$plan = $state.Plan

# Pre-deployment check
$answer = $null
if ($state.Existing -or $state.Folders) {
  if ($state.Existing) {
    Write-Host "You already have these VMs:"
    $state.Existing | ForEach-Object { Write-Host "  $($_.Name) ($($_.State), $($_.Checkpoints) checkpoints) in $($_.Path)" }
  }
  if ($state.Folders) {
    Write-Host "These destination folders already exist:"
    $state.Folders | ForEach-Object { Write-Host "  $_" }
  }

  # Offer "Deploy missing" only when you have some of the lab but not all of it
  $options = @(
    @{ Key = 'Redeploy'; Choice = New-Object System.Management.Automation.Host.ChoiceDescription '&Redeploy', 'Delete these VMs, disks and folders, then import fresh copies' }
    if ($state.Existing -and $state.Missing) {
      Write-Host "Missing from your lab ($($state.Missing.Count) of $($plan.Count)):"
      $state.Missing | ForEach-Object { Write-Host "  $($_.NewName)" }
      @{ Key = 'Missing'; Choice = New-Object System.Management.Automation.Host.ChoiceDescription 'Deploy &missing', "Keep the VMs you have. Import only the $($state.Missing.Count) missing ones." }
    }
    @{ Key = 'Delete'; Choice = New-Object System.Management.Automation.Host.ChoiceDescription '&Delete', 'Delete these VMs, disks and folders, then stop' }
    @{ Key = 'Cancel'; Choice = New-Object System.Management.Automation.Host.ChoiceDescription '&Cancel', 'Stop without changing anything' }
  )
  $choices = [System.Management.Automation.Host.ChoiceDescription[]]@($options.Choice)
  $answer = $options[$Host.UI.PromptForChoice('Existing lab found', 'What do you want to do?', $choices, $options.Count - 1)].Key
  if ($answer -eq 'Cancel') { Write-Host 'Cancelled. Nothing changed.'; return }
}

if ($answer -eq 'Missing') {
  # Keep the existing VMs. Clear only the leftover folders, which belong to
  # missing VMs, so their imports start clean.
  Remove-LabFolder $state.Folders
  $plan = $state.Missing
}
elseif ($answer) {
  foreach ($vm in $state.Existing) {
    Write-Progress -Activity 'Deleting existing VMs' -Status $vm.Name
    Remove-LabVM $vm.Id
    Write-Host "Deleted $($vm.Name)"
  }
  # Every VM using these folders is gone now, so nothing holds their files
  Remove-LabFolder $plan.Dir
  Write-Progress -Activity 'Deleting existing VMs' -Completed
  if ($answer -eq 'Delete') {
    Remove-LabSwitch $UserName
    Write-Host "Deleted the lab network $(Get-LabSwitchName $UserName)"
    return
  }
}

New-LabSwitch $UserName

# Import up to $ThrottleLimit VMs at once. When an import finishes, the VM's lab
# adapters move to the Private switch, then it is renamed and started.
$queue = [System.Collections.Queue]::new(@($plan))
$running = @{}   # import job ID -> plan entry
$done = 0
while ($queue.Count -or $running.Count) {
  while ($queue.Count -and $running.Count -lt $ThrottleLimit) {
    $p = $queue.Dequeue()
    try { $running[(Start-LabImport $p.ConfigPath $p.Dir)] = $p }
    catch { Write-Warning "Failed $($p.Name): $_"; $done++ }
  }

  # Built-in terminal progress bar: VMs finished, and the ones copying now
  Write-Progress -Activity 'Importing golden VMs' -PercentComplete (100 * $done / $plan.Count) `
    -Status "$done of $($plan.Count) VMs done, $($running.Count) copying (can take several minutes)" `
    -CurrentOperation (@($running.Values | ForEach-Object Name) -join ', ')

  if (-not $running.Count) { continue }
  Wait-Job -Id @($running.Keys) -Any -Timeout 2 | Out-Null
  foreach ($id in @(Get-FinishedLabImport @($running.Keys))) {
    $p = $running[$id]
    $running.Remove($id)
    $done++
    try {
      Complete-LabImport $id $p.NewName $UserName $LabSwitch
      Write-Host "Imported $($p.Name) and started it as $($p.NewName) on $(Get-LabSwitchName $UserName)"
    }
    catch { Write-Warning "Failed $($p.Name): $_" }
  }
}
Write-Progress -Activity 'Importing golden VMs' -Completed
