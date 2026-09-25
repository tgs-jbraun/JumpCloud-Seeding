variable "hyperv_host" {
  type        = string
  description = "Hyper-V host name or IP (WinRM must be enabled)"
}

variable "hyperv_user" {
  type        = string
  description = "Hyper-V host admin username"
}

variable "hyperv_password" {
  type        = string
  description = "Hyper-V host admin password"
  sensitive   = true
}

variable "hyperv_https" {
  type        = bool
  description = "Use WinRM over HTTPS (port 5986) instead of HTTP (port 5985)"
}

variable "hyperv_insecure" {
  type        = bool
  description = "Skip TLS certificate verification (set true for a self-signed WinRM cert)"
}

variable "vm_path" {
  type        = string
  description = "Local folder on the Hyper-V host for VM files and disks, e.g. F:/Hyper-V/Virtual-Hard-Disks"
}

variable "windows_source_vhdx" {
  type        = string
  description = "Path on the host to the sysprepped Windows 11 JumpCloud golden VHDX (stands in for the XO template)"
}

variable "windows_vm_count" {
  type        = number
  description = "Number of Windows 11 JumpCloud test VMs (JUMPCLOUD-TEST-1, -2, ...)"

  validation {
    condition     = var.windows_vm_count >= 0 && floor(var.windows_vm_count) == var.windows_vm_count
    error_message = "windows_vm_count must be a whole number of 0 or more."
  }
}
