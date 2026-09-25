output "ubuntu_vms" {
  description = "The deployed Ubuntu Server 24.04 VMs, keyed by name"
  value = {
    for name, vm in hyperv_machine_instance.ubuntu : name => {
      lab_mac      = local.ubuntu_vms[name].lab_mac
      ip_addresses = vm.network_adaptors[0].ip_addresses
    }
  }
}

output "pfsense_vm" {
  description = "The deployed pfSense VM"
  value = {
    ip_addresses = flatten(hyperv_machine_instance.pfsense.network_adaptors[*].ip_addresses)
  }
}

output "windows_vms" {
  description = "The deployed Windows 11 JumpCloud VMs, keyed by name"
  value = {
    for name, vm in hyperv_machine_instance.windows : name => {
      ip_addresses = vm.network_adaptors[0].ip_addresses
    }
  }
}
