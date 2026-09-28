#!/usr/bin/env python3
# Written with AI assistance: Claude Opus 5.5 (Anthropic), using Claude Code.

"""Interactive launcher for the JumpCloud lab on all three hypervisors.

Asks for each hypervisor's settings in a terminal UI, shows them for review,
then runs the tool that does the work:

  Xen Orchestra  Writes xo/terraform.tfvars, then runs terraform plan, apply
                 or destroy.
  Hyper-V        From a workstation, draws the import UI itself and runs the
                 PowerShell calls through hyper-v/JCLab.Bridge.ps1. On the
                 host, runs hyper-v/import-golden-vms.ps1.
  UTM            Runs utm-qemu/deploy-macos-vm.zsh on a Mac, or
                 deploy-macos-vm-remote.ps1 from Windows over SSH.

The UI uses rich (tables, panels, spinners) and questionary (arrow-key menus
and prompts), both MIT licensed. Install them once:

  python -m pip install -r requirements.txt

Run it from anywhere in the repo:

  python jclab.py

It remembers your answers for next time. It never saves passwords: the XO
password goes to Terraform as the TF_VAR_xoa_password environment variable,
the Hyper-V password stays in PowerShell (Get-Credential, as a SecureString),
and the UTM launcher's ssh asks for its own.
"""

import json
import os
import random
import re
import secrets
import socket
import subprocess
import sys
import time
from pathlib import Path
from shutil import which

try:
    import questionary
    from questionary import Choice, Style
    from rich import box
    from rich.align import Align
    from rich.console import Console, Group
    from rich.live import Live
    from rich.panel import Panel
    from rich.progress_bar import ProgressBar
    from rich.table import Table
    from rich.text import Text
except ImportError:
    sys.exit("jclab.py needs the rich and questionary packages. Install them with:\n"
             "  python -m pip install -r requirements.txt")

REPO = Path(__file__).resolve().parent
IS_WINDOWS = os.name == "nt"
IS_MAC = sys.platform == "darwin"
ACCENT = "deep_sky_blue1"
LABELS = {"xo": "Xen Orchestra", "hyperv": "Hyper-V", "utm": "UTM (macOS)"}

console = Console()
STYLE = Style([
    ("qmark", "fg:#00afff bold"),
    ("question", "bold"),
    ("answer", "fg:#00afff bold"),
    ("pointer", "fg:#00afff bold"),
    ("highlighted", "fg:#00afff bold"),
    ("selected", "fg:#00afff"),
    ("instruction", "fg:#808080 italic"),
    ("disabled", "fg:#6c6c6c italic"),
])

# --- Saved answers ------------------------------------------------------------

if IS_WINDOWS:
    STATE_DIR = Path(os.environ["APPDATA"]) / "JumpCloud-Seeding"
elif IS_MAC:
    STATE_DIR = Path.home() / "Library" / "Application Support" / "JumpCloud-Seeding"
else:
    STATE_DIR = Path.home() / ".config" / "jumpcloud-seeding"
STATE_FILE = STATE_DIR / "jclab.json"


try:
    state = json.loads(STATE_FILE.read_text(encoding="utf-8"))
except (OSError, ValueError):
    state = {}


def save_state():
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    STATE_FILE.write_text(json.dumps(state, indent=2), encoding="utf-8")


# --- Prompts ------------------------------------------------------------------
# unsafe_ask raises KeyboardInterrupt on Ctrl+C, which the menu loop catches
# to go back to the menu.

def text(message, default="", validate=None):
    return questionary.text(message, default=str(default or ""), validate=validate,
                            style=STYLE, qmark="›").unsafe_ask().strip()


def password(message):
    return questionary.password(message, validate=lambda v: bool(v) or "Enter the password.",
                                style=STYLE, qmark="›").unsafe_ask()


def confirm(message, default=True):
    return questionary.confirm(message, default=default, style=STYLE, qmark="›").unsafe_ask()


def select(message, choices, default=None):
    return questionary.select(message, choices=choices, default=default, style=STYLE, qmark="›",
                              pointer="❯", instruction="(arrow keys, Enter)").unsafe_ask()


def valid_name(value):
    name = re.sub(r"\s+", "-", value.strip())
    if re.fullmatch(r"[A-Za-z0-9._-]+", name):
        return True
    return "Use letters, digits, dots, dashes and underscores."


def whole_number(low, high=None):
    def check(value):
        if value.strip().isdigit() and int(value) >= low and (high is None or int(value) <= high):
            return True
        return f"Enter a whole number from {low} to {high}." if high else f"Enter a whole number of {low} or more."
    return check


def ask_technician():
    name = re.sub(r"\s+", "-", text("Your name (added to each VM name)", state.get("technician"), valid_name))
    state["technician"] = name
    return name


# --- Output -------------------------------------------------------------------

def banner():
    title = Text.assemble(("JumpCloud Lab\n", f"bold {ACCENT}"),
                          ("Xen Orchestra · Hyper-V · UTM", "grey62"), justify="center")
    console.print(Align.center(Panel.fit(title, box=box.DOUBLE, border_style=ACCENT, padding=(1, 6))))


def make_table(title, columns, colour=ACCENT):
    """A rounded table whose title stays on one line"""
    table = Table(title=title, title_style=f"bold {colour}", box=box.ROUNDED, border_style=colour,
                  min_width=len(title) + 4)
    for column in columns:
        table.add_column(column)
    return table


def print_table(title, columns, rows, colour=ACCENT):
    table = make_table(title, columns, colour)
    for row in rows:
        table.add_row(*row)
    console.print(table)


def settings_table(title, rows):
    table = Table(title=title, title_style=f"bold {ACCENT}", box=box.ROUNDED, border_style=ACCENT,
                  show_header=False)
    table.add_column(style="grey62")
    table.add_column(style="bold")
    for key, value in rows:
        table.add_row(key, str(value))
    console.print(table)


def result(code, what):
    if code == 0:
        console.print(Panel(f"[green]{what} finished.[/]", border_style="green", box=box.ROUNDED))
    else:
        console.print(Panel(f"[red]{what} stopped with exit code {code}.[/] Its output above says why.",
                            border_style="red", box=box.ROUNDED))


def load_facts():
    """Pop-culture facts from hyper-v/pop-culture-facts.txt, shuffled, as
    (sentence, sentence) pairs. Empty if the file is missing."""
    try:
        lines = (REPO / "hyper-v" / "pop-culture-facts.txt").read_text(encoding="utf-8").splitlines()
    except OSError:
        return []
    facts = [tuple(part.strip() for part in line.split("|")[:2])
             for line in lines if line.strip() and not line.startswith("#")]
    random.shuffle(facts)
    return facts


def fact_panel(fact, footer=None):
    """A fact in its own box, so nobody mistakes it for a VM or a result"""
    body = [Text(fact[0]), Text(fact[1], style="grey62")] + ([Text(""), footer] if footer else [])
    return Panel(Group(*body), title="While you wait: did you know?", title_align="left",
                 border_style="grey50", box=box.ROUNDED, width=76)


def show_fact():
    facts = load_facts()
    if facts:
        console.print(fact_panel(facts[0]))


def run(command, env=None):
    """Runs a command in this terminal, so its own prompts and menus work"""
    console.rule(Text(" ".join([Path(command[0]).name, *command[1:]]), style="grey62"), style="grey35")
    return subprocess.run(command, cwd=REPO, env=env).returncode


def powershell(script, *args, edition="powershell"):
    # Bypass only for this process, so the repo's unsigned scripts run
    return [edition, "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(REPO / script), *args]


# --- Readiness ----------------------------------------------------------------

def readiness():
    """Per hypervisor: how it runs from this machine, or why it can't"""
    xo = ("Terraform", None) if which("terraform") else (None, "Install Terraform: https://developer.hashicorp.com/terraform/install")

    if which("pwsh"):
        hv = ("PowerShell 7 (remote)" + (" or 5.1 (on the host)" if IS_WINDOWS else ""), None)
    elif IS_WINDOWS:
        hv = ("Windows PowerShell 5.1 (on the host)", None)
    else:
        hv = (None, "Install PowerShell 7.4: https://aka.ms/powershell")

    if IS_MAC:
        missing = [label for ok, label in ((which("zsh"), "zsh"), (Path("/Applications/UTM.app").exists(), "UTM"),
                                           (which("gum"), "gum (brew install gum)")) if not ok]
        utm = (None, "Missing " + ", ".join(missing)) if missing else ("zsh on this Mac", None)
    elif IS_WINDOWS:
        utm = ("SSH to the Mac", None) if which("ssh") else (None, "Add the Windows OpenSSH Client feature")
    else:
        utm = (None, "Run from macOS, or from Windows over SSH")
    return {"xo": xo, "hyperv": hv, "utm": utm}


def readiness_table(ready):
    table = Table(title="This machine", title_style=f"bold {ACCENT}", box=box.ROUNDED, border_style=ACCENT)
    table.add_column("Hypervisor", style="bold")
    table.add_column("Status")
    for key, (how, missing) in ready.items():
        table.add_row(LABELS[key], f"[green]✓[/] {how}" if how else f"[yellow]✗[/] [grey62]{missing}[/]")
    console.print(table)


# --- Xen Orchestra ------------------------------------------------------------

TFVARS = REPO / "xo" / "terraform.tfvars"
PLAN = "jclab.tfplan"


def read_tfvars(path):
    values = {}
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError:
        return values
    for line in lines:
        match = re.match(r'\s*(\w+)\s*=\s*("(?:[^"\\]|\\.)*"|[^\s#]+)', line)
        if match:
            key, value = match.groups()
            values[key] = json.loads(value) if value.startswith('"') else value
    return values


def write_tfvars(values):
    # JSON writes strings, numbers and booleans the way HCL reads them
    lines = ["# Written by jclab.py. Git ignores this file.", ""]
    lines += [f"{key} = {json.dumps(value)}" for key, value in values.items()]
    if "xoa_password" not in values:
        lines += ["", "# xoa_password isn't stored here. jclab.py passes it as TF_VAR_xoa_password,",
                  "# and terraform asks for it if you run it yourself."]
    TFVARS.write_text("\n".join(lines) + "\n", encoding="utf-8")


def xen_orchestra():
    saved = {**read_tfvars(REPO / "xo" / "terraform.tfvars.example"), **read_tfvars(TFVARS)}
    action = select("What do you want to do?", [
        Choice("Plan, then apply after you review the plan", "apply"),
        Choice("Plan only", "plan"),
        Choice("Destroy the lab", "destroy"),
        Choice("Only save the settings", "save"),
    ])

    url = text("XO websocket URL", saved.get("xoa_url"),
               lambda v: True if re.match(r"wss?://", v.strip()) else "Start with ws:// or wss://.")
    values = {
        "xoa_url": url,
        "xoa_user": text("XO admin account", saved.get("xoa_user")),
        "xoa_insecure": confirm("Skip TLS checks (self-signed XO certificate)?", saved.get("xoa_insecure", "true") == "true"),
        "vm_name": text("Ubuntu VM name prefix", saved.get("vm_name", "ubuntu-2404")),
        "vm_count": int(text("Ubuntu VMs", saved.get("vm_count", 3), whole_number(1))),
        "windows_vm_count": int(text("Windows 11 VMs", saved.get("windows_vm_count", 3), whole_number(0))),
    }
    keys = sorted(Path.home().joinpath(".ssh").glob("*.pub"))
    key_choices = [Choice("None", "")] + [Choice(k.name, k.read_text(encoding="utf-8").strip()) for k in keys]
    current = saved.get("vm_ssh_public_key", "")
    if current and current not in [c.value for c in key_choices]:
        key_choices.insert(1, Choice("The key already in terraform.tfvars", current))
    values["vm_ssh_public_key"] = select("SSH key for the Ubuntu user", key_choices,
                                         next((c for c in key_choices if c.value == current), None))

    # terraform.tfvars beats TF_VAR_ variables, so a password is either kept
    # in the file or left out of it and passed through the environment
    env = dict(os.environ)
    old = saved.get("xoa_password", "")
    if old and old != "CHANGE_ME" and confirm("Use the XO password already in terraform.tfvars?"):
        values["xoa_password"] = old
    else:
        env["TF_VAR_xoa_password"] = password("XO admin password (not saved)")

    shown = {k: v for k, v in values.items() if k != "xoa_password"}
    shown["vm_ssh_public_key"] = (shown["vm_ssh_public_key"][:40] + "…") if shown["vm_ssh_public_key"] else "None"
    settings_table("Xen Orchestra settings", list(shown.items()) + [("xoa_password", "hidden")])
    if not confirm(f"Save these to xo/terraform.tfvars{'' if action == 'save' else ' and continue'}?"):
        return
    write_tfvars(values)
    save_state()
    if action == "save":
        console.print("[green]Saved[/] xo/terraform.tfvars")
        return

    tf = ["terraform", "-chdir=xo"]
    show_fact()
    with console.status("Running terraform init", spinner="dots"):
        init = subprocess.run(tf + ["init", "-input=false"], cwd=REPO, env=env, capture_output=True, text=True)
    if init.returncode:
        console.print(init.stdout, init.stderr, markup=False)
        return result(init.returncode, "terraform init")

    if action == "destroy":
        # terraform lists what it will destroy and asks for "yes" itself
        return result(run(tf + ["destroy"], env), "terraform destroy")

    # The plan file holds variable values, including the password, so it is
    # deleted as soon as it has been used
    try:
        code = run(tf + ["plan", "-input=false", f"-out={PLAN}"], env)
        if code or action == "plan":
            return result(code, "terraform plan")
        if confirm("Apply this plan?", default=False):
            result(run(tf + ["apply", "-input=false", PLAN], env), "terraform apply")
        else:
            console.print("[grey62]Not applied. Nothing changed.[/]")
    finally:
        (REPO / "xo" / PLAN).unlink(missing_ok=True)


# --- Hyper-V ------------------------------------------------------------------

def hyper_v():
    modes = []
    if which("pwsh"):
        modes.append(Choice("From this workstation, over WinRM HTTPS (PowerShell 7.4)", "remote"))
    if IS_WINDOWS:
        modes.append(Choice("On this Hyper-V host (Windows PowerShell 5.1)", "local"))
    hv = state.setdefault("hyperv", {})
    mode = modes[0].value if len(modes) == 1 else select(
        "Where does the import run?", modes, next((c for c in modes if c.value == hv.get("mode")), None))

    name = ask_technician()
    rows = [("Runs", "remotely" if mode == "remote" else "on this host"), ("Technician", name)]
    if mode == "remote":
        host = text("Hyper-V host name or IP", hv.get("host"))
        rows.append(("Host", host))
    source = text("Golden exports on the host", hv.get("source", r"C:\Users\Public\Documents\Hyper-V\Golden"))
    destination = text("Lab VM folder on the host", hv.get("destination", r"C:\ProgramData\Microsoft\Windows\Hyper-V"))
    throttle = text("VMs imported at once (lower it on spinning disks)", hv.get("throttle", 3), whole_number(1, 16))
    rows += [("Source", source), ("Destination", destination), ("At once", throttle)]

    settings_table("Hyper-V import", rows)
    if not confirm("Start the import?"):
        return
    hv.update(mode=mode, source=source, destination=destination, throttle=int(throttle))
    args = ["-UserName", name, "-Source", source, "-Destination", destination, "-ThrottleLimit", throttle]

    if mode == "local":
        save_state()
        return result(run(powershell("hyper-v/import-golden-vms.ps1", *args)), "The import")
    hv["host"] = host
    save_state()
    try:
        with Bridge() as bridge:
            hyper_v_remote(bridge, host, name, source, destination, int(throttle))
    except HostError as error:
        console.print(Panel(Text(str(error)), title="PowerShell reported an error", title_align="left",
                            border_style="red", box=box.ROUNDED))


class HostError(Exception):
    """An error PowerShell reported, on the workstation or on the host"""


class Bridge:
    """The PowerShell 7 helper, hyper-v/JCLab.Bridge.ps1, which runs the
    certificate check, Get-Credential, the HTTPS session and the host
    functions. It shares this terminal, so Get-Credential prompts here, and
    the password stays in PowerShell as a SecureString.

    It connects back over loopback TCP and proves who it is with a token
    passed in its environment."""

    def __enter__(self):
        server = socket.create_server(("127.0.0.1", 0))
        token = secrets.token_hex(16)
        env = {**os.environ, "JCLAB_BRIDGE_PORT": str(server.getsockname()[1]), "JCLAB_BRIDGE_TOKEN": token}
        self.process = subprocess.Popen(powershell("hyper-v/JCLab.Bridge.ps1", edition="pwsh"), cwd=REPO, env=env)
        server.settimeout(60)
        try:
            connection = server.accept()[0]
        except socket.timeout:
            self.process.kill()
            raise HostError("The PowerShell helper didn't start. It needs PowerShell 7.4 or later.")
        finally:
            server.close()
        self.stream = connection.makefile("rw", encoding="utf-8", newline="\n")
        if self.stream.readline().strip() != token:
            self.process.kill()
            raise HostError("Something other than the PowerShell helper connected. Stopped.")
        return self

    def send(self, cmd, **fields):
        self.stream.write(json.dumps({"cmd": cmd, **fields}) + "\n")
        self.stream.flush()
        reply = json.loads(self.stream.readline() or '{"ok": false, "error": "The PowerShell helper stopped."}')
        if not reply["ok"]:
            raise HostError(reply["error"])
        return reply.get("result")

    def call(self, function, *args):
        """Runs a JCLab.Host.ps1 function on the host. Returns its output as a list."""
        return json.loads(self.send("call", function=function, args=list(args)))

    def __exit__(self, *_):
        try:
            self.send("close")
        except (HostError, OSError, ValueError):
            pass
        self.process.wait(timeout=30)


def hyper_v_remote(bridge, host, name, source, destination, throttle):
    """The remote import UI. Every host step runs through the bridge. hyper_v
    shows any HostError."""
    # 1. Validate the host's SSL certificate before asking for credentials
    with console.status(f"Checking the SSL certificate on {host}:5986", spinner="dots"):
        cert = bridge.send("check_cert", host=host)
    skip_cert = False
    if cert["status"] == "unreachable":
        console.print(f"[red]Couldn't reach a WinRM HTTPS listener on {host}:5986 to check its certificate.[/]")
        console.print(Text(cert["detail"], style="grey62"))
        console.print("Enable WinRM over HTTPS on the host (see docs/hyper-v.md), then try again.")
        return
    if cert["status"] == "invalid":
        console.print(f"[yellow]The SSL certificate on {host} isn't valid[/] (usually because it's self-signed):")
        console.print(Text(cert["detail"], style="grey62"))
        console.print("Skipping the checks keeps the connection encrypted, but no longer verifies that you reached the right host.")
        if not confirm("Skip certificate checks for this connection?", default=False):
            console.print("[grey62]Not connected. Install a trusted certificate on the host to connect without skipping.[/]")
            return
        skip_cert = True
    else:
        console.print(f"[green]SSL certificate is valid[/] for {host}")

    # 2. Only now ask for the account. PowerShell asks for the password.
    hv = state["hyperv"]
    hv["user"] = text("Administrator account on the host", hv.get("user"))
    save_state()
    console.print("[grey62]PowerShell asks for the password next. It stays in a SecureString and never reaches jclab.py.[/]")
    info = bridge.send("connect", host=host, user=hv["user"], skip_cert=skip_cert)
    console.print(f"[green]Connected[/] to [bold]{info['computer']}[/] ({info['scheme']}, {info['auth']})")

    with console.status("Reading golden exports on the host", spinner="dots"):
        lab = bridge.call("Get-LabState", source, destination, name)[0]
    plan = lab["Plan"]
    if lab["Skipped"]:
        print_table("Not part of the lab (skipped)", ("Export", "Reason"),
                    [(s["Export"], s["Reason"]) for s in lab["Skipped"]], "grey50")
    print_table("Deployment plan", ("Golden VM", "Deploys as", "Folder"), [(p["Name"], p["NewName"], p["Dir"]) for p in plan])

    plan = pre_deployment_check(bridge, lab)
    if plan:
        import_vms(bridge, plan, throttle)


def pre_deployment_check(bridge, lab):
    """Offers Cancel, Redeploy, Deploy missing or Delete if you already have
    lab VMs or folders. Returns the VMs to import."""
    existing, folders, missing, plan = lab["Existing"], lab["Folders"], lab["Missing"], lab["Plan"]
    if not (existing or folders):
        return plan
    if existing:
        print_table("You already have these VMs", ("Name", "State", "Checkpoints", "Path"),
                    [(vm["Name"], vm["State"], str(vm["Checkpoints"]), vm["Path"]) for vm in existing], "yellow")
    if folders:
        print_table("These folders already exist", ("Folder",), [(f,) for f in folders], "yellow")

    choices = [Choice("Cancel: change nothing", "cancel"),
               Choice("Redeploy: delete these VMs, disks and folders, then import fresh copies", "redeploy")]
    # Offer "Deploy missing" only when you have some of the lab but not all of it
    if existing and missing:
        print_table(f"Missing from your lab ({len(missing)} of {len(plan)})", ("Missing VM",),
                    [(p["NewName"],) for p in missing], "yellow")
        choices.append(Choice(f"Deploy missing: keep the VMs you have, import only the {len(missing)} missing", "missing"))
    choices.append(Choice("Delete: delete these VMs, disks and folders, then stop", "delete"))
    answer = select("Existing lab found. What do you want to do?", choices)

    if answer == "cancel":
        console.print("[grey62]Cancelled. Nothing changed.[/]")
        return []
    if answer == "missing":
        # Keep the existing VMs. Clear only the leftover folders, which belong
        # to missing VMs, so their imports start clean.
        if folders:
            bridge.call("Remove-LabFolder", folders)
        console.print(f"[green]Keeping your existing VMs.[/] Importing {len(missing)} missing.")
        return missing
    # Hyper-V's own order: VMs without checkpoints came first from the host
    with console.status("Deleting existing VMs through Hyper-V", spinner="dots"):
        for vm in existing:
            bridge.call("Remove-LabVM", vm["Id"])
            console.print(f"[red]Deleted[/] {vm['Name']}")
        bridge.call("Remove-LabFolder", [p["Dir"] for p in plan])
    console.print("[green]Existing lab removed.[/]")
    return [] if answer == "delete" else plan


FACT_SECONDS = 15


def import_vms(bridge, plan, throttle):
    """Imports up to `throttle` VMs at once in a live table, with a fact box
    below it, then prints the results"""
    status = {p["NewName"]: ("Queued", "grey62", 0) for p in plan}
    facts, fact_index, fact_since = load_facts(), 0, time.monotonic()
    results = []

    def view():
        table = make_table("Deploying lab VMs", ("Lab VM", "Progress", "Status"))
        for p in plan:
            label, colour, percent = status[p["NewName"]]
            # A copy has no percentage, so its bar pulses while it runs
            bar = ProgressBar(total=100, completed=percent, width=30, pulse=label == "Copying VM and disks")
            table.add_row(p["NewName"], bar, Text(label, style=colour))
        if not facts:
            return table
        elapsed = min(FACT_SECONDS, time.monotonic() - fact_since)
        timer = Table.grid(padding=(0, 1))
        timer.add_row(Text("Next fact", style="grey62"), ProgressBar(total=FACT_SECONDS, completed=elapsed, width=20),
                      Text(f"{int(100 * elapsed / FACT_SECONDS)}%", style="grey62"))
        return Group(table, fact_panel(facts[fact_index % len(facts)], timer))

    def finish(p, label, colour, message):
        status[p["NewName"]] = (label, colour, 100)
        results.append((p["NewName"], Text(message, style=colour)))

    queue, running = list(plan), {}   # running: host job ID -> plan entry
    with Live(view(), console=console, refresh_per_second=4) as live:
        while queue or running:
            # Start imports until the throttle limit is reached
            while queue and len(running) < throttle:
                p = queue.pop(0)
                try:
                    running[bridge.call("Start-LabImport", p["ConfigPath"], p["Dir"])[0]] = p
                    status[p["NewName"]] = ("Copying VM and disks", ACCENT, 10)
                except HostError as error:
                    finish(p, "Failed", "red", f"Failed: {error}")
            time.sleep(1)
            if running:
                for job in bridge.call("Get-FinishedLabImport", list(running)):
                    p = running.pop(job)
                    status[p["NewName"]] = ("Starting", ACCENT, 90)
                    live.update(view())
                    try:
                        bridge.call("Complete-LabImport", job, p["NewName"])
                        finish(p, "Imported and started", "green", "Imported and started")
                    except HostError as error:
                        finish(p, "Failed", "red", f"Failed: {error}")
            if facts and time.monotonic() - fact_since >= FACT_SECONDS:
                fact_index, fact_since = fact_index + 1, time.monotonic()
            live.update(view())
        facts = []   # the final frame shows the VM table only
        live.update(view())
    console.print()

    print_table("Results", ("VM", "Result"), results)


# --- UTM ----------------------------------------------------------------------

def utm():
    u = state.setdefault("utm", {})
    name = ask_technician()
    golden = text("Golden VM in UTM", u.get("golden", "JCLab-macOS-Golden"))
    u["golden"] = golden
    rows = [("Technician", name), ("Golden VM", golden), ("Deploys as", f"{name}_JCLab_macOS"),
            ("CPU / RAM", "4 cores, 4096 MiB")]

    if IS_MAC:
        rows.insert(0, ("Runs", "on this Mac"))
        command = ["zsh", str(REPO / "utm-qemu" / "deploy-macos-vm.zsh"), "-n", name, "-g", golden]
    else:
        # From Windows, through the SSH launcher
        u["host"] = text("Mac host name or IP", u.get("host"))
        u["user"] = text("Account on the Mac", u.get("user"))
        u["repo"] = text("Repo path on the Mac (relative to its home folder)", u.get("repo", "JumpCloud-Seeding"))
        rows[:0] = [("Runs", f"over SSH on {u['user']}@{u['host']}"), ("Repo on the Mac", u["repo"])]
        command = powershell("utm-qemu/deploy-macos-vm-remote.ps1", "-ComputerName", u["host"], "-User", u["user"],
                             "-RepoPath", u["repo"], "-UserName", name, "-Golden", golden)
        console.print("[grey62]On the first remote run, click Allow on the Mac's screen when macOS asks "
                      "whether SSH may control UTM.[/]")
    settings_table("UTM deployment", rows)
    if confirm("Deploy the VM?"):
        save_state()
        result(run(command), "The deployment")


# --- Menu ---------------------------------------------------------------------

def main():
    banner()
    ready = readiness()
    readiness_table(ready)
    flows = {"xo": xen_orchestra, "hyperv": hyper_v, "utm": utm}
    while True:
        choices = [Choice(LABELS[key], key, disabled=None if ready[key][0] else ready[key][1]) for key in flows]
        choices.append(Choice("Quit", "quit"))
        try:
            pick = select("Which hypervisor?", choices, next((c for c in choices if c.value == state.get("last") and not c.disabled), None))
        except KeyboardInterrupt:
            pick = "quit"
        if pick == "quit":
            console.print("[grey62]Bye.[/]")
            return
        state["last"] = pick
        console.rule(f"[bold {ACCENT}]{LABELS[pick]}[/]", style=ACCENT)
        try:
            flows[pick]()
        except KeyboardInterrupt:
            console.print("\n[grey62]Back to the menu.[/]")
        console.print()


if __name__ == "__main__":
    main()
