# pfSense interfaces enumerate in the order below:
#   hn0 = Lab-External-vSwitch (pfSense WAN)
#   hn1 = jumpcloud-lab-net   (pfSense LAN, 192.168.1.1/24 with DHCP)
#
# MANUAL STEP after the first apply: disable TX checksum offload. Hyper-V has
# no per-NIC TX checksumming setting like XO, so do it in pfSense:
# System > Advanced > Networking > "Disable hardware checksum offload", then
# reboot pfSense.
resource "hyperv_vhd" "pfsense" {
  path   = "${var.vm_path}/pfSense/pfSense.vhdx"
  source = var.pfsense_source_vhdx
  size   = 20 * local.gib
}

resource "hyperv_machine_instance" "pfsense" {
  name  = "pfSense"
  path  = var.vm_path
  notes = "Tags: jumpcloud-lab. pfSense 2.9 firewall for the JumpCloud lab - managed by Terraform"

  generation      = 2
  processor_count = 2

  static_memory        = true
  memory_startup_bytes = 2 * local.gib

  vm_firmware {
    # FreeBSD doesn't boot with Secure Boot on
    enable_secure_boot = "Off"

    boot_order {
      boot_type           = "HardDiskDrive"
      controller_number   = 0
      controller_location = 0
    }
  }

  # NIC 0: Lab-External-vSwitch (WAN)
  network_adaptors {
    name         = "wan"
    switch_name  = data.hyperv_network_switch.default.name
    wait_for_ips = false
  }

  # NIC 1: lab network (LAN)
  network_adaptors {
    name         = "lab"
    switch_name  = hyperv_network_switch.jumpcloud_lab_net.name
    wait_for_ips = false
  }

  hard_disk_drives {
    controller_type     = "Scsi"
    controller_number   = 0
    controller_location = 0
    path                = hyperv_vhd.pfsense.path
  }
}
