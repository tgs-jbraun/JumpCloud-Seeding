# Deploys vm_count Ubuntu Server 24.04 cloud-init VMs (2 vCPU, 4 GiB RAM, 10 GiB disk each)
# plus a pfSense 2.6 firewall VM (2 vCPU, 2 GiB RAM, 20 GiB template-default disk)
# and windows_vm_count Windows 11 JumpCloud VMs (4 vCPU, 4 GiB RAM, 64 GiB disk each).
#
# Usage:
#   copy terraform.tfvars.example terraform.tfvars   # then fill in real values
#   terraform init
#   terraform plan      # review: should show vm_count + 1 + windows_vm_count VMs to add
#   terraform apply     # creates the VMs
#   terraform output

locals {
  gib = 1024 * 1024 * 1024

  # jumpcloud-lab-net subnet. pfSense (192.168.1.1) serves DHCP on it.
  lab_net_cidr = "192.168.1.0/24"

  # e.g. ubuntu-2404-01 => { lab_mac = "02:63:00:00:00:0b" }, -02 gets :0c, ...
  # A fixed, locally administered MAC lets the netplan config below match the
  # NIC, whatever name the guest kernel gives it. It also gives a
  # stable key for DHCP reservations on pfSense.
  ubuntu_vms = {
    for i in range(var.vm_count) : format("%s-%02d", var.vm_name, i + 1) => {
      lab_mac = format("02:63:00:00:00:%02x", 11 + i)
    }
  }
}

resource "xenorchestra_vm" "ubuntu" {
  # Keyed by name, so changing vm_count only adds or removes VMs at the end
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

  # Netplan v2: DHCP on the lab NIC, which is the only NIC, so the default
  # route comes from pfSense. Not optional: boot waits for a lab DHCP lease.
  cloud_network_config = yamlencode({
    version = 2
    ethernets = {
      lab = {
        match = { macaddress = each.value.lab_mac }
        dhcp4 = true
      }
    }
  })

  # NIC 0: lab network (DHCP from pfSense)
  network {
    network_id  = data.xenorchestra_network.jumpcloud_lab_net.id
    mac_address = each.value.lab_mac

    # terraform apply waits until the VM reports an address in the lab subnet
    expected_ip_cidr = local.lab_net_cidr
  }

  disk {
    sr_id      = data.xenorchestra_sr.sr.id
    name_label = "${each.key}-disk0"
    size       = 10 * local.gib
  }
}
