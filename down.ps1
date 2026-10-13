#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Stops and removes the dotnet10-dev-container, retaining its SSH host-key
  volume so the next start has the same server identity.

.EXAMPLE
  ./down.ps1
#>
param(
    [string]$ContainerName = "dotnet10-dev"
)

$ErrorActionPreference = "Stop"

docker rm -f $ContainerName
if ($LASTEXITCODE -ne 0) {
    throw "Failed to remove container '$ContainerName'."
}

Write-Host "Container '$ContainerName' removed."
Write-Host "SSH host-key volume '${ContainerName}-ssh-host-keys' retained."
