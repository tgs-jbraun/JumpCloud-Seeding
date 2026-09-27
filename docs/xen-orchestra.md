# Xen Orchestra

The [`xo/`](../xo) folder deploys the lab on XCP-ng with Terraform and the `vatesfr/xenorchestra` provider.

## What it deploys

| VM | Template | CPU / RAM / disk | Network |
|---|---|---|---|
| `ubuntu-2404-01` to `-03` | Ubuntu 24.04 Cloud-Init (Hub) | 2 vCPU, 4 GiB, 10 GiB | `jumpcloud-lab-net`, DHCP from pfSense |
| `pfSense` | pfSense 2.6 (Hub) | 2 vCPU, 2 GiB, 20 GiB | `LAN` (WAN) and `jumpcloud-lab-net` (LAN) |
| `JUMPCLOUD-TEST-1` to `-3` | Windows 11 JumpCloud - Template | 4 vCPU, 4 GiB, 64 GiB | `jumpcloud-lab-net`, DHCP from pfSense |

All VMs carry the `jumpcloud-lab` tag. Disks go on the `my-storage-repository` storage repository in the `my-xcp-pool` pool.

`jumpcloud-lab-net` is an SDN private network (192.168.1.0/24) created in XO by the SDN Controller, so it spans every host in the pool. Terraform looks it up, since the provider can't create SDN networks. pfSense serves DHCP on it from 192.168.1.1.

## Run it

```bash
cd xo
copy terraform.tfvars.example terraform.tfvars
terraform init
terraform plan
terraform apply
```

Fill in `terraform.tfvars` before `plan`. Git ignores it, because it holds the XO password.

| Variable | Meaning |
|---|---|
| `xoa_url` | XO websocket URL, `ws://` or `wss://` |
| `xoa_user`, `xoa_password` | XO admin account |
| `xoa_insecure` | `true` to skip TLS checks, for a self-signed XO certificate |
| `vm_name` | Prefix for the Ubuntu VMs, which get `-01`, `-02`, ... |
| `vm_count` | Number of Ubuntu VMs |
| `vm_ssh_public_key` | SSH key for the default `ubuntu` user, or `""` to skip |
| `windows_vm_count` | Number of Windows 11 VMs |

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
