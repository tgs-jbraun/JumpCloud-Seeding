# Written with AI assistance: Claude Opus 5.5 (Anthropic), using Claude Code.

#Requires -Version 7.4
#Requires -Modules PwshSpectreConsole

# Remote-run copy of import-golden-vms.ps1 with a richer terminal UI. Run it
# on your workstation. It connects to the Hyper-V host over WinRM HTTPS, then
# imports every VM exported under C:\Users\Public\Documents\Hyper-V\Golden on the host, renames it to
# <name>_JumpCloud_Lab_<your name>, and starts it. The golden exports stay
# untouched.
#
# The UI comes from PwshSpectreConsole (MIT license, wraps Spectre.Console).
# It needs PowerShell 7.4 or later on your workstation only. The host needs
# nothing new. One-time setup on the workstation:
#   Install-Module PwshSpectreConsole -Scope CurrentUser
#
# Credentials: the script asks with Get-Credential, which keeps the password
# in a SecureString inside a PSCredential. It never converts the password to
# plain text, writes it anywhere, or accepts it as a plain-text parameter.
# It connects over HTTPS only (or a PSSession you pass that is encrypted),
# and drops its reference to the credential once connected.
#
# Examples:
#   .\import-golden-vms-remote.ps1
#   .\import-golden-vms-remote.ps1 -ComputerName hyperv01 -UserName jdoe
#   .\import-golden-vms-remote.ps1 -ComputerName hyperv01.example.local -SkipCertificateCheck   # self-signed cert
#   $s = New-PSSession -ComputerName hyperv01 -UseSSL; .\import-golden-vms-remote.ps1 -Session $s
param(
  [string]$ComputerName,
  # Pass a PSCredential, or a user name to be prompted for its password
  [pscredential][System.Management.Automation.Credential()]$Credential = [pscredential]::Empty,
  [switch]$SkipCertificateCheck,
  [System.Management.Automation.Runspaces.PSSession]$Session,
  [string]$UserName,
  [string]$Source = 'C:\Users\Public\Documents\Hyper-V\Golden',
  [string]$Destination = 'C:\ProgramData\Microsoft\Windows\Hyper-V'
)
$ErrorActionPreference = 'Stop'

function Esc($text) { Get-SpectreEscapedText -Text "$text" }

# --- Steps that run on the Hyper-V host ------------------------------------

# Finds the golden exports, the names they will get, and anything of yours
# already there. A VM counts as yours if it has a planned name, or if its
# files live in a planned destination folder (an interrupted run can leave a
# VM there under its golden name).
$remotePlan = {
  param($Source, $Destination, $UserName)
  $ErrorActionPreference = 'Stop'
  $configs = Get-ChildItem $Source -Recurse -Filter *.vmcx | Where-Object { $_.Directory.Name -eq 'Virtual Machines' }
  if (-not $configs) { throw "No exported VMs found under $Source" }
  $plan = @(foreach ($config in $configs) {
    $name = (Compare-VM -Path $config.FullName -Copy -GenerateNewId).VM.Name
    $newName = "${name}_JumpCloud_Lab_${UserName}"
    [pscustomobject]@{ ConfigPath = $config.FullName; Name = $name; NewName = $newName; Dir = Join-Path $Destination $newName }
  })
  $dirs = @($plan.Dir)
  function Test-InFolder($path, $dir) { $path -and "$path\".StartsWith("$dir\", [StringComparison]::OrdinalIgnoreCase) }
  $existing = @(Get-VM | Where-Object { $vm = $_; $plan.NewName -contains $vm.Name -or ($dirs | Where-Object { Test-InFolder $vm.Path $_ }) } |
    ForEach-Object { [pscustomobject]@{ Id = $_.Id.Guid; Name = $_.Name; State = "$($_.State)"; Path = $_.Path } })
  $folders = @(foreach ($dir in $dirs) {
    if ((Test-Path $dir) -and -not ($existing | Where-Object { Test-InFolder $_.Path $dir })) { $dir }
  })
  [pscustomobject]@{ Plan = $plan; Existing = $existing; Folders = $folders }
}

# Deletes one VM through Hyper-V, waiting for each step, then its disk files
$remoteDeleteVM = {
  param($VmId)
  $ErrorActionPreference = 'Stop'
  function Wait-Until($what, [scriptblock]$done) {
    $deadline = (Get-Date).AddMinutes(5)
    while (-not (& $done)) {
      if ((Get-Date) -gt $deadline) { throw "Timed out waiting for $what" }
      Start-Sleep -Seconds 2
    }
  }
  $vm = Get-VM -Id $VmId
  $disks = @(Get-VMHardDiskDrive -VM $vm | ForEach-Object Path)
  if ($vm.State -eq 'Saved') { Remove-VMSavedState -VM $vm }
  if ((Get-VM -Id $VmId).State -ne 'Off') {
    Stop-VM -VM $vm -TurnOff -Force
    Wait-Until "$($vm.Name) to turn off" { (Get-VM -Id $VmId).State -eq 'Off' }
  }
  # Delete checkpoints first. Remove-VM would merge them after the VM is gone,
  # keeping the disks locked.
  Get-VMSnapshot -VM $vm | Remove-VMSnapshot -IncludeAllChildSnapshots
  Wait-Until "$($vm.Name) checkpoints to merge" { (Get-VM -Id $VmId).OperationalStatus -notcontains 'MergingDisks' }
  Remove-VM -VM $vm -Force
  Wait-Until "$($vm.Name) to be removed" { -not (Get-VM -Id $VmId -ErrorAction SilentlyContinue) }
  # Remove-VM keeps the virtual disks
  $disks | Where-Object { $_ -and (Test-Path $_) } | Remove-Item -Force
}

$remoteDeleteFolders = {
  param($Dirs)
  foreach ($dir in $Dirs | Where-Object { Test-Path $_ }) { Remove-Item $dir -Recurse -Force }
}

# Compatibility check with the same arguments as the import. Returns the
# problems, usually a virtual switch that doesn't exist on the host.
$remoteCheck = {
  param($ConfigPath, $Dir)
  $ErrorActionPreference = 'Stop'
  $report = Compare-VM -Path $ConfigPath -Copy -GenerateNewId -VirtualMachinePath $Dir -SnapshotFilePath $Dir `
    -SmartPagingFilePath $Dir -VhdDestinationPath (Join-Path $Dir 'Virtual Hard Disks')
  @($report.Incompatibilities.Message)
}

# Copy import (never in-place registration) with every file under $Dir, then
# confirm nothing points at the golden export or a default location
$remoteImport = {
  param($ConfigPath, $Dir)
  $ErrorActionPreference = 'Stop'
  $vm = Import-VM -Path $ConfigPath -Copy -GenerateNewId -VirtualMachinePath $Dir -SnapshotFilePath $Dir `
    -SmartPagingFilePath $Dir -VhdDestinationPath (Join-Path $Dir 'Virtual Hard Disks')
  $outside = @($vm.ConfigurationLocation, $vm.SnapshotFileLocation, $vm.SmartPagingFilePath) +
    @(Get-VMHardDiskDrive -VM $vm | ForEach-Object Path) |
    Where-Object { $_ -and -not $_.StartsWith($Dir, [StringComparison]::OrdinalIgnoreCase) }
  if ($outside) {
    Remove-VM -VM $vm -Force
    throw "imported files are outside ${Dir}: $($outside -join ', '). Removed the VM."
  }
  $vm.Id.Guid
}

$remoteStart = {
  param($VmId, $NewName)
  $ErrorActionPreference = 'Stop'
  $vm = Get-VM -Id $VmId
  Rename-VM -VM $vm -NewName $NewName
  Start-VM -VM $vm
}

# --- Local UI ---------------------------------------------------------------

Write-SpectreFigletText -Text 'JumpCloud Lab' -Alignment Center -Color DeepSkyBlue1
Write-SpectreRule -Title 'Hyper-V golden VM import (remote)' -Alignment Center -Color Grey

# Plain text prompts use Read-Host, as the PwshSpectreConsole docs advise
if (-not $UserName) { $UserName = Read-Host 'Your name (added to each VM name)' }
$UserName = $UserName.Trim() -replace '\s+', '-'
if (-not $UserName) { throw 'No name given. Enter a name or pass -UserName.' }
if ($UserName.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0) { throw "Name '$UserName' contains characters not allowed in folder names" }

$ownSession = -not $Session
if ($ownSession) {
  if (-not $ComputerName) { $ComputerName = Read-Host 'Hyper-V host name or IP' }
  if ($Credential -eq [pscredential]::Empty) {
    $Credential = Get-Credential -Message "Administrator account on $ComputerName"
  }
  $connect = @{ ComputerName = $ComputerName; UseSSL = $true; Credential = $Credential }
  if ($SkipCertificateCheck) { $connect.SessionOption = New-PSSessionOption -SkipCACheck -SkipCNCheck }
  $Session = Invoke-SpectreCommandWithStatus -Spinner Dots2 -Title "Connecting to $(Esc $ComputerName) over HTTPS" -ScriptBlock {
    New-PSSession @connect
  }
  # The session is authenticated. Drop the credential so it isn't kept around.
  $Credential = $null; $connect = $null
}

try {
  $info = $Session.Runspace.ConnectionInfo
  if ($info.AuthenticationMechanism -eq 'Basic' -and $info.Scheme -ne 'https') {
    throw 'Refusing an unencrypted session (Basic auth over HTTP). Connect with -UseSSL instead.'
  }
  Write-SpectreHost "[green]Connected[/] to [bold]$(Esc $Session.ComputerName)[/] ($(Esc $info.Scheme), $(Esc $info.AuthenticationMechanism))"

  $state = Invoke-SpectreCommandWithStatus -Spinner Dots2 -Title 'Reading golden exports on the host' -ScriptBlock {
    Invoke-Command -Session $Session -ScriptBlock $remotePlan -ArgumentList $Source, $Destination, $UserName
  }
  $plan = @($state.Plan)
  $plan | ForEach-Object { [pscustomobject]@{ 'Golden VM' = $_.Name; 'Deploys as' = $_.NewName; 'Folder' = $_.Dir } } |
    Format-SpectreTable -Title 'Deployment plan' -Color DeepSkyBlue1

  # Pre-deployment check
  if ($state.Existing -or $state.Folders) {
    if ($state.Existing) {
      $state.Existing | Select-Object Name, State, Path | Format-SpectreTable -Title 'You already have these VMs' -Color Yellow
    }
    if ($state.Folders) {
      $state.Folders | ForEach-Object { [pscustomobject]@{ Folder = $_ } } | Format-SpectreTable -Title 'These folders already exist' -Color Yellow
    }
    $cancel = 'Cancel: change nothing'
    $redeploy = 'Redeploy: delete these VMs, disks and folders, then import fresh copies'
    $delete = 'Delete: delete these VMs, disks and folders, then stop'
    $answer = Read-SpectreSelection -Message 'Existing lab found. What do you want to do?' -Choices $cancel, $redeploy, $delete -Color Yellow
    if (-not $answer -or $answer -eq $cancel) { Write-SpectreHost '[grey]Cancelled. Nothing changed.[/]'; return }

    Invoke-SpectreCommandWithStatus -Spinner Dots2 -Title 'Deleting existing VMs through Hyper-V' -ScriptBlock {
      foreach ($vm in $state.Existing) {
        Invoke-Command -Session $Session -ScriptBlock $remoteDeleteVM -ArgumentList $vm.Id
        Write-SpectreHost "[red]Deleted[/] $(Esc $vm.Name)"
      }
      Invoke-Command -Session $Session -ScriptBlock $remoteDeleteFolders -ArgumentList (, @($plan.Dir))
    }
    Write-SpectreHost '[green]Existing lab removed.[/]'
    if ($answer -eq $delete) { return }
  }

  # Import: one progress bar per VM. Results print after the bars finish.
  $results = [System.Collections.Generic.List[object]]::new()
  Invoke-SpectreCommandWithProgress -ScriptBlock {
    param([Spectre.Console.ProgressContext]$Context)
    $tasks = @{}
    foreach ($p in $plan) { $tasks[$p.NewName] = $Context.AddTask((Esc $p.NewName)) }
    foreach ($p in $plan) {
      $task = $tasks[$p.NewName]
      try {
        $problems = @(Invoke-Command -Session $Session -ScriptBlock $remoteCheck -ArgumentList $p.ConfigPath, $p.Dir)
        $task.Increment(10)
        if ($problems) {
          $results.Add([pscustomobject]@{ VM = (Esc $p.NewName); Result = "[yellow]Skipped[/]: $(Esc ($problems -join '; '))" })
          $task.Value = 100
          continue
        }
        $id = Invoke-Command -Session $Session -ScriptBlock $remoteImport -ArgumentList $p.ConfigPath, $p.Dir
        $task.Increment(80)
        Invoke-Command -Session $Session -ScriptBlock $remoteStart -ArgumentList $id, $p.NewName
        $task.Increment(10)
        $results.Add([pscustomobject]@{ VM = (Esc $p.NewName); Result = '[green]Imported and started[/]' })
      }
      catch {
        $results.Add([pscustomobject]@{ VM = (Esc $p.NewName); Result = "[red]Failed[/]: $(Esc $_.Exception.Message)" })
        $task.Value = 100
      }
    }
  }
  $results | Format-SpectreTable -Title 'Results' -AllowMarkup -Color DeepSkyBlue1
}
finally {
  if ($ownSession -and $Session) { Remove-PSSession $Session }
}
