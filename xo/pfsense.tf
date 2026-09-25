# pfSense doesn't use cloud-init. Assign interfaces and IPs from the VM
# console on first boot. Interfaces enumerate in the order below:
#   xn0 = LAN   (pfSense WAN)
#   xn1 = jumpcloud-lab-net (pfSense LAN)
#
# MANUAL STEP after the first apply: disable TX checksum offload on both
# interfaces. The provider has no setting for it.
#   1. In XO, open the pfSense VM > Network tab.
#   2. For each of the two interfaces, turn off "TX checksumming".
#   3. Restart the VM so the change takes effect.
# Repeat if the VM is ever recreated (e.g. after destroy/apply).
resource "xenorchestra_vm" "pfsense" {
  name_label       = "pfSense"
  name_description = "pfSense 2.6 firewall for the JumpCloud lab - managed by Terraform"
  template         = data.xenorchestra_template.pfsense_template.id
  tags             = ["jumpcloud-lab"]

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
    # Matches the "pfSense 2.6 (Hub)" template's disk (21474836480 bytes).
    # The provider can't read a template's disk size, and disks can't shrink,
    # so update this if the template changes.
    size = 20 * local.gib
  }
}
