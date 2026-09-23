# ---------------------------------------------------------------------------
# Lookups - each one fails the plan if the named object is not visible
# ---------------------------------------------------------------------------

data "xenorchestra_pool" "pool" {
  name_label = "my-xcp-pool"
}

data "xenorchestra_hosts" "pool_hosts" {
  pool_id = data.xenorchestra_pool.pool.id
}

data "xenorchestra_template" "jumpcloud_template" {
  name_label = "Windows 11 JumpCloud - Template"
}

data "xenorchestra_template" "ubuntu_template" {
  name_label = "Ubuntu 24.04 Cloud-Init (Hub)"
}

data "xenorchestra_template" "pfsense_template" {
  name_label = "pfSense 2.6 (Hub)"
}

data "xenorchestra_sr" "sr" {
  name_label = "my-storage-repository"
  pool_id    = data.xenorchestra_pool.pool.id
}

data "xenorchestra_network" "servers" {
  name_label = "Servers"
  pool_id    = data.xenorchestra_pool.pool.id
}

data "xenorchestra_network" "wan" {
  name_label = "LAN"
  pool_id    = data.xenorchestra_pool.pool.id
}

data "xenorchestra_vms" "pool_vms" {
  pool_id = data.xenorchestra_pool.pool.id
}

# ---------------------------------------------------------------------------
# Lab network - existing XO SDN Controller private network
# ---------------------------------------------------------------------------

# Created in XO by the SDN Controller (spans all hosts in the pool). Looked
# up rather than managed, since the provider cannot create SDN networks.
data "xenorchestra_network" "jumpcloud_lab_net" {
  name_label = "jumpcloud-lab-net"
  pool_id    = data.xenorchestra_pool.pool.id
}
