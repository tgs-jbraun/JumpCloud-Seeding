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
  description = "Folder on the Hyper-V host for VM files and disks, e.g. D:/Hyper-V (stands in for the my-storage-repository SR)"
}

variable "lan_switch_name" {
  type        = string
  description = "Existing external virtual switch trunked to the LAN; pfSense's WAN adapter is tagged WAN on it"
}

variable "ubuntu_source_vhdx" {
  type        = string
  description = "Path on the host to the Ubuntu Server 24.04 cloud image VHDX (stands in for the XO template)"
}

variable "pfsense_source_vhdx" {
  type        = string
  description = "Path on the host to the pfSense 2.6 golden VHDX (stands in for the XO template)"
}

variable "windows_source_vhdx" {
  type        = string
  description = "Path on the host to the sysprepped Windows 11 JumpCloud golden VHDX (stands in for the XO template)"
}

variable "vm_name" {
  type        = string
  description = "Name prefix for the Ubuntu VMs; each gets a -01, -02, ... suffix"
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
