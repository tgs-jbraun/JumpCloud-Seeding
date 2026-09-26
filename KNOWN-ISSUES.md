# Known issues

Issues on the `staging` branch. Add a row to **Open** when you find an issue.
When its fix is merged, move the row to **Fixed** and name the commit.

## Open

| Affects | Issue | Workaround |
|---|---|---|
| Windows 11 VMs | The display resolution defaults to 1920x1080. | None yet |
| All VMs | A VM may have no internet connection on first boot. | None yet |
| Ubuntu VMs | The image is minimized and lacks common tools such as `ping` and `nslookup`. | `sudo apt install iputils-ping dnsutils`, or `sudo unminimize` for the full toolset |

## Fixed

| Affects | Issue | Fix |
|---|---|---|
| Hyper-V import script | Redeploy and Delete failed with "The process cannot access the file '….vmcx' because it is being used by another process". A VM left under its golden name in a lab folder was missed, so Hyper-V still held its files. | `d47036b`: the pre-deployment check also finds VMs by folder and deletes them through Hyper-V before removing the folder. |

_Written with AI assistance: Claude Opus 5.5 (Anthropic), using Claude Code._
