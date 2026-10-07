# Written with AI assistance: Claude Opus 5.5 (Anthropic), using Claude Code.

data "xenorchestra_pool" "pool" {
  name_label = var.pool_name
}

data "xenorchestra_template" "jumpcloud_template" {
  name_label = var.windows_template
}

data "xenorchestra_template" "ubuntu_template" {
  name_label = var.ubuntu_template
}

data "xenorchestra_template" "pfsense_template" {
  name_label = var.pfsense_template
}

data "xenorchestra_sr" "sr" {
  name_label = var.sr_name
  pool_id    = data.xenorchestra_pool.pool.id
}

data "xenorchestra_network" "wan" {
  name_label = var.wan_network_name
  pool_id    = data.xenorchestra_pool.pool.id
}

# Created in XO by the SDN Controller (spans all hosts in the pool). Looked
# up rather than managed, since the provider cannot create SDN networks.
data "xenorchestra_network" "jumpcloud_lab_net" {
  name_label = var.lab_network_name
  pool_id    = data.xenorchestra_pool.pool.id
}
