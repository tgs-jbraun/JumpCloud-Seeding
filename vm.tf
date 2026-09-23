# Looks up existing Xen Orchestra objects, prints them as outputs, and deploys
# vm_count Ubuntu Server 24.04 cloud-init VMs (2 vCPU, 4 GiB RAM, 10 GiB disk each)
# plus a pfSense 2.6 firewall VM (2 vCPU, 2 GiB RAM, 10 GiB disk).
#
# Usage:
#   copy terraform.tfvars.example terraform.tfvars   # then fill in real values
#   terraform init
#   terraform plan      # review: should show vm_count + 1 VMs to add
#   terraform apply     # creates the VMs
#   terraform output
#
# Layout:
#   providers.tf  Terraform/provider requirements and XOA connection
#   variables.tf  Input variables (values in terraform.tfvars)
#   data.tf       Lookups of existing XO objects
#   vm.tf         Resources: the Ubuntu VMs
#   pfsense.tf    Resources: the pfSense firewall VM
#   outputs.tf    Outputs

# ---------------------------------------------------------------------------
# Ubuntu Server 24.04 VMs
# ---------------------------------------------------------------------------

locals {
  gib = 1024 * 1024 * 1024

  # Last MAC byte for VM 01 (0x0b); VM 02 gets 0x0c, ...
  mac_suffix_start = 11

  # e.g. ubuntu-2404-01 => { lan_mac = "02:1e:00:00:00:0b", lab_mac = "02:63:00:00:00:0b" }
  # Fixed, locally administered MACs let the netplan config below match each
  # NIC reliably, whatever name the guest kernel gives it. They also give
  # stable keys for DHCP reservations.
  ubuntu_vms = {
    for i in range(var.vm_count) : format("%s-%02d", var.vm_name, i + 1) => {
      lan_mac = format("02:1e:00:00:00:%02x", local.mac_suffix_start + i)
      lab_mac = format("02:63:00:00:00:%02x", local.mac_suffix_start + i)
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

  # Netplan v2: DHCP on both NICs. The lab NIC's routes get a higher metric so
  # the LAN default route stays preferred if the lab DHCP server also hands
  # out a gateway. The lab NIC is optional, so boot doesn't wait for a lab
  # DHCP lease (e.g. if pfSense isn't up yet).
  cloud_network_config = yamlencode({
    version = 2
    ethernets = {
      lan = {
        match = { macaddress = each.value.lan_mac }
        dhcp4 = true
      }
      lab = {
        match           = { macaddress = each.value.lab_mac }
        dhcp4           = true
        dhcp4-overrides = { route-metric = 200 }
        optional        = true
      }
    }
  })

  # NIC 0: LAN (DHCP)
  network {
    network_id  = data.xenorchestra_network.wan.id
    mac_address = each.value.lan_mac
  }

  # NIC 1: lab network (DHCP)
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
