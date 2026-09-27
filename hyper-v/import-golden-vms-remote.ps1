# Written with AI assistance: Claude Opus 5.5 (Anthropic), using Claude Code.

#Requires -Version 7.4
#Requires -Modules PwshSpectreConsole

# Remote-run copy of import-golden-vms.ps1 with a richer terminal UI. Run it
# on your workstation. It connects to the Hyper-V host over WinRM HTTPS, then
# imports every VM exported under C:\Users\Public\Documents\Hyper-V\Golden on the host, renames it to
# <your name>_JCLab_<name>, and starts it. The golden exports stay
# untouched.
#
# The UI comes from PwshSpectreConsole (MIT license, wraps Spectre.Console).
# It needs PowerShell 7.4 or later on your workstation only. The host needs
# nothing new. One-time setup on the workstation:
#   Install-Module PwshSpectreConsole -Scope CurrentUser
#
# Before it asks for credentials, the script validates the host's SSL
# certificate on the WinRM HTTPS listener (port 5986).
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
#   .\import-golden-vms-remote.ps1 -ComputerName hyperv01.example.local -SkipCertificateCheck   # self-signed cert, no prompt
#
# If the host's certificate isn't trusted (for example, self-signed), the
# script explains the error and asks whether to skip certificate checks.
# The default answer is No.
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

# Pop-culture facts shown in a box below the VM table during the copy, in random
# order. Each line of the file is "sentence | sentence | source".
$factsFile = Join-Path $PSScriptRoot 'pop-culture-facts.txt'
$facts = @(if (Test-Path $factsFile) {
  Get-Content $factsFile | Where-Object { $_ -and $_ -notmatch '^\s*#' } |
    ForEach-Object { $s = $_ -split '\s*\|\s*'; [pscustomobject]@{ One = $s[0]; Two = $s[1] } }
})
if ($facts) { $facts = @($facts | Get-Random -Count $facts.Count) }
$nextFact = 0

# --- Steps that run on the Hyper-V host ------------------------------------

# Finds the golden exports, the names they will get, and anything of yours
# already there. A VM counts as yours if it has a planned name, or if its
# files live in a planned destination folder (an interrupted run can leave a
# VM there under its golden name).
$remotePlan = {
  param($Source, $Destination, $UserName)
  $ErrorActionPreference = 'Stop'
  $configs = Get-ChildItem $Source -Recurse -Filter *.vmcx | Where-Object { $_.Directory.Name -eq 'Virtual Machines' }
  # Skip folders that a VM registered on this host runs from, such as a
  # permanent VM kept under the golden folder. It isn't a lab export, and
  # Hyper-V keeps its files locked.
  $vmFiles = @(Get-VM | ForEach-Object { $_.ConfigurationLocation; Get-VMHardDiskDrive -VM $_ | ForEach-Object Path })
  $skipped = [System.Collections.Generic.List[object]]::new()
  $configs = @(foreach ($config in $configs) {
    $folder = $config.Directory.Parent.FullName
    if ($vmFiles | Where-Object { "$_\".StartsWith("$folder\", [StringComparison]::OrdinalIgnoreCase) }) {
      $skipped.Add([pscustomobject]@{ Export = $config.Directory.Parent.Name; Reason = "A VM on this host runs from $folder" })
    }
    else { $config }
  })
  if (-not $configs) { throw "No exported VMs found under $Source" }
  $plan = @(foreach ($config in $configs) {
    # Export-VM names the export folder after the VM. Compare-VM would copy the
    # export's files just to report the name, and fails if one is locked.
    $name = $config.Directory.Parent.Name
    $newName = "${UserName}_JCLab_${name}"
    [pscustomobject]@{ ConfigPath = $config.FullName; Name = $name; NewName = $newName; Dir = Join-Path $Destination $newName }
  })
  $dirs = @($plan.Dir)
  function Test-InFolder($path, $dir) { $path -and "$path\".StartsWith("$dir\", [StringComparison]::OrdinalIgnoreCase) }
  $existing = @(Get-VM | Where-Object { $vm = $_; $plan.NewName -contains $vm.Name -or ($dirs | Where-Object { Test-InFolder $vm.Path $_ }) } |
    ForEach-Object { [pscustomobject]@{ Id = $_.Id.Guid; Name = $_.Name; State = "$($_.State)"; Checkpoints = @(Get-VMSnapshot -VM $_).Count; Path = $_.Path } } |
    # VMs without checkpoints first, so the slow checkpoint merges run last
    Sort-Object { $_.Checkpoints -gt 0 })
  $folders = @(foreach ($dir in $dirs) {
    if ((Test-Path $dir) -and -not ($existing | Where-Object { Test-InFolder $_.Path $dir })) { $dir }
  })
  [pscustomobject]@{ Plan = $plan; Existing = $existing; Folders = $folders; Skipped = @($skipped) }
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

  # 1. Validate the host's SSL certificate before asking for credentials.
  # Test-WSMan -UseSSL makes a TLS connection to the WinRM HTTPS listener
  # (port 5986) without logging in. Windows rejects the certificate if it's
  # self-signed or from an untrusted authority, expired, revoked or
  # unverifiable, or issued for a different host name.
  $certError = $null
  Invoke-SpectreCommandWithStatus -Spinner Dots2 -Title "Checking the SSL certificate on $(Esc $ComputerName):5986" -ScriptBlock {
    try { Test-WSMan -ComputerName $ComputerName -UseSSL | Out-Null }
    catch { $script:certError = ($_ | Out-String).Trim() }
  }
  $certInvalid = $certError -match 'certificate'
  # Any other failure (except "access denied", which comes after the TLS
  # handshake) means no certificate could be checked at all
  if ($certError -and -not $certInvalid -and $certError -notmatch 'Access is denied') {
    Write-SpectreHost "[red]Couldn't reach a WinRM HTTPS listener on $(Esc $ComputerName):5986 to check its certificate.[/]"
    Write-SpectreHost "[grey]$(Esc $certError)[/]"
    throw 'Not connected. Enable WinRM over HTTPS on the host (see the README), then run the script again.'
  }
  if (-not $certInvalid) { Write-SpectreHost "[green]SSL certificate is valid[/] for $(Esc $ComputerName)" }

  # 2. Invalid certificate: show why and offer to skip the checks, default No
  if ($certInvalid -and -not $SkipCertificateCheck) {
    Write-SpectreHost "[yellow]The SSL certificate on $(Esc $ComputerName) isn't valid[/] (usually because it's self-signed):"
    Write-SpectreHost "[grey]$(Esc $certError)[/]"
    Write-SpectreHost 'Skipping the checks keeps the connection encrypted, but no longer verifies that you reached the right host.'
    if ((Read-SpectreConfirm -Message 'Skip certificate checks for this connection?' -DefaultAnswer n) -ne $true) {
      throw 'Not connected: the certificate is not valid. Install a trusted certificate on the host, or rerun with -SkipCertificateCheck.'
    }
    $SkipCertificateCheck = $true
  }

  # 3. Only now ask for the host's administrator account
  if ($Credential -eq [pscredential]::Empty) {
    $Credential = Get-Credential -Message "Administrator account on $ComputerName"
  }
  $connect = @{ ComputerName = $ComputerName; UseSSL = $true; Credential = $Credential }
  if ($SkipCertificateCheck) { $connect.SessionOption = New-PSSessionOption -SkipCACheck -SkipCNCheck -SkipRevocationCheck }
  $Session = Invoke-SpectreCommandWithStatus -Spinner Dots2 -Title "Connecting to $(Esc $ComputerName) over HTTPS" -ScriptBlock {
    New-PSSession @connect
  }
  # The session is authenticated. Drop the credential so it isn't kept around.
  # Remove the variable instead of assigning $null: the [Credential()]
  # attribute stays on $Credential, and assigning $null prompts again.
  Remove-Variable -Name Credential, connect
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
  if ($state.Skipped) {
    $state.Skipped | Select-Object Export, Reason | Format-SpectreTable -Title 'Not part of the lab (skipped)' -Color Grey
  }
  $plan | ForEach-Object { [pscustomobject]@{ 'Golden VM' = $_.Name; 'Deploys as' = $_.NewName; 'Folder' = $_.Dir } } |
    Format-SpectreTable -Title 'Deployment plan' -Color DeepSkyBlue1

  # Pre-deployment check
  if ($state.Existing -or $state.Folders) {
    if ($state.Existing) {
      $state.Existing | Select-Object Name, State, Checkpoints, Path | Format-SpectreTable -Title 'You already have these VMs' -Color Yellow
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

  # Import. A live view shows the VMs in their own table and the pop-culture
  # fact in a separate box below it, so the fact can't be mistaken for a VM.
  # Results print after the live view ends.
  $results = [System.Collections.Generic.List[object]]::new()
  $vmState = @{}
  foreach ($p in $plan) { $vmState[$p.NewName] = @{ Percent = 0; Status = '[grey]Queued[/]' } }
  $factSeconds = 15
  $fact = $null
  $factShownAt = Get-Date

  # Text progress bar: a line of box-drawing characters filled to the percent
  function Get-Bar($percent, $width) {
    $filled = [int][Math]::Round($width * $percent / 100)
    $line = [string][char]0x2501
    "[deepskyblue1]$($line * $filled)[/][grey]$($line * ($width - $filled))[/] $([int]$percent)%"
  }
  function Show-Fact {
    if (-not $facts) { return }
    $script:fact = $facts[$script:nextFact++ % $facts.Count]
    $script:factShownAt = Get-Date
  }
  function Get-LiveView {
    $table = @(foreach ($p in $plan) {
      $s = $vmState[$p.NewName]
      [pscustomobject]@{ 'Lab VM' = (Esc $p.NewName); Progress = (Get-Bar $s.Percent 30); Status = $s.Status }
    }) | Format-SpectreTable -AllowMarkup -Title 'Deploying lab VMs' -Color DeepSkyBlue1
    if (-not $fact) { return $table }
    # The box's bar counts up to the next fact, 0% to 100% in $factSeconds
    $elapsed = [Math]::Min($factSeconds, ((Get-Date) - $factShownAt).TotalSeconds)
    $factBox = "$(Esc $fact.One)`n[grey]$(Esc $fact.Two)[/]`n`n[grey]Next fact[/]  $(Get-Bar (100 * $elapsed / $factSeconds) 20)" |
      Format-SpectrePanel -Header 'While you wait: did you know?' -Border Rounded -Color Grey
    @($table, $factBox) | Format-SpectreRows
  }

  Show-Fact
  Invoke-SpectreLive -Data (Get-LiveView) -ScriptBlock {
    param([Spectre.Console.LiveDisplayContext]$Context)
    # Sets one VM's row (if named), moves to the next fact when its time is
    # up, and redraws
    function Update-View($name, $percent, $status) {
      if ($name) { $vmState[$name].Percent = $percent; $vmState[$name].Status = $status }
      if ($fact -and ((Get-Date) - $factShownAt).TotalSeconds -ge $factSeconds) { Show-Fact }
      $Context.UpdateTarget((Get-LiveView))
      $Context.Refresh()
    }

    foreach ($p in $plan) {
      $n = $p.NewName
      try {
        Update-View $n 0 '[yellow]Checking[/]'
        $problems = @(Invoke-Command -Session $Session -ScriptBlock $remoteCheck -ArgumentList $p.ConfigPath, $p.Dir)
        if ($problems) {
          Update-View $n 100 '[yellow]Skipped[/]'
          $results.Add([pscustomobject]@{ VM = (Esc $n); Result = "[yellow]Skipped[/]: $(Esc ($problems -join '; '))" })
          continue
        }
        Update-View $n 10 '[deepskyblue1]Copying VM and disks[/]'
        # Run the copy as a job so the view can redraw once a second meanwhile
        $job = Invoke-Command -Session $Session -ScriptBlock $remoteImport -ArgumentList $p.ConfigPath, $p.Dir -AsJob
        while (-not (Wait-Job $job -Timeout 1)) { Update-View }
        $id = Receive-Job $job -Wait -AutoRemoveJob
        Update-View $n 90 '[deepskyblue1]Starting[/]'
        Invoke-Command -Session $Session -ScriptBlock $remoteStart -ArgumentList $id, $p.NewName
        Update-View $n 100 '[green]Imported and started[/]'
        $results.Add([pscustomobject]@{ VM = (Esc $n); Result = '[green]Imported and started[/]' })
      }
      catch {
        Update-View $n 100 '[red]Failed[/]'
        $results.Add([pscustomobject]@{ VM = (Esc $n); Result = "[red]Failed[/]: $(Esc $_.Exception.Message)" })
      }
    }
    # Final frame: the VM table only
    $script:fact = $null
    Update-View
  }
  $results | Format-SpectreTable -Title 'Results' -AllowMarkup -Color DeepSkyBlue1
}
finally {
  if ($ownSession -and $Session) { Remove-PSSession $Session }
}
