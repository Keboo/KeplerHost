#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Shared helpers for azure-up.ps1 / azure-down.ps1. Dot-source it; it isn't
  meant to be run directly.
#>

# Runs `az` for checks that are allowed to fail (for example "does this
# resource exist?"). `az` is a wrapper script, so anything it writes to stderr
# becomes a PowerShell error record - which is fatal while
# $ErrorActionPreference is 'Stop'. Swallow that here and just report failure
# by returning $null.
function Invoke-AzQuiet {
    param([Parameter(Mandatory)][string[]]$Arguments)

    $ErrorActionPreference = "Continue"
    $output = & az @Arguments 2>$null
    $exitCode = $LASTEXITCODE
    $global:LASTEXITCODE = 0
    if ($exitCode -ne 0) { return $null }

    $text = ($output | Out-String).Trim()
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    return $text
}

function Assert-AzureCli {
    if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
        throw "The Azure CLI ('az') was not found. Install it from https://aka.ms/azure-cli."
    }
    $account = Invoke-AzQuiet @("account", "show", "--output", "json")
    if (-not $account) {
        throw "Not logged in to Azure. Run 'az login' (and 'az account set --subscription <id>') first."
    }
}

# Registry and DNS names must be globally/regionally unique, and both scripts
# have to agree on them, so derive a stable suffix from the resource group.
function Get-StableSuffix {
    param([Parameter(Mandatory)][string]$Value)

    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Value.ToLowerInvariant())
    $hash = [System.Security.Cryptography.SHA256]::Create().ComputeHash($bytes)
    return (($hash | ForEach-Object { $_.ToString("x2") }) -join "").Substring(0, 10)
}

function Get-DefaultRegistryName {
    param([Parameter(Mandatory)][string]$ResourceGroup)

    return "dotnet10dev$(Get-StableSuffix -Value $ResourceGroup)"
}

function Get-DefaultDnsLabel {
    param(
        [Parameter(Mandatory)][string]$ResourceGroup,
        [Parameter(Mandatory)][string]$ContainerName
    )

    return "$ContainerName-$(Get-StableSuffix -Value $ResourceGroup)".ToLowerInvariant()
}

# `az acr show` / `az container show` fail hard when the resource is missing, so
# use list-based lookups (which return an empty result instead) for existence.
function Test-AcrExists {
    param(
        [Parameter(Mandatory)][string]$ResourceGroup,
        [Parameter(Mandatory)][string]$RegistryName
    )

    return [bool](Invoke-AzQuiet @("acr", "list", "--resource-group", $ResourceGroup, "--query", "[?name=='$RegistryName'].name", "-o", "tsv"))
}

function Test-ContainerGroupExists {
    param(
        [Parameter(Mandatory)][string]$ResourceGroup,
        [Parameter(Mandatory)][string]$ContainerName
    )

    return [bool](Invoke-AzQuiet @("container", "list", "--resource-group", $ResourceGroup, "--query", "[?name=='$ContainerName'].name", "-o", "tsv"))
}

# The files that actually end up in the image: the Dockerfile itself plus
# everything it COPY/ADDs. Changing a .ps1 or the README can't affect the
# built image, so those must not invalidate the cached tag.
function Get-BuildContextFile {
    param(
        [Parameter(Mandatory)][string]$ContextPath,
        [string]$DockerfileName = "Dockerfile"
    )

    $dockerfile = Join-Path $ContextPath $DockerfileName
    if (-not (Test-Path $dockerfile)) { throw "Dockerfile not found at '$dockerfile'." }

    $files = [System.Collections.Generic.List[string]]::new()
    $files.Add((Resolve-Path $dockerfile).Path)

    foreach ($line in Get-Content -LiteralPath $dockerfile) {
        if ($line -notmatch '^\s*(COPY|ADD)\s+(.*)$') { continue }

        # Drop flags such as --chown=... and the final destination argument.
        $tokens = ($Matches[2] -split '\s+') | Where-Object { $_ -and $_ -notmatch '^--' }
        if ($tokens.Count -lt 2) { continue }

        foreach ($token in $tokens[0..($tokens.Count - 2)]) {
            $source = $token.Trim('"', "'")
            # Remote sources (ADD https://...) and build-stage copies aren't local files.
            if ($source -match '^[a-z]+://') { continue }

            $resolved = Get-ChildItem -Path (Join-Path $ContextPath $source) -File -Recurse -ErrorAction SilentlyContinue
            foreach ($item in $resolved) { $files.Add($item.FullName) }
        }
    }

    return $files | Sort-Object -Unique
}

# A tag derived from the build inputs: same inputs -> same tag -> the image is
# already in the registry and the build can be skipped entirely.
function Get-BuildContextHash {
    param(
        [Parameter(Mandatory)][string]$ContextPath,
        [string]$DockerfileName = "Dockerfile"
    )

    $contextRoot = (Resolve-Path $ContextPath).Path
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $buffer = [System.IO.MemoryStream]::new()

    foreach ($file in (Get-BuildContextFile -ContextPath $contextRoot -DockerfileName $DockerfileName)) {
        # Include the relative path so a rename alone changes the hash.
        $relative = $file.Substring($contextRoot.Length).TrimStart('\', '/').Replace('\', '/')
        $nameBytes = [System.Text.Encoding]::UTF8.GetBytes("$relative`n")
        $buffer.Write($nameBytes, 0, $nameBytes.Length)

        $contentHash = $sha.ComputeHash([System.IO.File]::ReadAllBytes($file))
        $buffer.Write($contentHash, 0, $contentHash.Length)
    }

    $final = $sha.ComputeHash($buffer.ToArray())
    $buffer.Dispose()
    $sha.Dispose()
    return (($final | ForEach-Object { $_.ToString("x2") }) -join "").Substring(0, 12)
}

function Test-AcrImageTagExists {
    param(
        [Parameter(Mandatory)][string]$RegistryName,
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][string]$Tag
    )

    # `show-tags` fails outright when the repository doesn't exist yet, so this
    # has to go through the quiet wrapper.
    return [bool](Invoke-AzQuiet @("acr", "repository", "show-tags", "--name", $RegistryName, "--repository", $Repository, "--query", "[?@=='$Tag']", "-o", "tsv"))
}
