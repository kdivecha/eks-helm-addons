#!/usr/bin/env pwsh

<#
.SYNOPSIS
Creates the managed namespaces and applies the network policy baseline.

.EXAMPLE
.\create-policies.ps1 -cluster my-production-cluster -profile admin
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
$CurrentDir = $PSScriptRoot
$RepositoryDir = Split-Path -Parent $CurrentDir
$InventoryPath = Join-Path $RepositoryDir "inventory.yaml"
$PoliciesDir = Join-Path $CurrentDir "policies"

if (-not (Get-Module -ListAvailable -Name powershell-yaml)) {
    throw "Required module 'powershell-yaml' is missing. Run: Install-Module powershell-yaml -Scope CurrentUser"
}

foreach ($Tool in @("aws", "kubectl")) {
    if (-not (Get-Command $Tool -ErrorAction SilentlyContinue)) {
        throw "Prerequisite tool missing from PATH: $Tool"
    }
}

foreach ($Path in @($InventoryPath, $PoliciesDir)) {
    if (-not (Test-Path -Path $Path)) {
        throw "Required network policy asset not found: $Path"
    }
}

$Addons = Get-Content -Raw -Path $InventoryPath | ConvertFrom-Yaml
$Namespaces = @(
    $Addons | ForEach-Object { $_.Namespace }
    "default"
    "kube-public"
    "kube-node-lease"
    "app-dev"
) | Sort-Object -Unique

$TempKubeConfig = Join-Path ([System.IO.Path]::GetTempPath()) ("kubeconfig-{0}.tmp" -f [guid]::NewGuid())
$env:KUBECONFIG = $TempKubeConfig
$env:AWS_PROFILE = $profile

try {
    Write-Host "Connecting to EKS cluster '$cluster'..." -ForegroundColor Cyan
    aws eks update-kubeconfig --name $cluster --kubeconfig $TempKubeConfig
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to connect to EKS cluster '$cluster'."
    }

    Write-Host "Creating network policy namespaces..." -ForegroundColor Cyan
    foreach ($Namespace in $Namespaces) {
        kubectl create namespace $Namespace --dry-run=client --output yaml | kubectl apply --filename -
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to ensure namespace '$Namespace' exists."
        }
    }

    Write-Host "Applying network policies..." -ForegroundColor Cyan
    kubectl apply --filename $PoliciesDir
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to apply network policies."
    }

    Write-Host "Network policies applied successfully." -ForegroundColor Green
}
finally {
    if (Test-Path $TempKubeConfig) {
        Remove-Item -Force $TempKubeConfig
    }
}
