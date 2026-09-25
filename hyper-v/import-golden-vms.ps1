# Imports every Hyper-V VM exported under C:\Users\Public\Documents\Hyper-V\Golden, renames it to
# <name>_JumpCloud_Lab_<your name>, then starts it. Each VM is imported as a
# copy with a new ID, so the golden exports stay untouched and the script can
# run again. VMs whose new name already exists are skipped.
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

foreach ($config in $configs) {
  try {
    $report = Compare-VM -Path $config.FullName -Copy -GenerateNewId
    $name = $report.VM.Name
    $newName = "${name}_JumpCloud_Lab_${UserName}"

    if (Get-VM -Name $newName -ErrorAction SilentlyContinue) {
      Write-Host "Skip ${name}: $newName already exists"
      continue
    }

    # Recheck with this VM's own destination folders
    $dir = Join-Path $Destination $newName
    $report = Compare-VM -Path $config.FullName -Copy -GenerateNewId `
      -VirtualMachinePath $dir -SnapshotFilePath $dir -SmartPagingFilePath $dir `
      -VhdDestinationPath (Join-Path $dir 'Virtual Hard Disks')

    # Usually a virtual switch that doesn't exist on this host
    if ($report.Incompatibilities) {
      Write-Warning "Skip ${name}: $($report.Incompatibilities.Message -join '; ')"
      continue
    }

    $vm = Import-VM -CompatibilityReport $report
    Rename-VM -VM $vm -NewName $newName
    Start-VM -VM $vm
    Write-Host "Imported $name and started it as $newName"
  }
  catch {
    Write-Warning "Failed $($config.FullName): $_"
  }
}
