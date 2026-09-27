#!/bin/zsh
# Written with AI assistance: Claude Opus 5.5 (Anthropic), using Claude Code.

# Deploys 2 macOS VMs in UTM by duplicating a golden macOS VM, then starts
# them. VMs are named <your name>_JCLab_macOS-1 and -2. The golden VM stays
# untouched.
#
# Each VM gets 2 CPU cores and 2048 MiB of RAM, so both fit on the test host,
# a Mac mini (M2, 8 GiB RAM), with room left for macOS itself.
#
# UTM 4.7.5 can't create or install a macOS VM from a script: its "make"
# command builds Apple Virtualization VMs as Linux guests only. It can
# duplicate one, so build the golden VM once by hand:
#   1. In UTM, create a macOS VM (Virtualize > macOS 12+) from an IPSW.
#      Set its disk to 40 GB. UTM can't resize it later from a script.
#   2. Finish Setup Assistant and install what every lab VM needs.
#   3. Shut it down and name it JCLab-macOS-Golden, or pass its name with -g.
#
# Disk space: UTM duplicates with APFS clones, so a new copy takes almost no
# space. Each copy grows only by what it writes after that. The disk image is
# sparse, so even the golden VM uses only the space macOS fills, not all 40 GB.
#
# Each copy gets its own random MAC address, since UTM 4.7.5 keeps the
# golden VM's address on Apple Virtualization VMs it duplicates. The copies
# share the golden VM's machine identifier, so don't sign them in to the
# same Apple Account as the golden VM.
#
# Requirements: a Mac with Apple silicon, UTM in /Applications, and
# permission for this terminal to control UTM when macOS asks (Automation).
#
# Usage:
#   ./deploy-macos-vms.zsh
#   ./deploy-macos-vms.zsh -n jdoe -g "macOS Golden"
#
#   -n  Your name, added to each VM name (asks if omitted)
#   -g  Name of the golden VM in UTM (default JCLab-macOS-Golden)

emulate -L zsh
setopt err_exit no_unset pipe_fail extended_glob

tech='' golden=JCLab-macOS-Golden
while getopts 'n:g:' opt; do
  case $opt in
    n) tech=$OPTARG ;;
    g) golden=$OPTARG ;;
    *) print -u2 "See the usage comment at the top of $0"; exit 2 ;;
  esac
done

die() { print -u2 "Error: $1"; exit 1 }

[[ $(uname -m) == arm64 ]] || die 'macOS VMs need a Mac with Apple silicon.'
[[ -d /Applications/UTM.app ]] || die 'UTM not found in /Applications. Install it from https://mac.getutm.app'

# The name becomes part of each VM name, so keep it to safe characters
[[ -n $tech ]] || read -r 'tech?Your name (added to each VM name): '
tech=${${tech## #}%% #}; tech=${tech// /-}
[[ $tech == [A-Za-z0-9._-]## ]] || die "Use only letters, digits, dots, dashes and underscores in the name: '$tech'"
names=(${tech}_JCLab_macOS-1 ${tech}_JCLab_macOS-2)

# The golden VM must exist and be stopped (UTM only duplicates stopped VMs),
# and neither lab VM may exist yet
problem=$(osascript - $golden $names <<'EOF'
on run argv
  set {goldenName, name1, name2} to argv
  tell application "UTM"
    if not (exists virtual machine named goldenName) then return "No VM named " & goldenName & " in UTM. Build it first (see the top of this script) or pass -g."
    if status of virtual machine named goldenName is not stopped then return "Shut down " & goldenName & " first."
    repeat with n in {name1, name2}
      if exists virtual machine named n then return "A VM named " & n & " already exists in UTM. Delete or rename it first."
    end repeat
  end tell
  return ""
end run
EOF
)
[[ -z $problem ]] || die $problem

for name in $names; do
  # Random locally administered unicast MAC: set bit 1, clear bit 0 of the first octet
  mac=$(printf '%02x:%02x:%02x:%02x:%02x:%02x' $(( (RANDOM & 0xfc) | 0x02 )) $((RANDOM % 256)) $((RANDOM % 256)) $((RANDOM % 256)) $((RANDOM % 256)) $((RANDOM % 256)))
  print "Duplicating $golden as $name (MAC $mac)"
  osascript - $golden $name $mac <<'EOF'
on run argv
  set {goldenName, vmName, vmMac} to argv
  tell application "UTM"
    duplicate (virtual machine named goldenName) with properties {configuration:{name:vmName, cpu cores:2, memory:2048, network interfaces:{{index:0, address:vmMac}}}}
    start (virtual machine named vmName)
  end tell
end run
EOF
done

print "Done: ${(j:, :)names} are starting."
