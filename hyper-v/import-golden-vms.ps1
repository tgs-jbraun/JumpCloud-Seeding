# Imports every Hyper-V VM exported under C:\Users\Public\Documents\Hyper-V\Golden, renames it to
# <name>_JumpCloud_Lab_<your name>, then starts it. Each VM is imported as a
# copy with a new ID, so the golden exports stay untouched.
#
# If you already have VMs with those names, it asks whether to redeploy them,
# delete them, or cancel before it changes anything.
#
# Run it in an elevated PowerShell, either on the Hyper-V host or remotely.
# It prompts for your name unless you pass -UserName.
#
#   Locally, on the Hyper-V host:
#     .\import-golden-vms.ps1
#     .\import-golden-vms.ps1 -UserName jdoe -Source C:\Users\Public\Documents\Hyper-V\Golden -Destination C:\ProgramData\Microsoft\Windows\Hyper-V
#
#   Remotely, over WinRM HTTPS (port 5986). Prompts and the progress bar
#   appear on your machine, and -Source and -Destination are host paths:
#     .\import-golden-vms.ps1 -ComputerName hyperv01 -Credential (Get-Credential)
#     .\import-golden-vms.ps1 -ComputerName hyperv01.example.local -SkipCertificateCheck   # self-signed cert
#
#   Remotely, over a PSSession you already opened. It must be encrypted
#   (HTTPS, Kerberos or NTLM), so Basic auth over HTTP is refused:
#     $s = New-PSSession -ComputerName hyperv01 -UseSSL
#     .\import-golden-vms.ps1 -Session $s
param(
  [string]$UserName = (Read-Host 'Your name (added to each VM name)'),
  [string]$Source = 'C:\Users\Public\Documents\Hyper-V\Golden',
  [string]$Destination = 'C:\ProgramData\Microsoft\Windows\Hyper-V',
  [string]$ComputerName,
  [pscredential]$Credential,
  [switch]$SkipCertificateCheck,
  [System.Management.Automation.Runspaces.PSSession]$Session
)
$ErrorActionPreference = 'Stop'

# The name also becomes part of each VM's folder, so keep it path-safe
$UserName = $UserName.Trim() -replace '\s+', '-'
if (-not $UserName) { throw 'A name is required' }
if ($UserName.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0) { throw "Name '$UserName' contains characters not allowed in folder names" }

# Remote run: send this same script to the host and run it there. It starts
# without -ComputerName or -Session, so on the host it takes the local path below.
if ($ComputerName -or $Session) {
  $ownSession = -not $Session
  if ($ownSession) {
    $connect = @{ ComputerName = $ComputerName; UseSSL = $true }
    if ($Credential) { $connect.Credential = $Credential }
    if ($SkipCertificateCheck) { $connect.SessionOption = New-PSSessionOption -SkipCACheck -SkipCNCheck }
    $Session = New-PSSession @connect
  }
  try {
    $info = $Session.Runspace.ConnectionInfo
    if ($info.AuthenticationMechanism -eq 'Basic' -and $info.Scheme -ne 'https') {
      throw 'Refusing an unencrypted session (Basic auth over HTTP). Connect with -UseSSL instead.'
    }
    Invoke-Command -Session $Session -FilePath $PSCommandPath -ArgumentList $UserName, $Source, $Destination
  }
  finally {
    if ($ownSession) { Remove-PSSession $Session }
  }
  return
}

# An export keeps the VM config at <VM>\Virtual Machines\<GUID>.vmcx.
# Checkpoint configs live elsewhere and come along with the import.
$configs = Get-ChildItem $Source -Recurse -Filter *.vmcx | Where-Object { $_.Directory.Name -eq 'Virtual Machines' }
if (-not $configs) { throw "No exported VMs found under $Source" }

# Name each export will get once imported
$plan = foreach ($config in $configs) {
  $name = (Compare-VM -Path $config.FullName -Copy -GenerateNewId).VM.Name
  [pscustomobject]@{ Config = $config; Name = $name; NewName = "${name}_JumpCloud_Lab_${UserName}" }
}

# Pre-deployment check: VMs you already have with the same names, and
# destination folders left without a VM (for example by a failed import)
$existing = @(Get-VM -Name $plan.NewName -ErrorAction SilentlyContinue)
$folders = @($plan.NewName | Where-Object { $existing.Name -notcontains $_ } |
  ForEach-Object { Join-Path $Destination $_ } | Where-Object { Test-Path $_ })
if ($existing -or $folders) {
  if ($existing) {
    Write-Host "You already have these VMs:"
    $existing | ForEach-Object { Write-Host "  $($_.Name) ($($_.State))" }
  }
  if ($folders) {
    Write-Host "These destination folders already exist:"
    $folders | ForEach-Object { Write-Host "  $_" }
  }

  $choices = [System.Management.Automation.Host.ChoiceDescription[]]@(
    New-Object System.Management.Automation.Host.ChoiceDescription '&Redeploy', 'Delete these VMs, disks and folders, then import fresh copies'
    New-Object System.Management.Automation.Host.ChoiceDescription '&Delete', 'Delete these VMs, disks and folders, then stop'
    New-Object System.Management.Automation.Host.ChoiceDescription '&Cancel', 'Stop without changing anything'
  )
  $answer = $Host.UI.PromptForChoice('Existing lab found', 'What do you want to do?', $choices, 2)
  if ($answer -eq 2) { Write-Host 'Cancelled. Nothing was changed.'; return }

  # Waits up to 5 minutes for a Hyper-V state change to finish
  function Wait-Until($what, [scriptblock]$done) {
    $deadline = (Get-Date).AddMinutes(5)
    while (-not (& $done)) {
      if ((Get-Date) -gt $deadline) { throw "Timed out waiting for $what" }
      Start-Sleep -Seconds 2
    }
  }

  foreach ($vm in $existing) {
    Write-Progress -Activity 'Deleting existing VMs' -Status $vm.Name
    $disks = @(Get-VMHardDiskDrive -VM $vm | ForEach-Object Path)

    # 1. Power off through Hyper-V. A saved state has to be discarded first.
    if ($vm.State -eq 'Saved') { Remove-VMSavedState -VM $vm }
    if ((Get-VM -Id $vm.Id).State -ne 'Off') {
      Stop-VM -VM $vm -TurnOff -Force
      Wait-Until "$($vm.Name) to turn off" { (Get-VM -Id $vm.Id).State -eq 'Off' }
    }

    # 2. Delete checkpoints and let Hyper-V finish merging them. Remove-VM
    # would otherwise merge them after the VM is gone, keeping the disks locked.
    Get-VMSnapshot -VM $vm | Remove-VMSnapshot -IncludeAllChildSnapshots
    Wait-Until "$($vm.Name) checkpoints to merge" { (Get-VM -Id $vm.Id).OperationalStatus -notcontains 'MergingDisks' }

    # 3. Delete the VM in Hyper-V and confirm it's gone
    Remove-VM -VM $vm -Force
    Wait-Until "$($vm.Name) to be removed" { -not (Get-VM -Id $vm.Id -ErrorAction SilentlyContinue) }

    # 4. Remove-VM keeps the virtual disks and folder, so delete them last
    $disks | Where-Object { $_ -and (Test-Path $_) } | Remove-Item -Force
    $dir = Join-Path $Destination $vm.Name
    if (Test-Path $dir) { Remove-Item $dir -Recurse -Force }
    Write-Host "Deleted $($vm.Name)"
  }
  foreach ($folder in $folders) {
    Remove-Item $folder -Recurse -Force
    Write-Host "Deleted folder $folder"
  }
  Write-Progress -Activity 'Deleting existing VMs' -Completed
  if ($answer -eq 1) { return }
}

# Built-in terminal progress bar: one bar across all VMs, the current step below it
$i = 0
function Show-Step($step) {
  Write-Progress -Activity 'Importing golden VMs' -PercentComplete (100 * ($i - 1) / @($plan).Count) `
    -Status "VM $i of $(@($plan).Count): $($p.Name)" -CurrentOperation $step
}

foreach ($p in $plan) {
  $i++
  try {
    Show-Step 'Checking the export'
    # Copy import (never in-place registration), with every file written under
    # this VM's destination folder. Import-VM's Copy parameter set takes these
    # paths directly. Its CompatibilityReport set takes no paths at all.
    $dir = Join-Path $Destination $p.NewName
    $import = @{
      Path                = $p.Config.FullName
      Copy                = $true
      GenerateNewId       = $true
      VirtualMachinePath  = $dir
      SnapshotFilePath    = $dir
      SmartPagingFilePath = $dir
      VhdDestinationPath  = Join-Path $dir 'Virtual Hard Disks'
    }

    # Usually a virtual switch that doesn't exist on this host
    $report = Compare-VM @import
    if ($report.Incompatibilities) {
      Write-Warning "Skip $($p.Name): $($report.Incompatibilities.Message -join '; ')"
      continue
    }

    Show-Step 'Copying the VM and its disks (can take several minutes)'
    $vm = Import-VM @import

    # Confirm nothing still points at the golden export or a default location
    $outside = @($vm.ConfigurationLocation, $vm.SnapshotFileLocation, $vm.SmartPagingFilePath) +
      @(Get-VMHardDiskDrive -VM $vm | ForEach-Object Path) |
      Where-Object { $_ -and -not $_.StartsWith($dir, [StringComparison]::OrdinalIgnoreCase) }
    if ($outside) {
      Remove-VM -VM $vm -Force
      throw "imported files landed outside ${dir}: $($outside -join ', '). Removed the VM."
    }

    Show-Step "Renaming to $($p.NewName) and starting"
    Rename-VM -VM $vm -NewName $p.NewName
    Start-VM -VM $vm
    Write-Host "Imported $($p.Name) and started it as $($p.NewName)"
  }
  catch {
    Write-Warning "Failed $($p.Config.FullName): $_"
  }
}
Write-Progress -Activity 'Importing golden VMs' -Completed
