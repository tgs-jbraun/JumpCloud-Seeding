# Hyper-V

The [`hyper-v/`](../hyper-v) folder imports golden VM exports on a Hyper-V host. Each technician gets their own copy of every golden VM, named `<name>_JCLab_<vm>` and stored under `C:\ProgramData\Microsoft\Windows\Hyper-V\<name>_JCLab_<vm>`. The golden exports stay untouched.

## Golden exports

Export each lab VM once with Hyper-V's `Export-VM` into `C:\Users\Public\Documents\Hyper-V\Golden`. An export keeps its config at `C:\Users\Public\Documents\Hyper-V\Golden\<VM>\Virtual Machines\<GUID>.vmcx`, and the scripts name each lab VM after its export folder.

The scripts skip any golden folder that a VM registered on the host runs from. That keeps a permanent VM such as `LAB-DC`, which runs from `C:\Users\Public\Documents\Hyper-V\Golden\LAB-DC`, out of the lab, and it avoids its locked files.

## The scripts

| Script | Runs on | Needs | Interface |
|---|---|---|---|
| [`import-golden-vms.ps1`](../hyper-v/import-golden-vms.ps1) | The Hyper-V host | Windows PowerShell 5.1, built in. Run it elevated. | Plain prompts and a progress bar |
| [`import-golden-vms-remote.ps1`](../hyper-v/import-golden-vms-remote.ps1) | Your workstation, connected to the host over WinRM HTTPS | PowerShell 7.4 and the [PwshSpectreConsole](https://github.com/ShaunLawrie/PwshSpectreConsole) module | Tables, arrow-key menus and a live progress view |

Both run their host-side steps from [`JCLab.Host.ps1`](../hyper-v/JCLab.Host.ps1), so keep it in the same folder. Both need an administrator account on the host.

| Parameter | Default | Meaning |
|---|---|---|
| `-UserName` | Asks | Your name, added to each VM name. Spaces become dashes. |
| `-Source` | `C:\Users\Public\Documents\Hyper-V\Golden` | Folder of golden exports on the host |
| `-Destination` | `C:\ProgramData\Microsoft\Windows\Hyper-V` | Folder for the lab VMs on the host |
| `-ThrottleLimit` | `3` | VMs imported at once, 1 to 16 |
| `-ComputerName` | Asks | Remote script only: the Hyper-V host |
| `-Credential` | Asks | Remote script only: the host's administrator account |
| `-SkipCertificateCheck` | Off | Remote script only: skip certificate checks without asking |

## What happens on a run

1. The script reads the golden exports and plans a VM name and folder for each.
2. If you already have lab VMs or leftover lab folders, it lists them and asks:
   - **Cancel** (the default) changes nothing.
   - **Redeploy** deletes your lab VMs, disks and folders, then imports fresh copies.
   - **Deploy missing** keeps your VMs and imports only the ones you don't have yet. It appears when you have part of the lab.
   - **Delete** deletes your lab VMs, disks and folders, then stops.
3. It imports each VM as a copy with a new ID. Every file goes under that VM's destination folder.
4. It renames each VM to `<name>_JCLab_<vm>` and starts it.

**Deleting uses Hyper-V's own order.** For each VM, the script discards a saved state, turns the VM off, deletes its checkpoints and waits for the disk merge, removes the VM, then deletes its disks. It waits up to 5 minutes for each step. VMs with checkpoints go last, because their merges take longest. Folders go after all the VMs, once nothing holds their files.

**Imports run in parallel.** Each import is a Hyper-V background job, 3 at a time by default. That is faster between SSD or NVMe drives. On spinning disks parallel copies compete for the same disks, so set `-ThrottleLimit 1` or `2`.

## The remote script

```powershell
Install-Module PwshSpectreConsole -Scope CurrentUser
.\hyper-v\import-golden-vms-remote.ps1 -ComputerName hyperv01
```

1. It asks for your name and the host. It offers the values from your last successful connection, saved in `%APPDATA%\JumpCloud-Seeding\remote-import.json`. Credentials are never saved.
2. It checks the host's SSL certificate on WinRM HTTPS (port 5986) before it asks for credentials. If the certificate isn't valid, for example because it's self-signed, it shows the reason and asks whether to skip certificate checks for this connection. The default is No.
3. It asks for the host's administrator account with `Get-Credential`. The password stays in a `SecureString` and is never converted to plain text. The script connects over HTTPS only and drops the credential once connected.
4. It shows the plan, runs the pre-deployment check, then imports the VMs in a live "Deploying lab VMs" table with a progress bar and status for each VM.

While the disks copy, a separate "While you wait" box below the table shows a random two-sentence pop-culture fact, with a bar that fills up until the next fact. The facts come from [`pop-culture-facts.txt`](../hyper-v/pop-culture-facts.txt), one per line as `sentence | sentence | source`. Each names its Wikipedia source. To add a fact, add a line.

## Set up WinRM over HTTPS on the host

The remote script connects only over HTTPS. Run this once, elevated, on the Hyper-V host:

```powershell
Enable-PSRemoting -Force
$cert = New-SelfSignedCertificate -DnsName $env:COMPUTERNAME -CertStoreLocation Cert:\LocalMachine\My
New-Item -Path WSMan:\localhost\Listener -Transport HTTPS -Address * -CertificateThumbPrint $cert.Thumbprint -Force
New-NetFirewallRule -DisplayName 'WinRM HTTPS' -Direction Inbound -Protocol TCP -LocalPort 5986 -Action Allow
```

A self-signed certificate works, but the script then asks whether to skip certificate checks on every run. To avoid that, use a certificate from a CA your workstation trusts, issued for the host name you connect to.

_Written with AI assistance: Claude Opus 5.5 (Anthropic), using Claude Code._
