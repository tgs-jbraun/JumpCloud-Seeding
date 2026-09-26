# JumpCloud lab

Deploys the JumpCloud lab: 3 Ubuntu Server 24.04 VMs, a pfSense firewall and
3 Windows 11 VMs, on an isolated lab network behind pfSense.

Each folder deploys the lab on one hypervisor.

| Folder | Hypervisor | Tool |
|---|---|---|
| [`xo/`](xo) | XCP-ng with Xen Orchestra | Terraform, `vatesfr/xenorchestra` provider |
| [`hyper-v/`](hyper-v) | Microsoft Hyper-V | PowerShell scripts that import golden VM exports |

On Xen Orchestra, run Terraform from `xo/`:

```bash
cd xo
copy terraform.tfvars.example terraform.tfvars   # then fill in real values
terraform init
terraform plan
terraform apply
```

On Hyper-V, two scripts do the same import. Both need an administrator account
on the host, and both ask before they redeploy or delete a lab you already
have.

| Script | Runs on | Needs | Interface |
|---|---|---|---|
| [`import-golden-vms.ps1`](hyper-v/import-golden-vms.ps1) | The Hyper-V host, or remotely over WinRM HTTPS | Windows PowerShell 5.1, built in. Run it elevated on the host. | Plain prompts and a progress bar |
| [`import-golden-vms-remote.ps1`](hyper-v/import-golden-vms-remote.ps1) | Your workstation, connecting to the host over WinRM HTTPS | PowerShell 7.4 and the [PwshSpectreConsole](https://github.com/ShaunLawrie/PwshSpectreConsole) module | Tables, menus, spinners and a progress bar per VM |

To run the remote version, install the module once, then start the script:

```powershell
Install-Module PwshSpectreConsole -Scope CurrentUser
.\hyper-v\import-golden-vms-remote.ps1 -ComputerName hyperv01
```

It asks for the host's administrator account with `Get-Credential` and never
stores the password. If the host's certificate is self-signed, it offers to
skip certificate checks for that connection. The comments at the top of each script list all options.

The comments in each folder's files list the manual steps the tools can't do.
Open problems and workarounds are in [KNOWN-ISSUES.md](KNOWN-ISSUES.md).

## AI assistance

This repository was written with AI assistance, using Claude Opus 5.5 by
Anthropic in Claude Code. Commits made with the assistant carry a
`Co-Authored-By: Claude Opus 5.5` trailer. Commits without it were written by
hand.
