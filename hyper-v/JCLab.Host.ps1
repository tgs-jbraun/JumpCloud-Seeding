# Written with AI assistance: Claude Opus 5.5 (Anthropic), using Claude Code.

# Steps that run on the Hyper-V host, shared by both import scripts.
# import-golden-vms.ps1 dot-sources this file on the host. The remote script
# loads it into its session on the host once it connects.
$ErrorActionPreference = 'Stop'

# True if $Path is $Dir or inside it
function Test-InFolder($Path, $Dir) {
  $Path -and "$Path\".StartsWith("$Dir\", [StringComparison]::OrdinalIgnoreCase)
}

# Finds the golden exports, the names they will get, and anything of yours
# already there. A VM counts as yours if it has a planned name, or if its
# files live in a planned destination folder: an interrupted run can leave a
# VM there under its golden name, and Hyper-V keeps its files locked until
# the VM itself is deleted.
function Get-LabState($Source, $Destination, $UserName) {
  # An export keeps the VM config at <VM>\Virtual Machines\<GUID>.vmcx.
  # Checkpoint configs live elsewhere and come along with the import.
  $configs = Get-ChildItem $Source -Recurse -Filter *.vmcx | Where-Object { $_.Directory.Name -eq 'Virtual Machines' }

  # Skip folders that a VM registered on this host runs from, such as a
  # permanent VM kept under the golden folder. It isn't a lab export, and
  # Hyper-V keeps its files locked.
  $vmFiles = @(Get-VM | ForEach-Object { $_.ConfigurationLocation; Get-VMHardDiskDrive -VM $_ | ForEach-Object Path })
  $skipped = @()
  $plan = @(foreach ($config in $configs) {
    $folder = $config.Directory.Parent.FullName
    if ($vmFiles | Where-Object { Test-InFolder $_ $folder }) {
      $skipped += [pscustomobject]@{ Export = $config.Directory.Parent.Name; Reason = "A VM on this host runs from $folder" }
      continue
    }
    # Export-VM names the export folder after the VM. Compare-VM would copy
    # the export's files just to report the name, and fails if one is locked.
    $name = $config.Directory.Parent.Name
    $newName = "${UserName}_JCLab_${name}"
    [pscustomobject]@{ ConfigPath = $config.FullName; Name = $name; NewName = $newName; Dir = Join-Path $Destination $newName }
  })
  if (-not $plan) { throw "No exported VMs found under $Source" }

  $existing = @(Get-VM |
    Where-Object { $vm = $_; $plan.NewName -contains $vm.Name -or ($plan | Where-Object { Test-InFolder $vm.Path $_.Dir }) } |
    ForEach-Object { [pscustomobject]@{ Id = $_.Id.Guid; Name = $_.Name; State = "$($_.State)"; Checkpoints = @(Get-VMSnapshot -VM $_).Count; Path = $_.Path } } |
    # VMs without checkpoints first, so the slow checkpoint merges run last
    Sort-Object { $_.Checkpoints -gt 0 })
  # Planned VMs you don't have yet: no VM with that name and no VM in its folder
  $missing = @($plan | Where-Object { $p = $_; -not ($existing | Where-Object { $_.Name -eq $p.NewName -or (Test-InFolder $_.Path $p.Dir) }) })
  # Folders left with no VM in them, for example by a failed import
  $folders = @($plan | Where-Object { $p = $_; (Test-Path $p.Dir) -and -not ($existing | Where-Object { Test-InFolder $_.Path $p.Dir }) } |
    ForEach-Object Dir)

  [pscustomobject]@{ Plan = $plan; Existing = $existing; Missing = $missing; Folders = $folders; Skipped = $skipped }
}

# Deletes one VM through Hyper-V, waiting for each step, then its disk files
function Remove-LabVM($Id) {
  # Waits up to 5 minutes for a Hyper-V state change to finish
  function Wait-Until($what, [scriptblock]$done) {
    $deadline = (Get-Date).AddMinutes(5)
    while (-not (& $done)) {
      if ((Get-Date) -gt $deadline) { throw "Timed out waiting for $what" }
      Start-Sleep -Seconds 2
    }
  }
  $vm = Get-VM -Id $Id
  $disks = @(Get-VMHardDiskDrive -VM $vm | ForEach-Object Path)

  # 1. Power off through Hyper-V. Discard a saved state first.
  if ($vm.State -eq 'Saved') { Remove-VMSavedState -VM $vm }
  if ((Get-VM -Id $Id).State -ne 'Off') {
    Stop-VM -VM $vm -TurnOff -Force
    Wait-Until "$($vm.Name) to turn off" { (Get-VM -Id $Id).State -eq 'Off' }
  }
  # 2. Delete checkpoints and let Hyper-V finish merging them. Remove-VM
  # would otherwise merge them after the VM is gone, keeping the disks locked.
  Get-VMSnapshot -VM $vm | Remove-VMSnapshot -IncludeAllChildSnapshots
  Wait-Until "$($vm.Name) checkpoints to merge" { (Get-VM -Id $Id).OperationalStatus -notcontains 'MergingDisks' }
  # 3. Delete the VM in Hyper-V and confirm it's gone
  Remove-VM -VM $vm -Force
  Wait-Until "$($vm.Name) to be removed" { -not (Get-VM -Id $Id -ErrorAction SilentlyContinue) }
  # 4. Remove-VM keeps the virtual disks, so delete them last
  $disks | Where-Object { $_ -and (Test-Path $_) } | Remove-Item -Force
}

function Remove-LabFolder($Dirs) {
  $Dirs | Where-Object { Test-Path $_ } | Remove-Item -Recurse -Force
}

# Starts a copy import as a native Hyper-V job and returns the job ID. The
# Copy parameter set copies the VM (never registers it in place) and writes
# every file under $Dir. Incompatibilities, usually a virtual switch that
# doesn't exist on this host, fail the job.
function Start-LabImport($ConfigPath, $Dir) {
  (Import-VM -Path $ConfigPath -Copy -GenerateNewId -VirtualMachinePath $Dir -SnapshotFilePath $Dir `
    -SmartPagingFilePath $Dir -VhdDestinationPath (Join-Path $Dir 'Virtual Hard Disks') -AsJob).Id
}

# Returns the IDs of the import jobs that have finished
function Get-FinishedLabImport($JobIds) {
  Get-Job -Id $JobIds | Where-Object { $_.State -in 'Completed', 'Failed', 'Stopped' } | ForEach-Object Id
}

# Collects a finished import, then renames and starts the VM. Throws the
# import's error if it failed.
function Complete-LabImport($JobId, $NewName) {
  $job = Get-Job -Id $JobId
  try { $vm = Receive-Job $job } finally { Remove-Job $job }
  if (-not $vm) { throw 'Import-VM returned no VM' }
  Rename-VM -VM $vm -NewName $NewName
  Start-VM -VM $vm
}
