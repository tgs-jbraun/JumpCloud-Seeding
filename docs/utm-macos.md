# UTM on macOS

The [`utm-qemu/`](../utm-qemu) folder deploys a macOS VM in UTM on a Mac with Apple silicon. [`deploy-macos-vm.zsh`](../utm-qemu/deploy-macos-vm.zsh) duplicates a golden macOS VM as `<name>_JCLab_macOS`, with 4 CPU cores and 4 GiB of RAM, and starts it.

It was tested on a Mac mini with an M2 chip, 8 GiB of RAM and a 250 GB disk, running UTM 4.7.5. One VM at 4 GiB leaves the other half of the Mac's RAM for macOS itself.

## Why a golden VM

UTM 4.7.5 can't create or install a macOS VM from a script. Its AppleScript `make` command builds Apple Virtualization VMs as Linux guests only. It can `duplicate` a VM, so the script copies one you build by hand, the way the Hyper-V scripts import golden exports.

UTM 5.0.6, a prerelease, adds scripted macOS installs from an IPSW. The script doesn't use them yet.

## Requirements

- Apple silicon. macOS guests don't run on Intel Macs.
- UTM in `/Applications`, from [mac.getutm.app](https://mac.getutm.app).
- [gum](https://github.com/charmbracelet/gum) (MIT license, Charmbracelet) for the menus, spinners and boxes: `brew install gum`.
- A clone of this repo.
- Permission for your terminal to control UTM. macOS asks on the first run.

## Build the golden VM

1. In UTM, create a macOS VM (Virtualize > macOS 12+) from an IPSW restore image.
2. Set its disk to 40 GB. The script can't resize it later.
3. Give it a single network adapter. Only the first adapter carries over to the copy.
4. Finish Setup Assistant and install what every lab VM needs.
5. Shut it down and name it `JCLab-macOS-Golden`.

## Run it

```bash
./utm-qemu/deploy-macos-vm.zsh
```

| Option | Default | Meaning |
|---|---|---|
| `-n` | Asks, offering the last value | Your name, added to the VM name |
| `-g` | Asks, offering the last value or `JCLab-macOS-Golden` | The golden VM's name in UTM |

1. It asks for your name and the golden VM. It remembers both with macOS's `defaults` command, in `~/Library/Preferences/JumpCloud-Seeding.plist`.
2. It checks that the golden VM exists and is shut down, since UTM only duplicates stopped VMs.
3. It shows the deployment plan.
4. If you already have the lab VM, it offers Cancel (the default), Redeploy or Delete. Delete stops the VM through UTM, waits up to 60 seconds for it to stop, then deletes it through UTM.
5. It duplicates the golden VM, sets 4 cores and 4 GiB of RAM, and gives the copy a new random MAC address.
6. It starts the VM and waits up to 60 seconds for UTM to report it running. If the start fails, it retries once after 5 seconds. A pop-culture fact from the Hyper-V facts file appears while the VM starts.
7. It shows a results box with the VM's name, size, MAC address and status.

## Disk space and identity

The copy takes almost no disk space at first. UTM duplicates with APFS clones, so the copy shares the golden VM's data and grows only by what it writes. The disk image is sparse, so even the golden VM uses only the space macOS fills, not all 40 GB.

UTM 4.7.5 keeps the golden VM's MAC address on the Apple Virtualization VMs it duplicates, so the script sets a new one. Without it, the copy and the golden VM would likely get the same IP address on UTM's shared network.

The copy shares the golden VM's Mac machine identifier. Don't sign it in to the same Apple Account as the golden VM.

## Run it from Windows over SSH

[`deploy-macos-vm-remote.ps1`](../utm-qemu/deploy-macos-vm-remote.ps1) runs the script on the Mac over SSH. The menus appear in your Windows terminal, and the VM's window opens on the Mac's screen. It needs only the SSH client built into Windows 10/11 and Windows Server 2019 or later, and it works in Windows PowerShell 5.1.

Set up the Mac once:

1. Turn on automatic login. UTM is a desktop app, so it needs a logged-in user to run VMs.
2. Turn on Remote Login in System Settings > General > Sharing.
3. Start the first remote run, then click Allow on the Mac's screen when macOS asks whether SSH may control UTM. The prompt doesn't appear over SSH. Until you allow it, the script fails with "Not authorized to send Apple events" (-1743). The setting is under System Settings > Privacy & Security > Automation.

Then run it from Windows:

```powershell
.\utm-qemu\deploy-macos-vm-remote.ps1 -ComputerName mac-mini.local -User labadmin
```

| Parameter | Default | Meaning |
|---|---|---|
| `-ComputerName` | Asks, offering the last value | The Mac's host name or IP address |
| `-User` | Asks, offering the last value | The account on the Mac |
| `-RepoPath` | `JumpCloud-Seeding` | The repo clone: a folder in the account's home folder (`JumpCloud-Seeding` or `~/JumpCloud-Seeding`), or a full path |
| `-UserName`, `-Golden` | Asked by the Mac script | Passed to the Mac script as `-n` and `-g` |

The launcher remembers the Mac, the account and the repo path in `%APPDATA%\JumpCloud-Seeding\utm-remote.json`. `ssh` asks for the password itself, and the launcher never saves it. It runs `ssh -t` so gum gets a terminal. The Mac script adds `/opt/homebrew/bin` to its search path, because commands run over SSH skip `~/.zprofile`, where Homebrew adds it.

Remote Apple Events (Remote Application Scripting) aren't an alternative from Windows. Only another Mac can send them.

_Written with AI assistance: Claude Opus 5.5 (Anthropic), using Claude Code._
