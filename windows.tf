# Built from the JumpCloud Windows 11 template, lab network only (no LAN NIC),
# so they get their addresses from pfSense's LAN DHCP.
#
# Names are XO name labels only. Windows computer names are limited to 15
# characters, so these are not applied as hostnames.
#
# vTPM: a vTPM is known to cause errors with Windows 11 VMs on XO, and the
# provider has no setting to remove one. If the template carries a vTPM, each
# clone inherits it, so the VMs are created powered OFF. MANUAL STEP after
# each apply that creates a Windows VM:
#   1. In XO, open the VM > Advanced tab.
#   2. If a vTPM is listed, delete it.
#   3. Start the VM.
# Removing the vTPM from the template itself avoids this step for new VMs.
resource "xenorchestra_vm" "windows" {
  # JUMPCLOUD-TEST-1, -2, ...; keyed by name, so changing windows_vm_count
  # only adds/removes VMs at the end
  for_each = toset([for i in range(var.windows_vm_count) : "JUMPCLOUD-TEST-${i + 1}"])

  name_label       = each.key
  name_description = "Windows 11 JumpCloud test VM - managed by Terraform"
  template         = data.xenorchestra_template.jumpcloud_template.id
  tags             = ["jumpcloud-lab"]

  # Keep the template's firmware (Windows 11 requires UEFI)
  hvm_boot_firmware = data.xenorchestra_template.jumpcloud_template.boot_firmware

  cpus       = 4
  memory_max = 4 * local.gib

  # NIC 0: lab network
  network {
    network_id = data.xenorchestra_network.jumpcloud_lab_net.id
  }

  disk {
    sr_id      = data.xenorchestra_sr.sr.id
    name_label = "${each.key}-disk0"
    size       = 64 * local.gib
  }

  # Create powered off so the vTPM can be removed before first boot (see above)
  power_state = "Halted"

  lifecycle {
    # After the manual start, don't power the VM back off on later applies
    ignore_changes = [power_state]
  }
}
