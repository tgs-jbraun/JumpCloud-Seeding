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
    # MAC suffixes start at 0x0b, so at most 244 VMs fit before 0xff
    condition     = var.vm_count >= 1 && var.vm_count <= 244 && floor(var.vm_count) == var.vm_count
    error_message = "vm_count must be a whole number from 1 to 244."
  }
}

variable "vm_ssh_public_key" {
  type        = string
  description = "SSH public key for the default ubuntu user (empty string to skip)"
}

variable "windows_vm_count" {
  type        = number
  description = "Number of Windows 11 JumpCloud test VMs (JUMPCLOUD-TEST-1, -2, ...)"

  validation {
    condition     = var.windows_vm_count >= 0 && floor(var.windows_vm_count) == var.windows_vm_count
    error_message = "windows_vm_count must be a whole number of 0 or more."
  }
}
