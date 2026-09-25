# Existing external switch that trunks to the LAN. Fails the plan if it's
# missing. The WAN tag is set on pfSense's WAN adapter.
data "hyperv_network_switch" "lan" {
  name = var.lan_switch_name
}

# Stands in for the XO SDN private network. A Hyper-V Private switch only
# connects VMs on this one host, and the host itself has no adapter on it.
resource "hyperv_network_switch" "jumpcloud_lab_net" {
  name                = "jumpcloud-lab-net"
  notes               = "Isolated JumpCloud lab network - managed by Terraform"
  switch_type         = "Private"
  allow_management_os = false
}
