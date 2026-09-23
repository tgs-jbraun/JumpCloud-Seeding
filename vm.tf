# Looks up existing Xen Orchestra objects, prints them as outputs, and deploys
# vm_count Ubuntu Server 24.04 cloud-init VMs (2 vCPU, 4 GiB RAM, 10 GiB disk each).
#
# Usage:
#   copy terraform.tfvars.example terraform.tfvars   # then fill in real values
#   terraform init
#   terraform plan      # review: should show vm_count VMs to add
#   terraform apply     # creates the VMs
#   terraform output

terraform {
  required_version = ">= 1.3"

  required_providers {
    xenorchestra = {
      source = "vatesfr/xenorchestra"
    }
  }
}

provider "xenorchestra" {
  url      = var.xoa_url
  username = var.xoa_user
  password = var.xoa_password
  insecure = var.xoa_insecure
}

# ---------------------------------------------------------------------------
# Variables - values are set in terraform.tfvars (git-ignored)
# ---------------------------------------------------------------------------

variable "xoa_url" {
  type        = string
  description = "XOA websocket URL (must be ws:// or wss://)"
}

variable "xoa_user" {
  type        = string
  description = "XOA Admin Username"
}

variable "xoa_password" {
  type        = string
  description = "XOA Admin Password"
  sensitive   = true
}

variable "xoa_insecure" {
  type        = bool
  description = "Skip TLS certificate verification (set true for a self-signed XOA cert)"
}

variable "vm_name" {
  type        = string
  description = "Name prefix for the Ubuntu VMs; each gets a -01, -02, ... suffix"
}

variable "vm_count" {
  type        = number
  description = "Number of Ubuntu VMs to deploy"

  validation {
    # Lab IPs start at 10.99.0.11, so at most 244 VMs fit in the /24
    condition     = var.vm_count >= 1 && var.vm_count <= 244 && floor(var.vm_count) == var.vm_count
    error_message = "vm_count must be a whole number from 1 to 244."
  }
}

variable "vm_ssh_public_key" {
  type        = string
  description = "SSH public key for the default ubuntu user (empty string to skip)"
}

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
      lab_ip         = local.ubuntu_vms[name].lab_ip
      ipv4_addresses = vm.ipv4_addresses
    }
  }
}
