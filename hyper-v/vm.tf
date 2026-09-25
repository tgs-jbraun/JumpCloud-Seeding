# Hyper-V translation of ../xo. Deploys vm_count Ubuntu Server 24.04 VMs
# (2 vCPU, 4 GiB RAM, 10 GiB disk each), a pfSense 2.6 VM (2 vCPU, 2 GiB RAM,
# 20 GiB disk) and windows_vm_count Windows 11 JumpCloud VMs (4 vCPU, 4 GiB
# RAM, 64 GiB disk each).
#
# Hyper-V has no templates, so each VM boots from a copy of a source VHDX,
# grown to the target size. Growing the disk doesn't grow the partition.
# Ubuntu's cloud-init grows it on first boot. On Windows and pfSense, extend
# it in the guest.
#
# Usage:
#   copy terraform.tfvars.example terraform.tfvars   # then fill in real values
#   terraform init
#   terraform plan      # review: should show the switch, disks, ISOs and VMs to add
#   terraform apply
#   terraform output

locals {
  gib = 1024 * 1024 * 1024

  # The provider reads host paths back with backslashes, so build them that
  # way. Forward slashes make apply fail with "produced an invalid new value".
  vm_path = replace(var.vm_path, "/", "\\")

  # e.g. ubuntu-2404-01 => { lab_mac = "02:63:00:00:00:0b", hyperv_mac = "02630000000B" }
  # Same MACs as the XO deployment. The fixed MAC lets netplan match the NIC
  # and gives a stable key for DHCP reservations on pfSense.
  ubuntu_vms = {
    for i in range(var.vm_count) : format("%s-%02d", var.vm_name, i + 1) => {
      lab_mac    = format("02:63:00:00:00:%02x", 11 + i)
      hyperv_mac = format("0263000000%02X", 11 + i)
    }
  }
}

# Source: ubuntu-24.04-server-cloudimg-amd64.img (QCOW2) from
# https://cloud-images.ubuntu.com/releases/noble/release/
# Convert it to VHDX once on the host before the first apply:
#   qemu-img convert -f qcow2 -O vhdx -o subformat=dynamic ubuntu-24.04-server-cloudimg-amd64.img ubuntu-24.04-server-cloudimg-amd64.vhdx
resource "hyperv_vhd" "ubuntu" {
  for_each = local.ubuntu_vms

  path   = "${local.vm_path}\\${each.key}\\${each.key}.vhdx"
  source = var.ubuntu_source_vhdx
  size   = 10 * local.gib
}

# cloud-init NoCloud seed: the same settings as the XO version, delivered on
# a CIDATA ISO in the VM's DVD drive.
data "archive_file" "ubuntu_cidata" {
  for_each = local.ubuntu_vms

  type        = "zip"
  output_path = "${path.module}/.cidata/${each.key}.zip"

  source {
    filename = "meta-data"
    content  = yamlencode({ instance-id = each.key, local-hostname = each.key })
  }

  source {
    filename = "user-data"
    content = "#cloud-config\n${yamlencode(merge(
      {
        hostname         = each.key
        manage_etc_hosts = true
        package_update   = true
        # Hyper-V KVP daemon: reports the VM's IP to the host, which
        # wait_for_ips below needs. The generic cloud image lacks it.
        packages = ["linux-cloud-tools-virtual"]
      },
      var.vm_ssh_public_key == "" ? {} : { ssh_authorized_keys = [var.vm_ssh_public_key] }
    ))}"
  }

  # Netplan v2: DHCP on the lab NIC, which is the only NIC, so the default
  # route comes from pfSense. Boot waits for a lab DHCP lease.
  source {
    filename = "network-config"
    content = yamlencode({
      version = 2
      ethernets = {
        lab = {
          match = { macaddress = each.value.lab_mac }
          dhcp4 = true
        }
      }
    })
  }
}

resource "hyperv_iso_image" "ubuntu_cidata" {
  for_each = local.ubuntu_vms

  volume_name               = "CIDATA"
  source_zip_file_path      = data.archive_file.ubuntu_cidata[each.key].output_path
  source_zip_file_path_hash = data.archive_file.ubuntu_cidata[each.key].output_sha
  destination_iso_file_path = "${local.vm_path}\\${each.key}\\cidata.iso"
  iso_media_type            = "cdrom"
  iso_file_system_type      = "iso9660|joliet"

  # Wait for the disk copy, which creates the VM folder the ISO goes in
  depends_on = [hyperv_vhd.ubuntu]
}

resource "hyperv_machine_instance" "ubuntu" {
  for_each = local.ubuntu_vms

  name  = each.key
  path  = local.vm_path
  notes = "Tags: jumpcloud-lab. Ubuntu Server 24.04 - managed by Terraform"

  generation      = 2
  processor_count = 2

  static_memory        = true
  memory_startup_bytes = 4 * local.gib

  vm_firmware {
    enable_secure_boot   = "On"
    secure_boot_template = "MicrosoftUEFICertificateAuthority"

    boot_order {
      boot_type           = "HardDiskDrive"
      controller_number   = 0
      controller_location = 0
    }
  }

  # NIC 0: lab network (DHCP from pfSense). Terraform waits for an IP, like
  # expected_ip_cidr in the XO version.
  network_adaptors {
    name                = "lab"
    switch_name         = hyperv_network_switch.jumpcloud_lab_net.name
    dynamic_mac_address = false
    static_mac_address  = each.value.hyperv_mac
    wait_for_ips        = true
  }

  hard_disk_drives {
    controller_type     = "Scsi"
    controller_number   = 0
    controller_location = 0
    path                = hyperv_vhd.ubuntu[each.key].path
  }

  dvd_drives {
    controller_number   = 0
    controller_location = 1
    path                = hyperv_iso_image.ubuntu_cidata[each.key].resolve_destination_iso_file_path
  }
}
