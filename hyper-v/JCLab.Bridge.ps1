# Written with AI assistance: Claude Opus 5.5 (Anthropic), using Claude Code.

#Requires -Version 7.4

# PowerShell side of jclab.py's remote Hyper-V import. jclab.py draws the
# whole UI. This helper runs only the PowerShell calls: the certificate check,
# Get-Credential, the HTTPS session, and the host functions in
# JCLab.Host.ps1. Don't run it yourself. jclab.py starts it.
#
# It shares jclab.py's terminal, so Get-Credential prompts there, and the
# password stays in a SecureString inside this process. It never reaches
# jclab.py.
#
# Commands arrive as JSON lines over a loopback TCP connection to the port
# jclab.py passes in JCLAB_BRIDGE_PORT. The helper sends JCLAB_BRIDGE_TOKEN
# first, so jclab.py knows it is talking to the process it started. Each
# reply is {"ok": true, "result": ...} or {"ok": false, "error": "..."}.
$ErrorActionPreference = 'Stop'

# The host functions jclab.py may call, from JCLab.Host.ps1
$allowed = 'Get-LabState', 'Remove-LabVM', 'Remove-LabFolder', 'New-LabSwitch', 'Remove-LabSwitch', 'Start-LabImport', 'Get-FinishedLabImport', 'Complete-LabImport'
$session = $null

function Test-Certificate($ComputerName) {
  # Test-WSMan -UseSSL makes a TLS connection to the WinRM HTTPS listener
  # (port 5986) without logging in. Windows rejects the certificate if it's
  # self-signed or from an untrusted authority, expired, revoked or
  # unverifiable, or issued for a different host name. "Access is denied"
  # comes after the TLS handshake, so the certificate passed.
  try { Test-WSMan -ComputerName $ComputerName -UseSSL | Out-Null; return @{ status = 'valid' } }
  catch {
    $detail = ($_ | Out-String).Trim()
    if ($detail -match 'certificate') { return @{ status = 'invalid'; detail = $detail } }
    if ($detail -match 'Access is denied') { return @{ status = 'valid' } }
    return @{ status = 'unreachable'; detail = $detail }
  }
}

function Connect-Lab($ComputerName, $UserName, $SkipCertificateCheck) {
  # Get-Credential keeps the password in a SecureString. It is never
  # converted to plain text, and the variable is removed once connected.
  $credential = Get-Credential -UserName $UserName -Message "Administrator account on $ComputerName"
  $connect = @{ ComputerName = $ComputerName; UseSSL = $true; Credential = $credential }
  if ($SkipCertificateCheck) { $connect.SessionOption = New-PSSessionOption -SkipCACheck -SkipCNCheck -SkipRevocationCheck }
  $script:session = New-PSSession @connect
  Remove-Variable credential, connect

  # Load the host functions into the session, at its global scope so they
  # stay defined for later calls
  Invoke-Command -Session $session -ScriptBlock ([scriptblock]::Create((Get-Content -Raw (Join-Path $PSScriptRoot 'JCLab.Host.ps1'))))
  $info = $session.Runspace.ConnectionInfo
  @{ computer = $session.ComputerName; scheme = "$($info.Scheme)"; auth = "$($info.AuthenticationMechanism)" }
}

$client = [System.Net.Sockets.TcpClient]::new('127.0.0.1', [int]$env:JCLAB_BRIDGE_PORT)
$utf8 = [System.Text.UTF8Encoding]::new($false)
$reader = [System.IO.StreamReader]::new($client.GetStream(), $utf8)
$writer = [System.IO.StreamWriter]::new($client.GetStream(), $utf8)
$writer.AutoFlush = $true
$writer.WriteLine($env:JCLAB_BRIDGE_TOKEN)

try {
  while ($null -ne ($line = $reader.ReadLine())) {
    $request = $line | ConvertFrom-Json
    try {
      $result = switch ($request.cmd) {
        'check_cert' { Test-Certificate $request.host }
        'connect'    { Connect-Lab $request.host $request.user $request.skip_cert }
        'call' {
          if ($request.function -notin $allowed) { throw "Not an allowed host function: $($request.function)" }
          # The host converts its own output to JSON, before remoting adds
          # PSComputerName and similar properties. Always a list, so jclab.py
          # gets the same shape for 0, 1 or more results.
          [string](Invoke-Command -Session $session -ArgumentList $request.function, @($request.args) -ScriptBlock {
            param($f, $a)
            ConvertTo-Json -InputObject @(& $f @a) -Depth 8 -Compress
          })
        }
      }
      $writer.WriteLine((@{ ok = $true; result = $result } | ConvertTo-Json -Depth 8 -Compress))
    }
    catch { $writer.WriteLine((@{ ok = $false; error = $_.Exception.Message } | ConvertTo-Json -Compress)) }
    if ($request.cmd -eq 'close') { break }
  }
}
finally {
  if ($session) { Remove-PSSession $session }
  $client.Dispose()
}
