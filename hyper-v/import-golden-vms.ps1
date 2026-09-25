# Imports every Hyper-V VM exported under C:\Users\Public\Documents\Hyper-V\Golden, then starts it. Each VM
# is imported as a copy with a new ID, so the golden exports stay untouched
# and the script can run again. VMs whose name already exists are skipped.
#
# Run on the Hyper-V host in an elevated PowerShell:
#   .\import-golden-vms.ps1
#   .\import-golden-vms.ps1 -Source C:\Users\Public\Documents\Hyper-V\Golden -Destination C:\ProgramData\Microsoft\Windows\Hyper-V
param(
  [string]$Source = 'C:\Users\Public\Documents\Hyper-V\Golden',
  [string]$Destination = 'C:\ProgramData\Microsoft\Windows\Hyper-V'
)
$ErrorActionPreference = 'Stop'

# An export keeps the VM config at <VM>\Virtual Machines\<GUID>.vmcx.
# Checkpoint configs live elsewhere and come along with the import.
$configs = Get-ChildItem $Source -Recurse -Filter *.vmcx | Where-Object { $_.Directory.Name -eq 'Virtual Machines' }
if (-not $configs) { throw "No exported VMs found under $Source" }

foreach ($config in $configs) {
  try {
    $report = Compare-VM -Path $config.FullName -Copy -GenerateNewId
    $name = $report.VM.Name

    if (Get-VM -Name $name -ErrorAction SilentlyContinue) {
      Write-Host "Skip ${name}: a VM with this name already exists"
      continue
    }

    # Recheck with this VM's own destination folders
    $dir = Join-Path $Destination $name
    $report = Compare-VM -Path $config.FullName -Copy -GenerateNewId `
      -VirtualMachinePath $dir -SnapshotFilePath $dir -SmartPagingFilePath $dir `
      -VhdDestinationPath (Join-Path $dir 'Virtual Hard Disks')

    # Usually a virtual switch that doesn't exist on this host
    if ($report.Incompatibilities) {
      Write-Warning "Skip ${name}: $($report.Incompatibilities.Message -join '; ')"
      continue
    }

    $vm = Import-VM -CompatibilityReport $report
    Start-VM -VM $vm
    Write-Host "Imported and started $name"
  }
  catch {
    Write-Warning "Failed $($config.FullName): $_"
  }
}
