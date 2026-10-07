# Written with AI assistance: Claude Opus 5.5 (Anthropic), using Claude Code.

# Batch converts Hyper-V VHDX disks to dynamic VHDs that XCP-ng can import,
# following https://docs.xcp-ng.org/installation/migrate-to-xcp-ng/#from-hyper-v
# The source VHDX files are left unchanged.
#
# Run it on the Hyper-V host in an elevated Windows PowerShell 5.1.
# Convert-VHD comes with the Hyper-V module, nothing else is needed.
#
# Before converting, remove the Hyper-V integration tools from each guest and
# shut the VM down. Convert-VHD can't read a disk a running VM holds open.
#
# It skips, with the reason, any disk that can't become a working VHD:
#   - larger than 2040 GiB, the VHD format's limit
#   - a 4096-byte logical sector size, which VHD doesn't support
#   - a checkpoint disk (.avhdx). Delete the VM's checkpoints first, so
#     Hyper-V merges them into the .vhdx.
#   - used by a running VM
#
# After converting, in Xen Orchestra: Import > Disk, pick the storage
# repository and upload the VHD. Then create a VM from a template without
# disks, attach the imported disk, start it and install the guest tools.
#
# With -XcpNaming, each VHD is named <UUID>.vhd instead, for copying straight
# into a file-based storage repository and rescanning it. XCP-ng blocks the
# repository if a VHD there has any other name. A mapping.csv next to the
# VHDs records which UUID came from which VHDX.
#
#   .\convert-vhdx-to-vhd.ps1 -VMName DC01, WIN11-01 -Destination C:\XCP-ng
#   .\convert-vhdx-to-vhd.ps1 -Path C:\ProgramData\Microsoft\Windows\Hyper-V -Destination C:\XCP-ng
#   .\convert-vhdx-to-vhd.ps1 -Path 'C:\Users\Public\Documents\Hyper-V\Virtual Hard Disks\DC01.vhdx' -Destination C:\XCP-ng -XcpNaming
[CmdletBinding(DefaultParameterSetName = 'Path')]
param(
  # VHDX files, or folders to search for them (including subfolders)
  [Parameter(Mandatory, ParameterSetName = 'Path')] [string[]]$Path,
  # Or convert every disk attached to these VMs
  [Parameter(Mandatory, ParameterSetName = 'VM')] [string[]]$VMName,
  # Folder for the VHDs
  [Parameter(Mandatory)] [string]$Destination,
  # Name each VHD <UUID>.vhd, for copying straight into a storage repository
  [switch]$XcpNaming,
  # Replace VHDs that already exist in the destination
  [switch]$Force
)
$ErrorActionPreference = 'Stop'
$maxBytes = 2040GB

$sources = @(@(if ($PSCmdlet.ParameterSetName -eq 'VM') {
  Get-VM -Name $VMName | Get-VMHardDiskDrive | ForEach-Object Path
} else {
  foreach ($p in $Path) {
    if (Test-Path $p -PathType Container) { Get-ChildItem $p -Recurse -Include *.vhdx, *.avhdx -File | ForEach-Object FullName }
    else { (Resolve-Path $p).Path }
  }
}) | Select-Object -Unique)
if (-not $sources) { throw 'No VHDX disks found.' }

# Which VM uses each disk, to skip the ones a running VM holds open
$owners = @{}
foreach ($d in Get-VM | Get-VMHardDiskDrive) { $owners[$d.Path] = Get-VM -Id $d.VMId }

New-Item -ItemType Directory -Force $Destination | Out-Null
$i = 0
$results = foreach ($source in $sources) {
  $i++
  Write-Progress -Activity 'Converting VHDX to VHD' -Status "$i of $($sources.Count): $source" -PercentComplete (100 * ($i - 1) / $sources.Count)
  $row = [pscustomobject]@{ Source = $source; VM = ''; SizeGiB = ''; Result = ''; VHD = '' }
  try {
    $vm = $owners[$source]
    if ($vm) { $row.VM = $vm.Name }
    $info = Get-VHD -Path $source
    $row.SizeGiB = [math]::Round($info.Size / 1GB, 1)
    $skip = if ($source -like '*.avhdx' -or $info.VhdType -eq 'Differencing') { 'Checkpoint disk. Delete the VM''s checkpoints first.' }
            elseif ($info.Size -gt $maxBytes) { 'Larger than 2040 GiB, the VHD limit.' }
            elseif ($info.LogicalSectorSize -ne 512) { "Logical sector size $($info.LogicalSectorSize), VHD needs 512." }
            elseif ($vm -and $vm.State -ne 'Off') { "Used by $($vm.Name), which is $($vm.State). Shut it down first." }
    if ($skip) { $row.Result = "Skipped: $skip"; $row; continue }

    $name = if ($XcpNaming) { "$([guid]::NewGuid()).vhd" }
            else { [IO.Path]::GetFileNameWithoutExtension($source) + $(if ($vm) { "_$($vm.Name)" }) + '.vhd' }
    $target = Join-Path $Destination $name
    if ((Test-Path $target) -and -not $Force) { $row.VHD = $target; $row.Result = 'Skipped: the VHD already exists. Use -Force to replace it.'; $row; continue }

    # A dynamic VHD holds only the data the disk uses, so the source file's
    # size is a fair estimate of the space it needs
    $free = (Get-Item $Destination).PSDrive.Free
    if ($free -and $info.FileSize -gt $free) { $row.Result = "Skipped: needs about $([math]::Round($info.FileSize / 1GB, 1)) GiB, $([math]::Round($free / 1GB, 1)) GiB free."; $row; continue }

    if (Test-Path $target) { Remove-Item $target -Force }
    # XCP-ng needs a dynamic VHD. It doesn't import fixed ones.
    Convert-VHD -Path $source -DestinationPath $target -VHDType Dynamic
    $row.VHD = $target
    $row.Result = 'Converted'
  }
  catch { $row.Result = "Failed: $($_.Exception.Message)" }
  $row
}
Write-Progress -Activity 'Converting VHDX to VHD' -Completed

# File names keep the table readable. mapping.csv keeps the full paths.
$results | Format-Table @{ n = 'Disk'; e = { Split-Path $_.Source -Leaf } }, VM, SizeGiB, Result, @{ n = 'VHD'; e = { if ($_.VHD) { Split-Path $_.VHD -Leaf } } } -AutoSize -Wrap
if ($XcpNaming) {
  $mapping = Join-Path $Destination 'mapping.csv'
  $results | Where-Object Result -eq 'Converted' | Select-Object VHD, Source, SizeGiB | Export-Csv $mapping -NoTypeInformation -Append
  Write-Host "Recorded which UUID came from which VHDX in $mapping"
}
$converted = @($results | Where-Object Result -eq 'Converted').Count
Write-Host "$converted of $(@($results).Count) disks converted to $Destination"
