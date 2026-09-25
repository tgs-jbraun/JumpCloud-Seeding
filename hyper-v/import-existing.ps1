# Writes imports.tf with an import block for every planned resource that
# already exists on the Hyper-V host, so the next plan adopts it instead of
# failing on "already exists".
#
# Usage, from hyper-v/:
#   .\import-existing.ps1       # prompts for the host credentials
#   terraform plan              # review: imports, then any changes to them
#   terraform apply
#   Remove-Item imports.tf      # an import block fails once its object is gone
param(
  [string]$HyperVHost = (Select-String -Path terraform.tfvars -Pattern '^\s*hyperv_host\s*=\s*"(.+)"').Matches.Groups[1].Value
)
$ErrorActionPreference = 'Stop'

# Resources the plan would create, with the ID the provider imports them by
Remove-Item imports.tf -ErrorAction SilentlyContinue
terraform plan -out import.tfplan | Out-Null
if ($LASTEXITCODE) { throw 'terraform plan failed' }
$changes = (terraform show -json import.tfplan | ConvertFrom-Json).resource_changes
Remove-Item import.tfplan

$idAttr = @{
  hyperv_machine_instance = 'name'
  hyperv_network_switch   = 'name'
  hyperv_vhd              = 'path'
  hyperv_iso_image        = 'destination_iso_file_path'
}
$planned = foreach ($c in $changes) {
  if ($c.change.actions -contains 'create' -and $idAttr[$c.type]) {
    [pscustomobject]@{ Address = $c.address; Type = $c.type; Id = $c.change.after.($idAttr[$c.type]) }
  }
}

# Same WinRM connection the provider uses (HTTPS, self-signed cert allowed)
$existing = Invoke-Command -ComputerName $HyperVHost -Port 5986 -UseSSL `
  -SessionOption (New-PSSessionOption -SkipCACheck -SkipCNCheck) `
  -Credential (Get-Credential -Message "Hyper-V host $HyperVHost") `
  -ArgumentList (, $planned) -ScriptBlock {
  param($planned)
  foreach ($p in $planned) {
    $found = switch ($p.Type) {
      hyperv_machine_instance { [bool](Get-VM -Name $p.Id -ErrorAction SilentlyContinue) }
      hyperv_network_switch   { [bool](Get-VMSwitch -Name $p.Id -ErrorAction SilentlyContinue) }
      default                 { Test-Path $p.Id }
    }
    if ($found) { $p }
  }
}

if (-not $existing) { Write-Host 'Nothing to import.'; return }
$existing | ForEach-Object { "import {`n  to = $($_.Address)`n  id = `"$($_.Id)`"`n}`n" } | Set-Content imports.tf
Write-Host "Wrote imports.tf with $(@($existing).Count) import block(s):"
$existing | ForEach-Object { "  $($_.Address)" }
