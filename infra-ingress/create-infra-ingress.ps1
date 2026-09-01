#!/usr/bin/env pwsh

<#
.SYNOPSIS
Applies the shared infrastructure Ingress manifests after their services are installed.

.EXAMPLE
.\create-infra-ingress.ps1 -cluster my-production-cluster -profile admin
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory = $true, Position = 0, HelpMessage = "The name of your Amazon EKS cluster")]
    [ValidateNotNullOrEmpty()]
    [string]$cluster,

    [Parameter(HelpMessage = "AWS CLI profile to use for EKS operations")]
    [ValidateNotNullOrEmpty()]
    [string]$profile = "admin"
)

$ErrorActionPreference = "Stop"
$ManifestsDir = Join-Path $PSScriptRoot "manifests"

foreach ($Tool in @("aws", "kubectl")) {
    if (-not (Get-Command $Tool -ErrorAction SilentlyContinue)) {
        throw "Prerequisite tool missing from PATH: $Tool"
    }
}

if (-not (Test-Path -Path $ManifestsDir -PathType Container)) {
    throw "Infrastructure ingress manifest directory not found: $ManifestsDir"
}

$TempKubeConfig = Join-Path ([System.IO.Path]::GetTempPath()) ("kubeconfig-{0}.tmp" -f [guid]::NewGuid())
$env:KUBECONFIG = $TempKubeConfig
$env:AWS_PROFILE = $profile

try {
    Write-Host "Connecting to EKS cluster '$cluster'..." -ForegroundColor Cyan
    aws eks update-kubeconfig --name $cluster --kubeconfig $TempKubeConfig
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to connect to EKS cluster '$cluster'."
    }

    Write-Host "Applying infrastructure Ingress manifests..." -ForegroundColor Cyan
    kubectl apply --filename $ManifestsDir
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to apply infrastructure Ingress manifests."
    }

    Write-Host "Infrastructure Ingress manifests applied successfully." -ForegroundColor Green
}
finally {
    if (Test-Path $TempKubeConfig) {
        Remove-Item -Force $TempKubeConfig
    }
}
