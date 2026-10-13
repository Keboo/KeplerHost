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
if ($LASTEXITCODE -ne 0) {
    throw "Docker image build failed; the existing container was not changed."
}

$existingContainer = docker container ls -a --filter "name=^/${ContainerName}$" --format '{{.Names}}'
if ($LASTEXITCODE -ne 0) {
    throw "Failed to check for the existing container."
}
if ($existingContainer -contains $ContainerName) {
    docker rm -f $ContainerName | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to remove container '$ContainerName'."
    }
}

$hostKeyVolume = "${ContainerName}-ssh-host-keys"
docker run -d --name $ContainerName -p "${SshPort}:22" `
    --mount "type=volume,source=$hostKeyVolume,target=/var/lib/ssh-host-keys" $ImageName
if ($LASTEXITCODE -ne 0) {
    throw "Failed to start container '$ContainerName'."
}

Write-Host ""
Write-Host "Container '$ContainerName' is up."
Write-Host "SSH host keys are retained in Docker volume '$hostKeyVolume'."
Write-Host "Connect with: ssh -i ~/.ssh/id_dotnet10dev_ed25519 -p $SshPort dev@localhost"
