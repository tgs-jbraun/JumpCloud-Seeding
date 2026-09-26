# Written with AI assistance: Claude Opus 5.5 (Anthropic), using Claude Code.

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

output "windows_vms" {
  description = "The deployed Windows 11 JumpCloud VMs, keyed by name"
  value = {
    for name, vm in xenorchestra_vm.windows : name => {
      id             = vm.id
      ipv4_addresses = vm.ipv4_addresses
    }
  }
}
