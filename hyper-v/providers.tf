terraform {
  required_version = ">= 1.5" # import blocks (import-existing.ps1)

  required_providers {
    hyperv = {
      source  = "taliesins/hyperv"
      version = "~> 1.2"
    }
    # Zips the cloud-init seed files for the Ubuntu VMs
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
  }
}

# Connects to the Hyper-V host over WinRM (NTLM auth)
provider "hyperv" {
  host     = var.hyperv_host
  user     = var.hyperv_user
  password = var.hyperv_password
  https    = var.hyperv_https
  port     = var.hyperv_https ? 5986 : 5985
  insecure = var.hyperv_insecure
}
