# Built from the sysprepped Windows 11 JumpCloud golden VHDX, lab network only
# (no LAN NIC), so they get their addresses from pfSense's LAN DHCP.
#
# Names are Hyper-V VM names only. Windows computer names are limited to 15
# characters, so Terraform doesn't set them as hostnames.
#
# vTPM: the provider never adds a vTPM, so these VMs start without one, which
# avoids the Windows 11 vTPM errors seen on XO.
resource "hyperv_vhd" "windows" {
  # JUMPCLOUD-TEST-1, -2, ... Keyed by name, so changing windows_vm_count
  # only adds or removes VMs at the end
  for_each = toset([for i in range(var.windows_vm_count) : "JUMPCLOUD-TEST-${i + 1}"])

  path   = "${local.vm_path}\\${each.key}\\${each.key}.vhdx"
  source = var.windows_source_vhdx
  size   = 64 * local.gib
}

resource "hyperv_machine_instance" "windows" {
  for_each = hyperv_vhd.windows

  name  = each.key
  path  = local.vm_path
  notes = "Tags: jumpcloud-lab. Windows 11 JumpCloud test VM - managed by Terraform"

  # Windows 11 requires UEFI (Generation 2)
  generation      = 2
  processor_count = 4

  static_memory        = true
  memory_startup_bytes = 4 * local.gib

  vm_firmware {
    enable_secure_boot   = "On"
    secure_boot_template = "MicrosoftWindows"

    boot_order {
      boot_type           = "HardDiskDrive"
      controller_number   = 0
      controller_location = 0
    }
  }

  # NIC 0: lab network
  network_adaptors {
    name         = "lab"
    switch_name  = hyperv_network_switch.jumpcloud_lab_net.name
    wait_for_ips = false
  }

  hard_disk_drives {
    controller_type     = "Scsi"
    controller_number   = 0
    controller_location = 0
    path                = each.value.path
  }
}
