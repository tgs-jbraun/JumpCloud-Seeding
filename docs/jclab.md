# jclab.py launcher

[`jclab.py`](../jclab.py) sets up and runs the lab on any of the three hypervisors from one terminal UI. It asks for the settings, shows them in a table for review, then runs the same tools the other pages describe. It adds no deployment logic of its own.

## Install and run

It needs Python 3.9 or later and two MIT-licensed packages: [rich](https://github.com/Textualize/rich) for tables, panels and spinners, and [questionary](https://github.com/tmbo/questionary) for arrow-key menus and prompts.

```bash
python -m pip install -r requirements.txt
python jclab.py
```

On start it shows which hypervisors this machine can drive, and why not for the others. The menu greys out the ones it can't run.

| Hypervisor | Needs on this machine | Runs |
|---|---|---|
| Xen Orchestra | Terraform | `terraform` in `xo/` |
| Hyper-V | PowerShell 7.4, or Windows PowerShell 5.1 on the host | Its own remote import UI, with [`JCLab.Bridge.ps1`](../hyper-v/JCLab.Bridge.ps1) for the PowerShell calls, or [`import-golden-vms.ps1`](../hyper-v/import-golden-vms.ps1) on the host |
| UTM | On a Mac: zsh, UTM and gum. On Windows: the OpenSSH client. | [`deploy-macos-vm.zsh`](../utm-qemu/deploy-macos-vm.zsh), or [`deploy-macos-vm-remote.ps1`](../utm-qemu/deploy-macos-vm-remote.ps1) over SSH |

Press Ctrl+C in any prompt to go back to the menu. Prompts show the last answer as a default, so Enter keeps it.

## Xen Orchestra

1. Pick an action: plan and then apply after review, plan only, destroy the lab, or only save the settings.
2. Answer the prompts for each variable in `terraform.tfvars`. The defaults come from your current `xo/terraform.tfvars`, then from the example file. For the SSH key, pick one of the `.pub` files in `~/.ssh` or none.
3. Enter the XO password. If `terraform.tfvars` already holds one, answer yes to keep it there instead.
4. Review the settings table and confirm. jclab.py writes `xo/terraform.tfvars`.
5. It runs `terraform init` behind a spinner, with a pop-culture fact, then `terraform plan`. After you review the plan, it asks whether to apply it.

jclab.py never writes a password you enter to disk. Terraform gets it through the `TF_VAR_xoa_password` environment variable, and only while its commands run. `terraform.tfvars` values beat environment variables, so a password you keep in the file stays the one Terraform uses. The saved plan file holds the password too, so jclab.py deletes it straight after the apply, or when you decline, and Git ignores `*.tfplan`.

## Hyper-V

1. Pick where the import runs: from this workstation over WinRM HTTPS, or on this Hyper-V host.
2. Enter your name, the host (remote only), the golden export and lab folders, and how many VMs import at once.
3. Review and confirm.

From the workstation, jclab.py checks the certificate, asks for the account, and shows the plan, the pre-deployment check and a live import table. PowerShell asks for the password, and it never reaches jclab.py. The [Hyper-V](hyper-v.md) page has the details. On the host, jclab.py runs the host script, so start jclab.py in an elevated terminal.

## UTM

1. Enter your name and the golden VM's name.
2. From Windows, also enter the Mac and the account on it. The SSH launcher then asks which key from `~/.ssh` to sign in with. The Mac needs no copy of this repo.
3. Review and confirm.

On a Mac, jclab.py runs the zsh script. From Windows it runs the SSH launcher, so the Mac setup on the [UTM on macOS](utm-macos.md) page applies, including the one-time Allow click on the Mac.

## What it remembers

Your answers go in `jclab.json`: under `%APPDATA%\JumpCloud-Seeding` on Windows, `~/Library/Application Support/JumpCloud-Seeding` on a Mac, and `~/.config/jumpcloud-seeding` elsewhere. No passwords are saved.

_Written with AI assistance: Claude Opus 5.5 (Anthropic), using Claude Code._
