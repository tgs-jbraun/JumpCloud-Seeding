# ---------------------------------------------------------------------------
# Outputs
# ---------------------------------------------------------------------------

output "pool" {
  description = "The XCP-ng pool"
  value       = data.xenorchestra_pool.pool
}

output "hosts" {
  description = "Hosts in the pool"
  value       = [for h in data.xenorchestra_hosts.pool_hosts.hosts : h.name_label]
}

output "template" {
  description = "VM template used for lab deployments"
  value       = data.xenorchestra_template.jumpcloud_template
}

output "storage_repository" {
  description = "Storage repository for lab VM disks"
  value       = data.xenorchestra_sr.sr
}

output "networks" {
  description = "Networks available to lab VMs"
  value = {
    servers            = data.xenorchestra_network.servers
    wan            = data.xenorchestra_network.wan
    jumpcloud_lab_net = data.xenorchestra_network.jumpcloud_lab_net
  }
}

output "existing_vms" {
  description = "VMs currently in the pool, with power state"
  value       = [for vm in data.xenorchestra_vms.pool_vms.vms : "${vm.name_label} (${vm.power_state})"]
}

output "ubuntu_vms" {
  description = "The deployed Ubuntu Server 24.04 VMs, keyed by name"
  value = {
    for name, vm in xenorchestra_vm.ubuntu : name => {
      id             = vm.id
      lab_mac        = local.ubuntu_vms[name].lab_mac
      ipv4_addresses = vm.ipv4_addresses
    }
  }
}

output "pfsense_vm" {
  description = "The deployed pfSense VM"
  value = {
    id             = xenorchestra_vm.pfsense.id
    ipv4_addresses = xenorchestra_vm.pfsense.ipv4_addresses
  }
}
