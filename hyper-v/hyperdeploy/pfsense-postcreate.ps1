# HyperDeploy PostCreate for pfSense. Runs on the Hyper-V host before first
# boot, with the VM name as its only argument. HyperDeploy creates one NIC on
# Lab-External-vSwitch (the WAN). This adds the lab NIC and sets what
# HyperDeploy can't. Interfaces in pfSense:
#   hn0 = Lab-External-vSwitch (pfSense WAN)
#   hn1 = jumpcloud-lab-net   (pfSense LAN, 192.168.1.1/24 with DHCP)
#
# MANUAL STEP after the first boot: disable TX checksum offload. Hyper-V has
# no per-NIC TX checksumming setting like XO, so do it in pfSense:
# System > Advanced > Networking > "Disable hardware checksum offload", then
# reboot pfSense.
param($name)
$ErrorActionPreference = 'Stop'

# HyperDeploy always turns on dynamic memory
Set-VM -Name $name -StaticMemory -MemoryStartupBytes 2GB -Notes 'Tags: jumpcloud-lab. pfSense 2.9 firewall for the JumpCloud lab - managed by HyperDeploy'

Get-VMNetworkAdapter -VMName $name | Rename-VMNetworkAdapter -NewName wan
Add-VMNetworkAdapter -VMName $name -Name lab -SwitchName jumpcloud-lab-net

# The golden image is copied as-is. Disks can only grow.
$disk = (Get-VMHardDiskDrive -VMName $name)[0].Path
if ((Get-VHD $disk).Size -lt 20GB) { Resize-VHD -Path $disk -SizeBytes 20GB }
