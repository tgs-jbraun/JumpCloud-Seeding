# JumpCloud lab

Deploys the JumpCloud lab: 3 Ubuntu Server 24.04 VMs, a pfSense firewall and
3 Windows 11 VMs, on an isolated lab network behind pfSense.

Each folder deploys the lab on one hypervisor.

| Folder | Hypervisor | Tool |
|---|---|---|
| [`xo/`](xo) | XCP-ng with Xen Orchestra | Terraform, `vatesfr/xenorchestra` provider |
| [`hyper-v/`](hyper-v) | Microsoft Hyper-V | PowerShell script that imports golden VM exports |

On Xen Orchestra, run Terraform from `xo/`:

```bash
cd xo
copy terraform.tfvars.example terraform.tfvars   # then fill in real values
terraform init
terraform plan
terraform apply
```

On Hyper-V, run `hyper-v\import-golden-vms.ps1` in an elevated PowerShell. The
comments at the top of the script show the local and remote options.

The comments in each folder's files list the manual steps the tools can't do.
Open problems and workarounds are in [KNOWN-ISSUES.md](KNOWN-ISSUES.md).

## AI assistance

This repository was written with AI assistance, using Claude Opus 5.5 by
Anthropic in Claude Code. Commits made with the assistant carry a
`Co-Authored-By: Claude Opus 5.5` trailer. Commits without it were written by
hand.
