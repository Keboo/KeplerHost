#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Tears down the Azure Container Instance created by azure-up.ps1.

.DESCRIPTION
  By default this only deletes the container instance (billing for ACI stops
  when the container group is gone), leaving the registry so the next
  ./azure-up.ps1 is a fast incremental build.

  Use -IncludeRegistry to also delete the ACR, or -DeleteResourceGroup to
  delete the whole resource group and everything in it.

.EXAMPLE
  ./azure-down.ps1

.EXAMPLE
  ./azure-down.ps1 -DeleteResourceGroup
#>
param(
    [string]$ResourceGroup = "dotnet10-dev-rg",
    [string]$ContainerName = "dotnet10-dev",
    [string]$RegistryName,
    [switch]$IncludeRegistry,
    [switch]$DeleteResourceGroup,
    [switch]$Force
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "azure-common.ps1")

Assert-AzureCli

if (-not $RegistryName) { $RegistryName = Get-DefaultRegistryName -ResourceGroup $ResourceGroup }

if ($DeleteResourceGroup) {
    if (-not $Force) {
        $answer = Read-Host "Delete the ENTIRE resource group '$ResourceGroup' and all resources in it? (y/N)"
        if ($answer -notmatch '^(y|yes)$') {
            Write-Host "Aborted."
            return
        }
    }

    Write-Host "==> Deleting resource group '$ResourceGroup'..."
    az group delete --name $ResourceGroup --yes --output none
    Write-Host "Resource group '$ResourceGroup' deleted."
    return
}

$groupExists = az group exists --name $ResourceGroup -o tsv
if ($groupExists -ne "true") {
    Write-Host "Resource group '$ResourceGroup' does not exist - nothing to do."
    return
}

$containerExists = Test-ContainerGroupExists -ResourceGroup $ResourceGroup -ContainerName $ContainerName
if ($containerExists) {
    Write-Host "==> Deleting container instance '$ContainerName'..."
    az container delete --name $ContainerName --resource-group $ResourceGroup --yes --output none
    Write-Host "Container instance '$ContainerName' deleted."
}
else {
    Write-Host "Container instance '$ContainerName' not found - skipping."
}

if ($IncludeRegistry) {
    $registryExists = Test-AcrExists -ResourceGroup $ResourceGroup -RegistryName $RegistryName
    if ($registryExists) {
        Write-Host "==> Deleting container registry '$RegistryName'..."
        az acr delete --name $RegistryName --resource-group $ResourceGroup --yes --output none
        Write-Host "Registry '$RegistryName' deleted."
    }
    else {
        Write-Host "Registry '$RegistryName' not found - skipping."
    }
}
else {
    Write-Host ""
    Write-Host "Registry '$RegistryName' kept (re-run with -IncludeRegistry to delete it,"
    Write-Host "or -DeleteResourceGroup to remove everything)."
}
