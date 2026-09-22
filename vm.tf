provider "xenorchestra" {
  url   = "wss://xo.example.local" # must be ws:// or wss://, or set XOA_URL
  user = var.xoa_user            # or set XOA_USER
  password = var.xoa_password    # or set XOA_PASSWORD
  # username/password authentication is also supported (username/password
  # arguments, or the XOA_USER and XOA_PASSWORD environment variables),
  # and insecure = true skips TLS verification (XOA_INSECURE)
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

data "xenorchestra_pool" "pool" {
  name_label = "my-xcp-pool"
}

data "xenorchestra_template" "vm_template" {
  name_label = "test-fs01"
}

data "xenorchestra_sr" "sr" {
  name_label = "my-storage-repository"
  pool_id    = data.xenorchestra_pool.pool.id
}

data "xenorchestra_network" "network" {
  name_label = "Pool-wide network"
  pool_id    = data.xenorchestra_pool.pool.id
}