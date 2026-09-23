# Read-only discovery config: looks up existing Xen Orchestra objects and
# prints them as outputs. No resources are created, changed, or destroyed.
#
# Usage:
#   copy terraform.tfvars.example terraform.tfvars   # then fill in real values
#   terraform init
#   terraform plan      # shows the outputs that would be read
#   terraform refresh   # or: terraform apply (no resources, so nothing changes)
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

# ---------------------------------------------------------------------------
# Lookups - each one fails the plan if the named object is not visible
# ---------------------------------------------------------------------------

data "xenorchestra_pool" "pool" {
  name_label = "my-xcp-pool"
}

data "xenorchestra_hosts" "pool_hosts" {
  pool_id = data.xenorchestra_pool.pool.id
}

data "xenorchestra_template" "vm_template" {
  name_label = "Windows 11 OOBE"
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
  value       = data.xenorchestra_template.vm_template
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
