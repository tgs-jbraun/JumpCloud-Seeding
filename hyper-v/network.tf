# Stands in for the XO SDN private network. A Hyper-V Private switch only
# connects VMs on this one host, and the host itself has no adapter on it.
# The HyperDeploy VMs (hyperdeploy/) connect to it by name.
resource "hyperv_network_switch" "jumpcloud_lab_net" {
  name                = "jumpcloud-lab-net"
  notes               = "Isolated JumpCloud lab network - managed by Terraform"
  switch_type         = "Private"
  allow_management_os = false
}
