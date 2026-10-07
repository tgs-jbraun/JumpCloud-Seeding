# Xen Orchestra

The [`xo/`](../xo) folder deploys the lab on XCP-ng with Terraform and the `vatesfr/xenorchestra` provider.

## What it deploys

| VM | Template | CPU / RAM / disk | Network |
|---|---|---|---|
| `<vm_name>-01` to `-03` | `ubuntu_template` | 2 vCPU, 4 GiB, 10 GiB | `lab_network_name`, DHCP from pfSense |
| `pfSense` | `pfsense_template` | 2 vCPU, 2 GiB, 20 GiB | `wan_network_name` (WAN) and `lab_network_name` (LAN) |
| `<windows_vm_prefix>1` to `3` | `windows_template` | 4 vCPU, 4 GiB, 64 GiB | `lab_network_name`, DHCP from pfSense |

All VMs carry the `jumpcloud-lab` tag. Disks go on the `sr_name` storage repository in the `pool_name` pool. Names in code font are variables in `terraform.tfvars`.

The lab network (`lab_network_name`, subnet `lab_net_cidr`) is an SDN private network created in XO by the SDN Controller, so it spans every host in the pool. Terraform looks it up, since the provider can't create SDN networks. pfSense serves DHCP on it from the subnet's first address.

## Run it

```bash
cd xo
copy terraform.tfvars.example terraform.tfvars
terraform init
terraform plan
terraform apply
```

Fill in `terraform.tfvars` before `plan`. Git ignores it, because it holds the XO password and your site's names. `terraform.tfvars.example` shows every variable with placeholder values.

| Variable | Meaning |
|---|---|
| `xoa_url` | XO websocket URL, `ws://` or `wss://` |
| `xoa_user`, `xoa_password` | XO admin account |
| `xoa_insecure` | `true` to skip TLS checks, for a self-signed XO certificate |
| `vm_name` | Prefix for the Ubuntu VMs, which get `-01`, `-02`, ... |
| `vm_count` | Number of Ubuntu VMs |
| `vm_ssh_public_key` | SSH key for the default `ubuntu` user, or `""` to skip |
| `windows_vm_count`, `windows_vm_prefix` | Number of Windows 11 VMs, and their name prefix |
| `pool_name`, `sr_name` | XO pool and storage repository |
| `wan_network_name`, `lab_network_name` | Networks for pfSense's WAN and for the lab |
| `lab_net_cidr` | Lab network subnet |
| `ubuntu_template`, `pfsense_template`, `windows_template` | XO templates for the three kinds of VM |

`terraform plan` should show `vm_count` + 1 + `windows_vm_count` VMs to add.

## How the VMs are set up

- **Ubuntu:** cloud-init sets the host name and adds the SSH key. Each VM's lab NIC gets a fixed, locally administered MAC address (`02:63:00:00:00:0b`, `:0c`, ...). Netplan matches the NIC by that MAC, whatever name the guest kernel gives it, and pfSense can use it for DHCP reservations. `terraform apply` waits until each VM reports an address in 192.168.1.0/24, so it waits for pfSense.
- **Windows:** keeps the template's UEFI firmware, which Windows 11 requires. The names are XO labels only, because Windows computer names are limited to 15 characters.
- **pfSense:** its disk matches the template's 21474836480 bytes. The provider can't read a template's disk size, and disks can't shrink, so update it if the template changes.

## Manual steps

**pfSense interfaces.** pfSense doesn't use cloud-init. Assign interfaces and IP addresses from the VM console on first boot. They enumerate in this order:

- `xn0`: `LAN`, the pfSense WAN
- `xn1`: `jumpcloud-lab-net`, the pfSense LAN

**pfSense TX checksum offload.** The provider has no setting for it. After the first apply, and again whenever the VM is recreated:

1. In XO, open the pfSense VM's Network tab.
2. Turn off "TX checksumming" on both interfaces.
3. Restart the VM.

**No vTPM on the Windows template.** A vTPM causes errors with Windows 11 VMs on XO, and the provider can't remove one. The clones inherit the template's vTPM and start straight after creation, so keep the template itself free of a vTPM (XO > template > Advanced tab).

_Written with AI assistance: Claude Opus 5.5 (Anthropic), using Claude Code._
