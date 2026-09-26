# Known issues

Open issues on the `staging` branch. Add a row when you find one, and delete
the row when a fix is merged.

| Issue | Affects | Workaround |
|---|---|---|
| Windows 11 VMs default to a 1920x1080 display resolution. | Windows 11 VMs | None yet |
| pfSense may take 192.0.2.240 instead of requesting an address from DHCP. | pfSense VM | None yet |
| VMs may have no internet connection on first boot. | All VMs | None yet |
| The Ubuntu image is minimized and lacks common tools such as `ping` and `nslookup`. | Ubuntu VMs | `sudo apt install iputils-ping dnsutils`, or `sudo unminimize` for the full toolset |
