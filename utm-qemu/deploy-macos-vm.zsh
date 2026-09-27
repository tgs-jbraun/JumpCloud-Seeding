#!/bin/zsh
# Written with AI assistance: Claude Opus 5.5 (Anthropic), using Claude Code.

# Deploys a macOS VM in UTM by duplicating a golden macOS VM, then starts it.
# The VM is named <your name>_JCLab_macOS. The golden VM stays untouched.
#
# The VM gets 4 CPU cores and 4 GiB of RAM, half of the test host, a Mac mini
# (M2, 8 GiB RAM), which leaves the rest for macOS itself.
#
# UTM 4.7.5 can't create or install a macOS VM from a script: its "make"
# command builds Apple Virtualization VMs as Linux guests only. It can
# duplicate one, so build the golden VM once by hand:
#   1. In UTM, create a macOS VM (Virtualize > macOS 12+) from an IPSW.
#      Set its disk to 40 GB. UTM can't resize it later from a script.
#   2. Finish Setup Assistant and install what every lab VM needs.
#   3. Shut it down and name it JCLab-macOS-Golden, or pass its name with -g.
#
# Disk space: UTM duplicates with APFS clones, so the copy takes almost no
# space at first. It grows only by what it writes after that. The disk image is
# sparse, so even the golden VM uses only the space macOS fills, not all 40 GB.
#
# The copy gets its own random MAC address, since UTM 4.7.5 keeps the
# golden VM's address on Apple Virtualization VMs it duplicates. The copy
# shares the golden VM's machine identifier, so don't sign it in to the
# same Apple Account as the golden VM.
#
# Like the Hyper-V scripts, it remembers your name and the golden VM for next
# time, shows the plan first, and asks before it changes a lab VM you already
# have: redeploy it, delete it, or cancel.
#
# Menus, spinners and boxes come from gum (MIT license, Charmbracelet), if
# installed: brew install gum. Without gum, the script uses plain prompts.
# With gum, it also shows a pop-culture fact from
# ../hyper-v/pop-culture-facts.txt while the VM starts.
#
# Requirements: a Mac with Apple silicon, UTM in /Applications, and
# permission for this terminal to control UTM when macOS asks (Automation).
#
# Usage:
#   ./deploy-macos-vm.zsh
#   ./deploy-macos-vm.zsh -n jdoe -g "macOS Golden"
#
#   -n  Your name, added to the VM name (asks if omitted)
#   -g  Name of the golden VM in UTM (asks if omitted, default JCLab-macOS-Golden)

emulate -L zsh
setopt err_exit no_unset pipe_fail extended_glob

tech='' golden=''
while getopts 'n:g:' opt; do
  case $opt in
    n) tech=$OPTARG ;;
    g) golden=$OPTARG ;;
    *) print -u2 "See the usage comment at the top of $0"; exit 2 ;;
  esac
done

cores=4 memory=4096
prefs=JumpCloud-Seeding   # defaults domain: ~/Library/Preferences/JumpCloud-Seeding.plist

die() { print -u2 -P "%F{red}Error:%f $1"; exit 1 }

[[ $(uname -m) == arm64 ]] || die 'macOS VMs need a Mac with Apple silicon.'
[[ -d /Applications/UTM.app ]] || die 'UTM not found in /Applications. Install it from https://mac.getutm.app'

# --- UI helpers: gum when installed, plain zsh otherwise ---------------------

(( $+commands[gum] )) && has_gum=1 || has_gum=0

# Prints a bordered box of lines
ui_box() {
  if (( has_gum )); then gum style --border rounded --border-foreground 39 --padding '0 1' -- "$@"
  else print -l -- '' "$@" ''; fi
}

# Reads a line into REPLY, offering $2 as the default. zsh shows read's own
# prompt only in interactive shells, so print it separately.
ui_input() {
  if (( has_gum )); then REPLY=$(gum input --header "$1" --value "$2" --placeholder "$1"); return; fi
  print -u2 -n -- "$1${2:+ [$2]}: "; read -r REPLY; REPLY=${REPLY:-$2}
}

# Prints the chosen option. The first option is the default.
ui_choose() {
  local header=$1 i=0 opt; shift
  if (( has_gum )); then gum choose --header "$header" -- "$@"; return; fi
  print -u2 -- $header
  for opt; do print -u2 -- "  $((++i))) $opt"; done
  while true; do
    print -u2 -n 'Number [1]: '; read -r REPLY; REPLY=${REPLY:-1}
    [[ $REPLY == <1-> ]] && (( REPLY <= $# )) && { print -- ${@[REPLY]}; return }
  done
}

# Runs a command with a spinner and passes its output through
ui_spin() {
  local title=$1; shift
  if (( has_gum )); then gum spin --spinner dot --title "$title" --show-output -- "$@"
  else print -u2 -- "$title"; "$@"; fi
}

# --- AppleScripts, run with osascript -e script args... -----------------------

# Every script returns plain words, so the shell never parses AppleScript
# constants. "missing" means no VM with that name.
as_status='
on statusName(vmName)
  tell application "UTM"
    if not (exists virtual machine named vmName) then return "missing"
    set s to status of virtual machine named vmName
    if s is stopped then return "stopped"
    if s is started then return "started"
  end tell
  return "busy"
end statusName'

as_state="$as_status"'
on run argv
  return statusName(item 1 of argv) & " " & statusName(item 2 of argv)
end run'

# Stops the VM through UTM first (like Stop-VM -TurnOff), then deletes it
as_delete='
on run argv
  set vmName to item 1 of argv
  tell application "UTM"
    if status of virtual machine named vmName is not stopped then
      stop virtual machine named vmName by force
      repeat 60 times
        if status of virtual machine named vmName is stopped then exit repeat
        delay 1
      end repeat
    end if
    delete virtual machine named vmName
  end tell
end run'

as_duplicate='
on run argv
  set {goldenName, vmName, vmMac, vmCores, vmMemory} to argv
  tell application "UTM"
    duplicate (virtual machine named goldenName) with properties {configuration:{name:vmName, cpu cores:(vmCores as integer), memory:(vmMemory as integer), network interfaces:{{index:0, address:vmMac}}}}
  end tell
end run'

# Starts the VM and waits up to 60 seconds for UTM to report it running
as_start="$as_status"'
on run argv
  set vmName to item 1 of argv
  tell application "UTM" to start virtual machine named vmName
  repeat 60 times
    if statusName(vmName) is "started" then return "started"
    delay 1
  end repeat
  return statusName(vmName)
end run'

# --- Name and golden VM, remembered from the last run ------------------------

(( has_gum )) && gum style --bold --foreground 39 --border double --border-foreground 39 \
  --align center --width 44 --padding '1 2' 'JumpCloud Lab' 'UTM macOS deploy' \
  || print -P '%B%F{cyan}JumpCloud Lab: UTM macOS deploy%f%b'
(( has_gum )) || print -P '%F{242}Tip: brew install gum for menus and spinners.%f'

last_tech=$(defaults read $prefs TechName 2>/dev/null) || last_tech=''
last_golden=$(defaults read $prefs GoldenVM 2>/dev/null) || last_golden=JCLab-macOS-Golden

if [[ -z $tech ]]; then ui_input 'Your name (added to the VM name)' $last_tech; tech=$REPLY; fi
if [[ -z $golden ]]; then ui_input 'Golden VM in UTM' $last_golden; golden=$REPLY; fi

# The name becomes part of the VM name, so keep it to safe characters
tech=${${tech## #}%% #}; tech=${tech// /-}
[[ $tech == [A-Za-z0-9._-]## ]] || die "Use only letters, digits, dots, dashes and underscores in the name: '$tech'"
[[ -n $golden ]] || die 'No golden VM given.'
name=${tech}_JCLab_macOS

state=($(ui_spin 'Reading VMs in UTM' osascript -e $as_state $golden $name))
golden_state=$state[1] lab_state=$state[2]
case $golden_state in
  missing) die "No VM named $golden in UTM. Build it first (see the top of this script) or pass -g." ;;
  stopped) ;;
  *)       die "Shut down $golden first. UTM only duplicates stopped VMs." ;;
esac

defaults write $prefs TechName -string $tech
defaults write $prefs GoldenVM -string $golden

ui_box 'Deployment plan' '' "Golden VM   $golden" "Deploys as  $name" "CPU / RAM   $cores cores, $memory MiB" 'Network     Shared (NAT), new random MAC'

# --- Pre-deployment check ------------------------------------------------------

if [[ $lab_state != missing ]]; then
  print -P "%F{yellow}You already have $name%f ($lab_state)."
  answer=$(ui_choose 'Existing lab VM found. What do you want to do?' \
    'Cancel: change nothing' \
    'Redeploy: stop and delete it, then deploy a fresh copy' \
    'Delete: stop and delete it, then stop')
  case $answer in
    Cancel*) print -P '%F{242}Cancelled. Nothing changed.%f'; exit 0 ;;
  esac
  ui_spin "Stopping and deleting $name through UTM" osascript -e $as_delete $name
  print -P "%F{red}Deleted%f $name"
  [[ $answer == Delete* ]] && exit 0
fi

# --- Deploy ------------------------------------------------------------------

# Random locally administered unicast MAC: set bit 1, clear bit 0 of the first octet
mac=$(printf '%02x:%02x:%02x:%02x:%02x:%02x' $(( (RANDOM & 0xfc) | 0x02 )) $((RANDOM % 256)) $((RANDOM % 256)) $((RANDOM % 256)) $((RANDOM % 256)) $((RANDOM % 256)))
ui_spin "Duplicating $golden as $name" osascript -e $as_duplicate $golden $name $mac $cores $memory

# A random two-sentence fact in its own box while the VM starts (gum only)
facts_file=${0:A:h}/../hyper-v/pop-culture-facts.txt
if (( has_gum )) && [[ -r $facts_file ]]; then
  facts=(${(f)"$(<$facts_file)"}); facts=(${facts:#(\#*|)})
  if (( $#facts )); then
    fact=(${(s:|:)facts[RANDOM % $#facts + 1]})
    gum style --border rounded --border-foreground 242 --padding '0 1' --width 70 \
      'While you wait: did you know?' '' "${fact[1]## #}" "$(gum style --faint -- "${${fact[2]## #}%% #}")"
  fi
fi

# A start can fail right after the duplicate with "Connection is invalid"
# (-609). It works on a retry, so try once more after a short pause.
started=$(ui_spin "Starting $name" osascript -e $as_start $name) || started=failed
if [[ $started != started ]]; then
  print -P "%F{yellow}First start didn't finish ($started). Retrying in 5 seconds.%f"
  sleep 5
  started=$(ui_spin "Starting $name (retry)" osascript -e $as_start $name) || started=failed
fi

if [[ $started == started ]]; then result='%F{green}Deployed and started%f'
else result="%F{red}Deployed, but it didn't start ($started)%f. Start it from UTM's window."; fi
ui_box 'Results' '' "VM          $name" "CPU / RAM   $cores cores, $memory MiB" "MAC         $mac" "Status      ${(%)result}"
[[ $started == started ]]
