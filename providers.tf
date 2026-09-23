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
