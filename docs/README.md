# Documentation

JumpCloud-Seeding deploys the VMs for the JumpCloud lab on three hypervisors. Each page covers one of them: what it deploys, what it needs, and every step the tools can't do for you.

| Page | Hypervisor | Deploys |
|---|---|---|
| [Xen Orchestra](xen-orchestra.md) | XCP-ng with Xen Orchestra, through Terraform | 3 Ubuntu Server 24.04 VMs, a pfSense firewall and 3 Windows 11 VMs on an isolated lab network |
| [Hyper-V](hyper-v.md) | Microsoft Hyper-V, through PowerShell | Each technician's copy of the golden VM exports under `C:\Users\Public\Documents\Hyper-V\Golden` |
| [UTM on macOS](utm-macos.md) | UTM on a Mac with Apple silicon, through zsh | A macOS VM duplicated from a golden VM |

VMs a technician deploys carry their name: `<name>_JCLab_<vm>` on Hyper-V and `<name>_JCLab_macOS` on UTM.

Open problems and workarounds are in [KNOWN-ISSUES.md](../KNOWN-ISSUES.md).

_Written with AI assistance: Claude Opus 5.5 (Anthropic), using Claude Code._
