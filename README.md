# JumpCloud lab

JumpCloud-Seeding gives each technician a working JumpCloud test lab in
minutes, on whichever hypervisor they have: Xen Orchestra, Hyper-V, or UTM on
a Mac. Every lab is built from the same known-good templates or golden VMs, so
labs start from the same state and can be torn down and redeployed without
manual setup.

## Goals

- **Repeatable:** deploy the same lab every time, from templates or golden VMs.
- **Per technician:** each technician's VMs carry their name, so several labs
  share one host without clashing.
- **Safe to rerun:** the scripts ask before they change a lab you already
  have, and never touch the golden VMs.
- **Few dependencies:** use what each platform ships, and add a tool only
  where it clearly helps.

## What's here

| Folder | Hypervisor | Tool | Deploys |
|---|---|---|---|
| [`xo/`](xo) | XCP-ng with Xen Orchestra | Terraform | 3 Ubuntu Server 24.04 VMs, a pfSense firewall and 3 Windows 11 VMs on an isolated lab network |
| [`hyper-v/`](hyper-v) | Microsoft Hyper-V | PowerShell | Each technician's copy of the golden VM exports |
| [`utm-qemu/`](utm-qemu) | UTM on a Mac with Apple silicon | zsh, with a Windows launcher | A macOS VM duplicated from a golden VM |

## Documentation

Setup, requirements, options and manual steps for each hypervisor are in
[`docs/`](docs): [Xen Orchestra](docs/xen-orchestra.md),
[Hyper-V](docs/hyper-v.md) and [UTM on macOS](docs/utm-macos.md). The comments
at the top of each script list its options too.

Open problems and workarounds are in [KNOWN-ISSUES.md](KNOWN-ISSUES.md).

## AI assistance

This repository was written with AI assistance, using Claude Opus 5.5 by
Anthropic in Claude Code. Commits made with the assistant carry a
`Co-Authored-By: Claude Opus 5.5` trailer. Commits without it were written by
hand.
