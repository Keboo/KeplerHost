#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Stops and removes the dotnet10-dev-container.

.EXAMPLE
  ./down.ps1
#>
param(
    [string]$ContainerName = "dotnet10-dev"
)

$ErrorActionPreference = "Stop"

docker rm -f $ContainerName

Write-Host "Container '$ContainerName' removed."
