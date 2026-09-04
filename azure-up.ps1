#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Builds this repo's Dockerfile in Azure Container Registry and runs it as an
  Azure Container Instance, so you get the exact same dev container (dotnet 10
  SDK, git, node/npm, sshd) as a cloud agent host.

.DESCRIPTION
  Requires the Azure CLI (`az`) and an active login (`az login`).
  Run ./generate-keys.ps1 first so `authorized_keys` exists — it gets baked
  into the image and is the only way to SSH in.

  Steps performed:
    1. create the resource group (if missing)
    2. create an ACR (if missing) with the admin user enabled so ACI can pull
    3. `az acr build` the Dockerfile in this folder (same deps as local), but
       only when the build inputs changed - the image is tagged with a hash of
       the Dockerfile and everything it COPY/ADDs, so re-running with no edits
       reuses the image that is already in the registry
    4. create/replace the container group with a public IP + DNS name, port 22,
       skipped when it is already running that same image

.PARAMETER ResourceGroup
  Resource group to hold the registry and container instance.

.PARAMETER Location
  Azure region.

.PARAMETER RegistryName
  ACR name (globally unique, lowercase alphanumeric). Defaults to a stable
  name derived from the resource group so azure-down.ps1 finds the same one.

.PARAMETER ContainerName
  Name of the container group / container.

.PARAMETER ImageName
  Repository name for the image in ACR. The tag is always a content hash of
  the build context; `:latest` is pushed alongside it for convenience.

.PARAMETER DnsLabel
  DNS name label for the public IP. Must be unique within the region.
  Defaults to the container name plus a stable suffix.

.PARAMETER ForceBuild
  Rebuild the image and recreate the container even when nothing changed.

.EXAMPLE
  ./azure-up.ps1

.EXAMPLE
  ./azure-up.ps1 -ResourceGroup my-agents -Location westus2 -Cpu 4 -Memory 8

.EXAMPLE
  ./azure-up.ps1 -ForceBuild
#>
param(
    [string]$ResourceGroup = "dotnet10-dev-rg",
    [string]$Location = "eastus",
    [string]$RegistryName,
    [string]$ContainerName = "dotnet10-dev",
    [string]$ImageName = "dotnet10-dev-container",
    [string]$DnsLabel,
    [double]$Cpu = 2,
    [double]$Memory = 4,
    [ValidateSet("Basic", "Standard", "Premium")]
    [string]$RegistrySku = "Basic",
    [switch]$ForceBuild
)

$ErrorActionPreference = "Stop"
$scriptDir = $PSScriptRoot

. (Join-Path $scriptDir "azure-common.ps1")

Assert-AzureCli

if (-not (Test-Path (Join-Path $scriptDir "authorized_keys"))) {
    throw "authorized_keys not found - run ./generate-keys.ps1 first."
}

if (-not $RegistryName) { $RegistryName = Get-DefaultRegistryName -ResourceGroup $ResourceGroup }
if (-not $DnsLabel) { $DnsLabel = Get-DefaultDnsLabel -ResourceGroup $ResourceGroup -ContainerName $ContainerName }

Write-Host "Subscription: $(az account show --query name -o tsv)"
Write-Host "Resource group: $ResourceGroup ($Location)"
Write-Host "Registry: $RegistryName"
Write-Host ""

Write-Host "==> Ensuring resource group..."
az group create --name $ResourceGroup --location $Location --output none

Write-Host "==> Ensuring container registry..."
if (-not (Test-AcrExists -ResourceGroup $ResourceGroup -RegistryName $RegistryName)) {
    az acr create `
        --name $RegistryName `
        --resource-group $ResourceGroup `
        --location $Location `
        --sku $RegistrySku `
        --admin-enabled true `
        --output none
}
else {
    # ACI pulls with username/password, so the admin user has to be on.
    az acr update --name $RegistryName --resource-group $ResourceGroup --admin-enabled true --output none
}

$imageHashTag = Get-BuildContextHash -ContextPath $scriptDir
$image = "${ImageName}:$imageHashTag"
Write-Host "Image: $image"

if (-not $ForceBuild -and (Test-AcrImageTagExists -RegistryName $RegistryName -Repository $ImageName -Tag $imageHashTag)) {
    Write-Host "==> Image '$image' already in the registry and the build context is unchanged - skipping build."
    Write-Host "    (use -ForceBuild to rebuild anyway)"
}
else {
    Write-Host "==> Building image '$image' in ACR (same Dockerfile as ./up.ps1)..."
    az acr build `
        --registry $RegistryName `
        --resource-group $ResourceGroup `
        --image $image `
        --image "${ImageName}:latest" `
        $scriptDir
}

$loginServer = az acr show --name $RegistryName --resource-group $ResourceGroup --query loginServer -o tsv
$targetImage = "$loginServer/$image"

# If a healthy container group is already running this exact image there is
# nothing to do - deleting and recreating it would only churn the public IP.
$currentImage = Invoke-AzQuiet @("container", "show", "--name", $ContainerName, "--resource-group", $ResourceGroup, "--query", "containers[0].image", "-o", "tsv")
$currentState = Invoke-AzQuiet @("container", "show", "--name", $ContainerName, "--resource-group", $ResourceGroup, "--query", "instanceView.state", "-o", "tsv")

if (-not $ForceBuild -and $currentImage -eq $targetImage -and $currentState -eq "Running") {
    Write-Host "==> Container instance '$ContainerName' is already running '$image' - leaving it alone."
}
else {
    $registryUser = az acr credential show --name $RegistryName --resource-group $ResourceGroup --query username -o tsv
    $registryPassword = az acr credential show --name $RegistryName --resource-group $ResourceGroup --query "passwords[0].value" -o tsv

    if ($currentImage) {
        Write-Host "==> Removing existing container instance '$ContainerName'..."
        az container delete --name $ContainerName --resource-group $ResourceGroup --yes --output none
    }

    Write-Host "==> Creating container instance..."
    az container create `
        --name $ContainerName `
        --resource-group $ResourceGroup `
        --location $Location `
        --image $targetImage `
        --registry-login-server $loginServer `
        --registry-username $registryUser `
        --registry-password $registryPassword `
        --os-type Linux `
        --cpu $Cpu `
        --memory $Memory `
        --ports 22 `
        --ip-address Public `
        --dns-name-label $DnsLabel `
        --restart-policy OnFailure `
        --output none
}

$fqdn = az container show --name $ContainerName --resource-group $ResourceGroup --query "ipAddress.fqdn" -o tsv
$ip = az container show --name $ContainerName --resource-group $ResourceGroup --query "ipAddress.ip" -o tsv

Write-Host ""
Write-Host "Container instance '$ContainerName' is up."
Write-Host "  FQDN: $fqdn"
Write-Host "  IP:   $ip"
Write-Host ""
Write-Host "SSH in:"
Write-Host "  ssh -i ~/.ssh/id_dotnet10dev_ed25519 dev@$fqdn"
Write-Host ""
Write-Host "Or get a shell without SSH (see aka.ms/aci-exec):"
Write-Host "  az container exec --resource-group $ResourceGroup --name $ContainerName --exec-command `"/bin/bash`""
Write-Host ""
Write-Host "Tear it down with: ./azure-down.ps1 -ResourceGroup $ResourceGroup"
