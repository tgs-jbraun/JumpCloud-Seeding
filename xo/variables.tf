# Written with AI assistance: Claude Opus 5.5 (Anthropic), using Claude Code.

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
  description = "Name prefix for the Ubuntu VMs, which get a -01, -02, ... suffix"
}

variable "vm_count" {
  type        = number
  description = "Number of Ubuntu VMs to deploy"

  validation {
    condition     = var.vm_count >= 1 && floor(var.vm_count) == var.vm_count
    error_message = "vm_count must be a whole number of 1 or more."
  }
}

variable "vm_ssh_public_key" {
  type        = string
  description = "SSH public key for the default ubuntu user (empty string to skip)"
}

variable "windows_vm_count" {
  type        = number
  description = "Number of Windows 11 JumpCloud test VMs (<windows_vm_prefix>1, 2, ...)"

  validation {
    condition     = var.windows_vm_count >= 0 && floor(var.windows_vm_count) == var.windows_vm_count
    error_message = "windows_vm_count must be a whole number of 0 or more."
  }
}

# Names of things that already exist in XO, and the lab's addressing. Set
# them in terraform.tfvars, so no site's names live in the code.

variable "pool_name" {
  type        = string
  description = "XO pool to deploy into"
}

variable "sr_name" {
  type        = string
  description = "Storage repository for the VM disks"
}

variable "wan_network_name" {
  type        = string
  description = "Network for pfSense's WAN interface"
}

variable "lab_network_name" {
  type        = string
  description = "SDN private network the lab VMs share, created in XO by the SDN Controller"
}

variable "lab_net_cidr" {
  type        = string
  description = "Lab network subnet. pfSense serves DHCP on it."
}

variable "ubuntu_template" {
  type        = string
  description = "XO template for the Ubuntu Server 24.04 cloud-init VMs"
}

variable "pfsense_template" {
  type        = string
  description = "XO template for the pfSense VM"
}

variable "windows_template" {
  type        = string
  description = "XO template for the Windows 11 VMs (keep it free of a vTPM)"
}

variable "windows_vm_prefix" {
  type        = string
  description = "Name prefix for the Windows VMs, which get 1, 2, ... appended"
}
