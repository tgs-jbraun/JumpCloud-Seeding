# ---------------------------------------------------------------------------
# pfSense firewall VM
# ---------------------------------------------------------------------------

# pfSense does not use cloud-init; assign interfaces and IPs from the VM
# console on first boot. Interfaces enumerate in the order below:
#   xn0 = LAN   (pfSense WAN)
#   xn1 = jumpcloud-lab-net (pfSense LAN)
#
# MANUAL STEP after the first apply - TX checksum offload must be disabled on
# both interfaces, and the provider has no setting for it:
#   1. In XO, open the pfSense VM > Network tab.
#   2. For each of the two interfaces, turn off "TX checksumming".
#   3. Restart the VM so the change takes effect.
# Repeat if the VM is ever recreated (e.g. after destroy/apply).
resource "xenorchestra_vm" "pfsense" {
  name_label       = "pfSense"
  name_description = "pfSense 2.6 firewall for the JumpCloud lab - managed by Terraform"
  template         = data.xenorchestra_template.pfsense_template.id

  cpus       = 2
  memory_max = 2 * local.gib

  # NIC 0: WAN
  network {
    network_id = data.xenorchestra_network.wan.id
  }

  # NIC 1: lab network
  network {
    network_id = data.xenorchestra_network.jumpcloud_lab_net.id
  }

  disk {
    sr_id      = data.xenorchestra_sr.sr.id
    name_label = "pfSense-disk0"
    size       = 10 * local.gib
  }
}
