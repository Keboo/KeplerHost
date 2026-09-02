#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Builds the dotnet10-dev-container image and starts it, publishing SSH on
  localhost:2222. Run generate-keys.ps1 first so authorized_keys exists.

.EXAMPLE
  ./up.ps1
#>
param(
    [string]$ImageName = "dotnet10-dev-container",
    [string]$ContainerName = "dotnet10-dev",
    [int]$SshPort = 2222
)

$ErrorActionPreference = "Stop"
$scriptDir = $PSScriptRoot

if (-not (Test-Path (Join-Path $scriptDir "authorized_keys"))) {
    throw "authorized_keys not found run ./generate-keys.ps1 first."
}

docker build -t $ImageName $scriptDir

docker rm -f $ContainerName 2>$null | Out-Null

docker run -d --name $ContainerName -p "${SshPort}:22" $ImageName

Write-Host ""
Write-Host "Container '$ContainerName' is up."
Write-Host "Connect with: ssh -i ~/.ssh/id_dotnet10dev_ed25519 -p $SshPort dev@localhost"
