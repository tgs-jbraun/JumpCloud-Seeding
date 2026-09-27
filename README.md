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
on the host, and both ask before they change a lab you already have: redeploy it, delete
it, or deploy only the VMs that are missing.

| Script | Runs on | Needs | Interface |
|---|---|---|---|
| [`import-golden-vms.ps1`](hyper-v/import-golden-vms.ps1) | The Hyper-V host, or remotely over WinRM HTTPS | Windows PowerShell 5.1, built in. Run it elevated on the host. | Plain prompts and a progress bar |
| [`import-golden-vms-remote.ps1`](hyper-v/import-golden-vms-remote.ps1) | Your workstation, connecting to the host over WinRM HTTPS | PowerShell 7.4 and the [PwshSpectreConsole](https://github.com/ShaunLawrie/PwshSpectreConsole) module | Tables, menus, spinners and a live deployment table |

To run the remote version, install the module once, then start the script:

```powershell
Install-Module PwshSpectreConsole -Scope CurrentUser
.\hyper-v\import-golden-vms-remote.ps1 -ComputerName hyperv01
```

The remote version walks through these steps in a terminal UI:

1. Asks for your name and the host name. After a successful connection it
   saves both to `%APPDATA%\JumpCloud-Seeding\remote-import.json` and offers
   them as defaults next time, so pressing Enter keeps them. No credentials
   are saved.
2. Validates the host's SSL certificate on WinRM HTTPS (port 5986). If the
   certificate isn't valid, for example because it's self-signed, it shows
   why and asks whether to skip certificate checks for this connection. The
   default is No.
3. Asks for the host's administrator account with `Get-Credential`. The
   password stays encrypted in memory and is never stored.
4. Shows the deployment plan as a table.
5. If you already have lab VMs or folders, lists them and offers Cancel,
   Redeploy, Deploy missing or Delete in an arrow-key menu. Deploy missing
   keeps your VMs and imports only the ones you don't have yet.
6. Imports the VMs in a live "Deploying lab VMs" table, with a progress bar
   and status for each VM, then shows a results table.

Both scripts import 3 VMs at once by default. That is faster when the host
copies between SSD or NVMe drives. On spinning disks, parallel copies compete
for the same disks, so lower it with `-ThrottleLimit 1` or `2`.

While the disks copy, the remote version shows random two-sentence pop-culture
facts in a separate "While you wait" box below the VM table, so they can't be
mistaken for VMs. The facts come from [`hyper-v/pop-culture-facts.txt`](hyper-v/pop-culture-facts.txt). Each
fact names its Wikipedia source. Add a line to the file to add a fact.

The comments at the top of each script list all options.

The comments in each folder's files list the manual steps the tools can't do.
Open problems and workarounds are in [KNOWN-ISSUES.md](KNOWN-ISSUES.md).

## AI assistance

This repository was written with AI assistance, using Claude Opus 5.5 by
Anthropic in Claude Code. Commits made with the assistant carry a
`Co-Authored-By: Claude Opus 5.5` trailer. Commits without it were written by
hand.
