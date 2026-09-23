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
    condition     = var.vm_count >= 1 && floor(var.vm_count) == var.vm_count
    error_message = "vm_count must be a whole number of at least 1."
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
# Lab network - created and managed by Terraform
# ---------------------------------------------------------------------------

# Private network with no physical uplink (no source PIF / VLAN), so lab
# traffic stays inside XCP-ng.
resource "xenorchestra_network" "jumpcloud_lab_net" {
  name_label       = "jumpcloud-lab-net"
  name_description = "Isolated JumpCloud lab network - managed by Terraform"
  pool_id          = data.xenorchestra_pool.pool.id
}

# ---------------------------------------------------------------------------
# Ubuntu Server 24.04 VMs
# ---------------------------------------------------------------------------

locals {
  gib = 1024 * 1024 * 1024

  # e.g. ubuntu-2404-01, ubuntu-2404-02, ubuntu-2404-03
  ubuntu_vm_names = [for i in range(var.vm_count) : format("%s-%02d", var.vm_name, i + 1)]
}

resource "xenorchestra_vm" "ubuntu" {
  # Keyed by name, so changing vm_count only adds/removes VMs at the end
  for_each = toset(local.ubuntu_vm_names)

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

  # NIC 0: LAN
  network {
    network_id = data.xenorchestra_network.wan.id
  }

  # NIC 1: lab network
  network {
    network_id = xenorchestra_network.jumpcloud_lab_net.id
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
    jumpcloud_lab_net = xenorchestra_network.jumpcloud_lab_net
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
      ipv4_addresses = vm.ipv4_addresses
    }
  }
}
