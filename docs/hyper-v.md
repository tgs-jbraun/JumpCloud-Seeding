# Hyper-V

The [`hyper-v/`](../hyper-v) folder imports golden VM exports on a Hyper-V host. Each technician gets their own copy of every golden VM, named `<name>_JCLab_<vm>` and stored under `C:\ProgramData\Microsoft\Windows\Hyper-V\<name>_JCLab_<vm>`. The golden exports stay untouched.

## Golden exports

Export each lab VM once with Hyper-V's `Export-VM` into `C:\Users\Public\Documents\Hyper-V\Golden`. An export keeps its config at `C:\Users\Public\Documents\Hyper-V\Golden\<VM>\Virtual Machines\<GUID>.vmcx`, and the scripts name each lab VM after its export folder.

The scripts skip any golden folder that a VM registered on the host runs from. That keeps a permanent VM such as `LAB-DC`, which runs from `C:\Users\Public\Documents\Hyper-V\Golden\LAB-DC`, out of the lab, and it avoids its locked files.

## Two ways to run it

| Runs from | Tool | Needs | Interface |
|---|---|---|---|
| The Hyper-V host | [`import-golden-vms.ps1`](../hyper-v/import-golden-vms.ps1) | Windows PowerShell 5.1, built in. Run it elevated. | Plain prompts and a progress bar |
| Your workstation, over WinRM HTTPS | [`jclab.py`](jclab.md), with [`JCLab.Bridge.ps1`](../hyper-v/JCLab.Bridge.ps1) | Python 3.9+, `pip install -r requirements.txt`, and PowerShell 7.4 | Tables, arrow-key menus and a live progress view |

Both run their host-side steps from [`JCLab.Host.ps1`](../hyper-v/JCLab.Host.ps1), so keep it in the same folder. Both need an administrator account on the host.

| Setting | Default | Meaning |
|---|---|---|
| Your name (`-UserName`) | Asks | Added to each VM name. Spaces become dashes. |
| Source (`-Source`) | `C:\Users\Public\Documents\Hyper-V\Golden` | Folder of golden exports on the host |
| Destination (`-Destination`) | `C:\ProgramData\Microsoft\Windows\Hyper-V` | Folder for the lab VMs on the host |
| At once (`-ThrottleLimit`) | `3` | VMs imported at once, 1 to 16 |
| Lab switch (`-LabSwitch`) | Asks | The vSwitch the golden VMs' lab adapters use |

The host script takes these as parameters. jclab.py asks for them, and also for the host and its administrator account.

## What happens on a run

Both tools follow the same steps:

1. Read the golden exports and plan a VM name and folder for each.
2. If you already have lab VMs or leftover lab folders, list them and ask:
   - **Cancel** (the default) changes nothing.
   - **Redeploy** deletes your lab VMs, disks and folders, then imports fresh copies.
   - **Deploy missing** keeps your VMs and imports only the ones you don't have yet. It appears when you have part of the lab.
   - **Delete** deletes your lab VMs, disks and folders, then stops.
3. Import each VM as a copy with a new ID. Every file goes under that VM's destination folder.
4. Rename each VM to `<name>_JCLab_<vm>` and starts it.

**Deleting uses Hyper-V's own order.** For each VM, the tool discards a saved state, turns the VM off, deletes its checkpoints and waits for the disk merge, removes the VM, then deletes its disks. It waits up to 5 minutes for each step. VMs with checkpoints go last, because their merges take longest. Folders go after all the VMs, once nothing holds their files.

**Each lab gets its own network.** Before the first import, the tools create a Private vSwitch for the technician, `<name>_JCLab_vSwitch`. A Private switch connects only the VMs on it, not the host and not other technicians' labs, so VMs of different technicians never share L2. Before each VM's first boot, its adapters on the lab switch move to that Private switch. Adapters on other switches, such as a router's WAN on an external switch, stay as they are. If the lab switch name is wrong, the tools stop before changing anything, because no adapters would move. Delete also removes the Private switch. Labs deployed before this change still use the shared lab switch, so redeploy them.

**Imports run in parallel.** Each import is a Hyper-V background job, 3 at a time by default. That is faster between SSD or NVMe drives. On spinning disks parallel copies compete for the same disks, so import 1 or 2 at once.

## Remote import from your workstation

```bash
python jclab.py
```

Pick Hyper-V, then "From this workstation". jclab.py draws the whole UI. A PowerShell 7 helper, [`JCLab.Bridge.ps1`](../hyper-v/JCLab.Bridge.ps1), runs only the PowerShell calls: the certificate check, `Get-Credential`, the HTTPS session and the `JCLab.Host.ps1` functions. jclab.py starts it in the background. The helper connects back over loopback with a one-time token, and it refuses any function outside the few that jclab.py needs.

1. jclab.py asks for your name, the host, the folders and how many VMs import at once, then shows them for review. It remembers them for next time.
2. Before it asks for credentials, it checks the host's SSL certificate on WinRM HTTPS (port 5986) with `Test-WSMan`. If the certificate isn't valid, for example because it's self-signed, it shows the reason and asks whether to skip certificate checks for this connection. The default is No.
3. It asks for the host's administrator account name. PowerShell's `Get-Credential` then asks for the password in the same terminal. The password stays in a `SecureString` inside the helper. It is never converted to plain text and never reaches jclab.py. The helper connects over HTTPS only and drops the credential once connected.
4. It shows the skipped exports and the plan, then runs the pre-deployment check.
5. It imports the VMs in a live "Deploying lab VMs" table, with a progress bar and status for each VM, then shows a results table.

While the disks copy, a separate "While you wait" box below the table shows a random two-sentence pop-culture fact, with a bar that fills up until the next fact. The facts come from [`pop-culture-facts.txt`](../hyper-v/pop-culture-facts.txt), one per line as `sentence | sentence | source`. Each names its Wikipedia source. To add a fact, add a line.

## Convert disks for XCP-ng

[`convert-vhdx-to-vhd.ps1`](../Tools/convert-vhdx-to-vhd.ps1) batch converts VHDX disks to the dynamic VHDs XCP-ng imports, following the [XCP-ng migration guide](https://docs.xcp-ng.org/installation/migrate-to-xcp-ng/#from-hyper-v). It runs on the Hyper-V host in an elevated Windows PowerShell 5.1 and leaves the VHDX files unchanged.

1. Remove the Hyper-V integration tools from each guest, then shut the VMs down.
2. Convert the disks of whole VMs, or of every VHDX in a folder:

   ```powershell
   .\Tools\convert-vhdx-to-vhd.ps1 -VMName DC01, WIN11-01 -Destination C:\XCP-ng
   .\Tools\convert-vhdx-to-vhd.ps1 -Path C:\ProgramData\Microsoft\Windows\Hyper-V -Destination C:\XCP-ng
   ```

3. In Xen Orchestra, open Import > Disk, pick the storage repository and upload each VHD.
4. Create a VM from a template without disks.
5. Attach the imported disk to the VM, then start it.
6. Install the XCP-ng guest tools in the VM.

The script skips a disk, and says why, if the disk:

- is larger than 2040 GiB, the VHD format's limit
- has 4096-byte logical sectors, which VHD doesn't support
- is a checkpoint disk. Delete the VM's checkpoints first, so Hyper-V merges them.
- belongs to a running VM

It doesn't replace an existing VHD unless you add `-Force`.

To copy the VHDs straight into a file-based storage repository instead of importing them, add `-XcpNaming`. Each VHD is then named `<UUID>.vhd`, the only name XCP-ng accepts there, and `mapping.csv` records which VHDX each UUID came from. Rescan the storage repository after copying.

## Set up WinRM over HTTPS on the host

The remote import connects only over HTTPS. Run this once, elevated, on the Hyper-V host:

```powershell
Enable-PSRemoting -Force
$cert = New-SelfSignedCertificate -DnsName $env:COMPUTERNAME -CertStoreLocation Cert:\LocalMachine\My
New-Item -Path WSMan:\localhost\Listener -Transport HTTPS -Address * -CertificateThumbPrint $cert.Thumbprint -Force
New-NetFirewallRule -DisplayName 'WinRM HTTPS' -Direction Inbound -Protocol TCP -LocalPort 5986 -Action Allow
```

A self-signed certificate works, but jclab.py then asks whether to skip certificate checks on every run. To avoid that, use a certificate from a CA your workstation trusts, issued for the host name you connect to.

_Written with AI assistance: Claude Opus 5.5 (Anthropic), using Claude Code._
