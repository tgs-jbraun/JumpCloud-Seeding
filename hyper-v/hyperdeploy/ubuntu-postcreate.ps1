# HyperDeploy PostCreate for the Ubuntu VMs. Runs on the Hyper-V host before
# first boot, with the VM name (ubuntu-2404-01, ...) as its only argument.
# Sets what HyperDeploy can't: static memory, disk size, a fixed MAC, and the
# cloud-init seed (hostname, SSH key, network).
param($name)
$ErrorActionPreference = 'Stop'

$sshKey = '' # e.g. 'ssh-ed25519 AAAA... you@host'. Empty to skip.

# Same MACs as the XO and Terraform versions: VM 01 = 02:63:00:00:00:0b, ...
$mac = '0263000000{0:X2}' -f (10 + [int]($name -replace '.*-'))
$macColons = (($mac -split '(..)' -ne '') -join ':').ToLower()

# HyperDeploy always turns on dynamic memory
Set-VM -Name $name -StaticMemory -MemoryStartupBytes 4GB -Notes 'Tags: jumpcloud-lab. Ubuntu Server 24.04 - managed by HyperDeploy'
Set-VMNetworkAdapter -VMName $name -StaticMacAddress $mac

# The golden image is copied as-is. Disks can only grow.
$disk = (Get-VMHardDiskDrive -VMName $name)[0].Path
if ((Get-VHD $disk).Size -lt 10GB) { Resize-VHD -Path $disk -SizeBytes 10GB }

# cloud-init NoCloud seed: a small FAT32 disk labelled CIDATA. Native
# cmdlets only, no ISO tooling needed.
$seed = Join-Path (Split-Path $disk) 'cidata.vhdx'
New-VHD -Path $seed -SizeBytes 64MB -Dynamic | Out-Null
$diskNumber = (Mount-VHD -Path $seed -Passthru | Get-Disk).Number
try {
  Initialize-Disk -Number $diskNumber -PartitionStyle MBR
  $letter = (New-Partition -DiskNumber $diskNumber -UseMaximumSize -AssignDriveLetter |
    Format-Volume -FileSystem FAT32 -NewFileSystemLabel CIDATA).DriveLetter

  Set-Content "${letter}:\meta-data" "instance-id: $name`nlocal-hostname: $name"
  Set-Content "${letter}:\user-data" (@(
    '#cloud-config'
    "hostname: $name"
    'manage_etc_hosts: true'
    'package_update: true'
    if ($sshKey) { 'ssh_authorized_keys:'; "  - $sshKey" }
  ) -join "`n")
  # DHCP on the lab NIC, which is the only NIC, so the default route comes
  # from pfSense. Boot waits for a lab DHCP lease.
  Set-Content "${letter}:\network-config" (@(
    'version: 2'
    'ethernets:'
    '  lab:'
    '    match:'
    "      macaddress: '$macColons'"
    '    dhcp4: true'
  ) -join "`n")
}
finally {
  Dismount-VHD -Path $seed
}
Add-VMHardDiskDrive -VMName $name -Path $seed
