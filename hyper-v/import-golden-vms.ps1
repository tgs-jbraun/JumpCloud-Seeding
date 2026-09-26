# Imports every Hyper-V VM exported under C:\Users\Public\Documents\Hyper-V\Golden, renames it to
# <name>_JumpCloud_Lab_<your name>, then starts it. Each VM is imported as a
# copy with a new ID, so the golden exports stay untouched.
#
# If you already have VMs with those names, it asks whether to redeploy them,
# delete them, or cancel before it changes anything.
#
# Run on the Hyper-V host in an elevated PowerShell. It prompts for your name
# unless you pass -UserName:
#   .\import-golden-vms.ps1
#   .\import-golden-vms.ps1 -UserName jdoe -Source C:\Users\Public\Documents\Hyper-V\Golden -Destination C:\ProgramData\Microsoft\Windows\Hyper-V
param(
  [string]$UserName = (Read-Host 'Your name (added to each VM name)'),
  [string]$Source = 'C:\Users\Public\Documents\Hyper-V\Golden',
  [string]$Destination = 'C:\ProgramData\Microsoft\Windows\Hyper-V'
)
$ErrorActionPreference = 'Stop'

# The name also becomes part of each VM's folder, so keep it path-safe
$UserName = $UserName.Trim() -replace '\s+', '-'
if (-not $UserName) { throw 'A name is required' }
if ($UserName.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0) { throw "Name '$UserName' contains characters not allowed in folder names" }

# An export keeps the VM config at <VM>\Virtual Machines\<GUID>.vmcx.
# Checkpoint configs live elsewhere and come along with the import.
$configs = Get-ChildItem $Source -Recurse -Filter *.vmcx | Where-Object { $_.Directory.Name -eq 'Virtual Machines' }
if (-not $configs) { throw "No exported VMs found under $Source" }

# Name each export will get once imported
$plan = foreach ($config in $configs) {
  $name = (Compare-VM -Path $config.FullName -Copy -GenerateNewId).VM.Name
  [pscustomobject]@{ Config = $config; Name = $name; NewName = "${name}_JumpCloud_Lab_${UserName}" }
}

# Pre-deployment check: VMs you already have with the same names
$existing = @(Get-VM -Name $plan.NewName -ErrorAction SilentlyContinue)
if ($existing) {
  Write-Host "You already have these VMs:"
  $existing | ForEach-Object { Write-Host "  $($_.Name) ($($_.State))" }

  $choices = [System.Management.Automation.Host.ChoiceDescription[]]@(
    New-Object System.Management.Automation.Host.ChoiceDescription '&Redeploy', 'Delete these VMs and their disks, then import fresh copies'
    New-Object System.Management.Automation.Host.ChoiceDescription '&Delete', 'Delete these VMs and their disks, then stop'
    New-Object System.Management.Automation.Host.ChoiceDescription '&Cancel', 'Stop without changing anything'
  )
  $answer = $Host.UI.PromptForChoice('Existing VMs found', 'What do you want to do?', $choices, 2)
  if ($answer -eq 2) { Write-Host 'Cancelled. Nothing was changed.'; return }

  foreach ($vm in $existing) {
    Write-Progress -Activity 'Deleting existing VMs' -Status $vm.Name
    $disks = @(Get-VMHardDiskDrive -VM $vm | ForEach-Object Path)
    Stop-VM -VM $vm -TurnOff -Force -ErrorAction SilentlyContinue
    Remove-VM -VM $vm -Force
    # Remove-VM keeps the disks and folder, so delete them too
    $disks | Where-Object { $_ -and (Test-Path $_) } | Remove-Item -Force
    $dir = Join-Path $Destination $vm.Name
    if (Test-Path $dir) { Remove-Item $dir -Recurse -Force }
    Write-Host "Deleted $($vm.Name)"
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
    $dir = Join-Path $Destination $p.NewName
    $report = Compare-VM -Path $p.Config.FullName -Copy -GenerateNewId `
      -VirtualMachinePath $dir -SnapshotFilePath $dir -SmartPagingFilePath $dir `
      -VhdDestinationPath (Join-Path $dir 'Virtual Hard Disks')

    # Usually a virtual switch that doesn't exist on this host
    if ($report.Incompatibilities) {
      Write-Warning "Skip $($p.Name): $($report.Incompatibilities.Message -join '; ')"
      continue
    }

    Show-Step 'Copying the VM and its disks (can take several minutes)'
    $vm = Import-VM -CompatibilityReport $report
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
