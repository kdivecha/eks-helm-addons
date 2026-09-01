#!/usr/bin/env pwsh

<#
.SYNOPSIS
Applies Grafana dashboard ConfigMaps after kube-prometheus-stack is installed.

.EXAMPLE
.\create-dashboards.ps1 -cluster my-production-cluster -profile admin
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
    throw "Grafana dashboard manifest directory not found: $ManifestsDir"
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

    Write-Host "Applying Grafana dashboard ConfigMaps..." -ForegroundColor Cyan
    kubectl apply --filename $ManifestsDir
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to apply Grafana dashboard ConfigMaps."
    }

    Write-Host "Grafana dashboard ConfigMaps applied successfully." -ForegroundColor Green
}
finally {
    if (Test-Path $TempKubeConfig) {
        Remove-Item -Force $TempKubeConfig
    }
}
