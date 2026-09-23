# Looks up existing Xen Orchestra objects, prints them as outputs, and deploys
# one Ubuntu Server 24.04 cloud-init VM (2 vCPU, 4 GiB RAM, 10 GiB disk).
#
# Usage:
#   copy terraform.tfvars.example terraform.tfvars   # then fill in real values
#   terraform init
#   terraform plan      # review: should show 1 VM to add
#   terraform apply     # creates the VM
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

variable "ubuntu_template_name" {
  type        = string
  description = "Name of the Ubuntu Server 24.04 cloud-init template in XO"
}

variable "vm_name" {
  type        = string
  description = "Name label and hostname for the Ubuntu VM"
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

data "xenorchestra_network" "network" {
  name_label = "LAN"
  pool_id    = data.xenorchestra_pool.pool.id
}

data "xenorchestra_vms" "pool_vms" {
  pool_id = data.xenorchestra_pool.pool.id
}

# ---------------------------------------------------------------------------
# Ubuntu Server 24.04 VM
# ---------------------------------------------------------------------------

locals {
  gib = 1024 * 1024 * 1024

  ubuntu_cloud_config = "#cloud-config\n${yamlencode(merge(
    {
      hostname         = var.vm_name
      manage_etc_hosts = true
      package_update   = true
    },
    var.vm_ssh_public_key == "" ? {} : { ssh_authorized_keys = [var.vm_ssh_public_key] }
  ))}"
}

resource "xenorchestra_vm" "ubuntu" {
  name_label       = var.vm_name
  name_description = "Ubuntu Server 24.04 - managed by Terraform"
  template         = data.xenorchestra_template.ubuntu_template.id

  cpus       = 2
  memory_max = 4 * local.gib

  cloud_config = local.ubuntu_cloud_config

  network {
    network_id = data.xenorchestra_network.network.id
  }

  disk {
    sr_id      = data.xenorchestra_sr.sr.id
    name_label = "${var.vm_name}-disk0"
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

output "network" {
  description = "Network for lab VMs"
  value       = data.xenorchestra_network.network
}

output "existing_vms" {
  description = "VMs currently in the pool, with power state"
  value       = [for vm in data.xenorchestra_vms.pool_vms.vms : "${vm.name_label} (${vm.power_state})"]
}

output "ubuntu_vm" {
  description = "The deployed Ubuntu Server 24.04 VM"
  value = {
    id             = xenorchestra_vm.ubuntu.id
    name           = xenorchestra_vm.ubuntu.name_label
    ipv4_addresses = xenorchestra_vm.ubuntu.ipv4_addresses
  }
}
