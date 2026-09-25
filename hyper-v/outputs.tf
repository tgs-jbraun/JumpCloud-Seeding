output "windows_vms" {
  description = "The deployed Windows 11 JumpCloud VMs, keyed by name"
  value = {
    for name, vm in hyperv_machine_instance.windows : name => {
      ip_addresses = vm.network_adaptors[0].ip_addresses
    }
  }
}
