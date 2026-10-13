#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Generates a dedicated SSH keypair for the dotnet10-dev-container and drops
  the public half into this directory as `authorized_keys` so the Dockerfile
  can bake it into the image.

.PARAMETER KeyPath
  Where to write the private key. Defaults to ~/.ssh/id_dotnet10dev_ed25519.

.EXAMPLE
  ./generate-keys.ps1
#>
param(
  [string]$KeyPath = (Join-Path $HOME ".ssh/id_dotnet10dev_ed25519")
)

$ErrorActionPreference = "Stop"

$scriptDir = $PSScriptRoot
$keyDir = Split-Path -Parent $KeyPath

if (Test-Path $KeyPath) {
  Write-Host "Key already exists at $KeyPath - skipping generation."
} else {
    if (-not (Test-Path $keyDir)) {
        New-Item -ItemType Directory -Path $keyDir -Force | Out-Null
    }
    # Legacy PowerShell drops empty native arguments; modern argument passing
    # preserves them and would treat '""' as a literal two-character passphrase.
    $argumentPassing = Get-Variable PSNativeCommandArgumentPassing -ErrorAction SilentlyContinue
    $emptyPassphrase = if ($argumentPassing -and $argumentPassing.Value -ne "Legacy") { "" } else { '""' }
    ssh-keygen -t ed25519 -f $KeyPath -C "dotnet10-dev-container" -N $emptyPassphrase
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to generate SSH key at '$KeyPath'."
    }
}

$authorizedKeys = Join-Path $scriptDir "authorized_keys"

# Write with LF endings: this file is consumed by sshd inside the Linux
# container, and a plain Copy-Item would carry Windows CRLFs into the image.
$publicKey = (Get-Content -Path "$KeyPath.pub" -Raw).Replace("`r`n", "`n").TrimEnd("`n") + "`n"
[System.IO.File]::WriteAllText($authorizedKeys, $publicKey, (New-Object System.Text.UTF8Encoding $false))

Write-Host ""
Write-Host "Public key written to: $authorizedKeys"
Write-Host "Private key stays at:  $KeyPath"
Write-Host ""
Write-Host "Next: docker build -t dotnet10-dev-container ."
Write-Host "Then: ssh -i $KeyPath -p 2222 dev@localhost"
