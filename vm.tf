# Looks up existing Xen Orchestra objects, prints them as outputs, and deploys
# vm_count Ubuntu Server 24.04 cloud-init VMs (2 vCPU, 4 GiB RAM, 10 GiB disk each).
#
# Usage:
#   copy terraform.tfvars.example terraform.tfvars   # then fill in real values
#   terraform init
#   terraform plan      # review: should show vm_count VMs to add
#   terraform apply     # creates the VMs
#   terraform output
#
# Layout:
#   providers.tf  Terraform/provider requirements and XOA connection
#   variables.tf  Input variables (values in terraform.tfvars)
#   data.tf       Lookups of existing XO objects
#   vm.tf         Resources: the Ubuntu VMs
#   outputs.tf    Outputs

# ---------------------------------------------------------------------------
# Ubuntu Server 24.04 VMs
# ---------------------------------------------------------------------------

locals {
  gib = 1024 * 1024 * 1024

  # Static addressing on jumpcloud-lab-net: VM 01 gets .11, 02 gets .12, ...
  lab_net_cidr       = "10.99.0.0/24"
  lab_net_first_host = 11

  # e.g. ubuntu-2404-01 => { lab_ip = "10.99.0.11", ... }
  # Fixed, locally administered MACs let the netplan config below match each
  # NIC reliably, whatever name the guest kernel gives it.
  ubuntu_vms = {
    for i in range(var.vm_count) : format("%s-%02d", var.vm_name, i + 1) => {
      lab_ip  = cidrhost(local.lab_net_cidr, local.lab_net_first_host + i)
      lan_mac = format("02:1e:00:00:00:%02x", local.lab_net_first_host + i)
      lab_mac = format("02:63:00:00:00:%02x", local.lab_net_first_host + i)
    }
  }
}

resource "xenorchestra_vm" "ubuntu" {
  # Keyed by name, so changing vm_count only adds/removes VMs at the end
  for_each = local.ubuntu_vms

  name_label       = each.key
  name_description = "Ubuntu Server 24.04 - managed by Terraform"
  template         = data.xenorchestra_template.ubuntu_template.id
  tags             = ["jumpcloud-lab"]

  cpus       = 2
  memory_max = 4 * local.gib

  cloud_config = "#cloud-config\n${yamlencode(merge(
    {
      hostname         = each.key
      manage_etc_hosts = true
      package_update   = true
    },
    var.vm_ssh_public_key == "" ? {} : { ssh_authorized_keys = [var.vm_ssh_public_key] }
  ))}"

  # Netplan v2: DHCP on the LAN NIC, static IP (no gateway) on the lab NIC
  cloud_network_config = yamlencode({
    version = 2
    ethernets = {
      lan = {
        match = { macaddress = each.value.lan_mac }
        dhcp4 = true
      }
      lab = {
        match     = { macaddress = each.value.lab_mac }
        dhcp4     = false
        addresses = ["${each.value.lab_ip}/${split("/", local.lab_net_cidr)[1]}"]
      }
    }
  })

  # NIC 0: LAN (DHCP)
  network {
    network_id  = data.xenorchestra_network.wan.id
    mac_address = each.value.lan_mac
  }

  # NIC 1: lab network (static)
  network {
    network_id  = data.xenorchestra_network.jumpcloud_lab_net.id
    mac_address = each.value.lab_mac
  }

  disk {
    sr_id      = data.xenorchestra_sr.sr.id
    name_label = "${each.key}-disk0"
    size       = 10 * local.gib
  }
}
