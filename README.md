# JumpCloud lab on Terraform

Deploys the JumpCloud lab: 3 Ubuntu Server 24.04 VMs, a pfSense firewall and
3 Windows 11 VMs, on an isolated lab network behind pfSense.

Each folder is a separate Terraform config for one hypervisor. Run Terraform
from inside the folder for your hypervisor.

| Folder | Hypervisor | Provider |
|---|---|---|
| [`xo/`](xo) | XCP-ng with Xen Orchestra | `vatesfr/xenorchestra` |
| [`hyper-v/`](hyper-v) | Microsoft Hyper-V: lab switch and Windows 11 VMs | `taliesins/hyperv` |
| [`hyper-v/hyperdeploy/`](hyper-v/hyperdeploy) | Microsoft Hyper-V: Ubuntu and pfSense VMs | HyperDeploy (PowerShell), not Terraform |

```bash
cd xo        # or: cd hyper-v
copy terraform.tfvars.example terraform.tfvars   # then fill in real values
terraform init
terraform plan
terraform apply
```

On Hyper-V, apply `hyper-v/` first (it creates the lab switch), then from
`hyper-v/hyperdeploy/` run:

```powershell
Install-Module -Name HyperDeploy
Publish-HyperDeploy -DefinitionFile .\definition.json
```

Each folder's files list the manual steps that the tools can't do.
