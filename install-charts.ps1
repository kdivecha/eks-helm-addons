#!/usr/bin/env pwsh

<#
.SYNOPSIS
Installs enabled Helm add-ons into an Amazon EKS cluster.

.EXAMPLE
.\install-charts.ps1 -cluster my-production-cluster -profile admin
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory = $true, Position = 0, HelpMessage = "The name of your Amazon EKS Cluster")]
    [ValidateNotNullOrEmpty()]
    [string]$cluster,

    [Parameter(HelpMessage = "AWS CLI profile to use for EKS operations")]
    [ValidateNotNullOrEmpty()]
    [string]$profile = "admin"
)

if (-not (Get-Module -ListAvailable -Name powershell-yaml)) {
    Write-Error "Required module 'powershell-yaml' is missing. Run: Install-Module powershell-yaml"
    exit
}

$CurrentDir = $PSScriptRoot
$ConfigFile = Join-Path $CurrentDir "inventory.yaml"

if (-not (Test-Path $ConfigFile)) {
    Write-Error "Configuration data file not found at: $ConfigFile"
    exit
}

$ChartsDir = Join-Path $CurrentDir "charts"
$OverridesDir = Join-Path $CurrentDir "overrides"
$DashboardsDir = Join-Path $CurrentDir "dashboards"
$InfraIngressDir = Join-Path $CurrentDir "infra-ingress"
$SecretsDir = Join-Path $CurrentDir "secrets"
$NetworkDir = Join-Path $CurrentDir "network"
$GrafanaIngressManifest = Join-Path $InfraIngressDir "grafana.yaml"
$ArgoCDIngressManifest = Join-Path $InfraIngressDir "argocd.yaml"
$NatsSecretStoreManifest = Join-Path $SecretsDir "cluster-secret-store.yaml"
$NatsAuthManifest = Join-Path $SecretsDir "nats-auth.yaml"
$AppAuthManifest = Join-Path $SecretsDir "app-nats-auth.yaml"
$AppNamespace = "app-dev"
$Addons = Get-Content -Raw -Path $ConfigFile | ConvertFrom-Yaml
$NetworkNamespaces = @(
    $Addons | ForEach-Object { $_.Namespace }
    "default"
    "kube-public"
    "kube-node-lease"
    $AppNamespace
) | Sort-Object -Unique

####################################################################
# --- STEP 1: CHECKING DEPLOYMENT TOOLS ---
####################################################################

Write-Host " STEP 1: CHECKING DEPLOYMENT TOOLS " -ForegroundColor Cyan
foreach ($Tool in @("aws", "helm", "kubectl")) {
    if (-not (Get-Command $Tool -ErrorAction SilentlyContinue)) {
        Write-Error "Prerequisite tool missing from PATH: $Tool"
        exit
    }
}
Write-Host "All deployment tools found." -ForegroundColor Green

####################################################################
# --- STEP 2: CREATING ISOLATED CONTEXT ---
####################################################################

Write-Host " STEP 2: CREATING ISOLATED CONTEXT " -ForegroundColor Cyan

$TempKubeConfig = Join-Path $CurrentDir "kubeconfig-$Cluster.tmp"
if (Test-Path $TempKubeConfig) { Remove-Item -Force $TempKubeConfig | Out-Null }

$env:KUBECONFIG = $TempKubeConfig
$env:AWS_PROFILE = $Profile
aws eks update-kubeconfig --name $Cluster

if ($LASTEXITCODE -ne 0) { Write-Error "Failed to connect to EKS."; exit }

####################################################################
### --- STEP 3: RUNNING INSTALLATIONS ---
####################################################################

Write-Host " STEP 3: RUNNING INSTALLATIONS " -ForegroundColor Cyan

try {
    foreach ($Addon in $Addons) {
        # --- STEP: EVALUATE ENABLED STATUS ---
        if ($Addon.Enabled -eq $false) {
            Write-Host "Skipping Addon (Disabled in config): $($Addon.ChartName)" -ForegroundColor Gray
            Write-Output ""
            continue # Safe escape jump out of loop block container iteration
        }

        Write-Host "Deploying Addon: $($Addon.ChartName)" -ForegroundColor Yellow
        
        $LocalChartPath = Join-Path $ChartsDir $Addon.ChartName
        $ExternalValuesPath = Join-Path $OverridesDir $Addon.ValuesFile
        $ReleaseName = if ([string]::IsNullOrWhiteSpace($Addon.ReleaseName)) { $Addon.ChartName } else { $Addon.ReleaseName }

        if (-not (Test-Path $LocalChartPath) -or -not (Test-Path $ExternalValuesPath)) {
            Write-Error "Required local deployment assets are missing."; exit
        }

        ### NATS SECRET MANAGEMENT
        if ($Addon.ChartName -eq "nats") {
            foreach ($Namespace in @($Addon.Namespace, $AppNamespace) | Select-Object -Unique) {
                kubectl create namespace $Namespace --dry-run=client --output yaml | kubectl apply --filename -
            }

            kubectl apply --filename $NatsSecretStoreManifest --filename $NatsAuthManifest --filename $AppAuthManifest
        }

        # --- EKS POD IDENTITY MAPPER ---
        if ($null -ne $Addon.PodIdentity) {
            Write-Host "Reconciling EKS Pod Identity Association..." -ForegroundColor Gray
            $ExistingAssoc = aws eks list-pod-identity-associations `
                --cluster-name $Cluster `
                --query "associations[?namespace=='$($Addon.Namespace)' && serviceAccount=='$($Addon.PodIdentity.ServiceAccount)'].associationId" `
                --output text 2>$null

            if ([string]::IsNullOrEmpty($ExistingAssoc) -or $ExistingAssoc -eq "None") {
                Write-Host "Creating new Pod Identity Association..." -ForegroundColor Gray
                aws eks create-pod-identity-association `
                    --cluster-name $Cluster `
                    --namespace $Addon.Namespace `
                    --service-account $Addon.PodIdentity.ServiceAccount `
                    --role-arn $Addon.PodIdentity.RoleArn | Out-Null
            } else {
                Write-Host "Association exists ($ExistingAssoc)." -ForegroundColor Green
            }
        }

        # --- DYNAMIC MULTI-CLUSTER SET ARGUMENTS ---
        $HelmArgs = @("upgrade", "--install", $ReleaseName, $LocalChartPath, "--namespace", $Addon.Namespace, "--create-namespace", "--values", $ExternalValuesPath)
        
        if ($Addon.ChartName -eq "aws-load-balancer-controller") {
            $HelmArgs += @("--set", "clusterName=$Cluster")
        }
        elseif ($Addon.ChartName -eq "karpenter") {
            $HelmArgs += @("--set", "settings.clusterName=$Cluster")
        }

        # --- HELM RENDER PREFLIGHT ---
        Write-Host "Rendering chart with final deployment values..." -ForegroundColor Gray
        $HelmTemplateArgs = @("template") + $HelmArgs[2..($HelmArgs.Count - 1)] + @("--include-crds")
        & helm $HelmTemplateArgs | Out-Null
        if ($LASTEXITCODE -ne 0) { Write-Error "Helm template failed for addon: $($Addon.ChartName)"; exit }

        # --- HELM UPGRADE ENGINE ---
        $HelmArgs += @("--atomic", "--wait", "--wait-for-jobs", "--timeout", "10m")
        Write-Host "Running local helm release installer..." -ForegroundColor Gray
        & helm $HelmArgs

        if ($LASTEXITCODE -ne 0) { Write-Error "Helm upgrade failed."; exit }

        # --- ROLLOUT STATUS EVALUATION ---
        Write-Host "Checking target workload rollout verifications..." -ForegroundColor Gray
        foreach ($Target in $Addon.RolloutTargets) {
            $ResourceString = "$($Target.Type.ToLower())/$($Target.Name)"
            kubectl rollout status $ResourceString --namespace $Addon.Namespace --timeout=300s
            if ($LASTEXITCODE -ne 0) { Write-Error "Rollout timed out or crashed on target: $ResourceString."; exit }
        }

        ### GRAFANA DASHBOARDS AND INFRASTRUCTURE INGRESS
        if ($Addon.ChartName -eq "kube-prometheus-stack") {
            if (-not (Test-Path -Path $DashboardsDir -PathType Container)) {
                Write-Error "Grafana dashboard directory not found: $DashboardsDir"; exit
            }

            Write-Host "Applying Grafana dashboard ConfigMaps..." -ForegroundColor Gray
            kubectl apply --filename $DashboardsDir
            if ($LASTEXITCODE -ne 0) { Write-Error "Failed to apply Grafana dashboard ConfigMaps."; exit }

            if (-not (Test-Path -Path $GrafanaIngressManifest -PathType Leaf)) {
                Write-Error "Grafana ingress manifest not found: $GrafanaIngressManifest"; exit
            }

            Write-Host "Applying Grafana infrastructure ingress..." -ForegroundColor Gray
            kubectl apply --filename $GrafanaIngressManifest
            if ($LASTEXITCODE -ne 0) { Write-Error "Failed to apply Grafana infrastructure ingress."; exit }
        }

        ### ARGO CD INFRASTRUCTURE INGRESS
        if ($Addon.ChartName -eq "argo-cd") {
            if (-not (Test-Path -Path $ArgoCDIngressManifest -PathType Leaf)) {
                Write-Error "Argo CD ingress manifest not found: $ArgoCDIngressManifest"; exit
            }

            Write-Host "Applying Argo CD infrastructure ingress..." -ForegroundColor Gray
            kubectl apply --filename $ArgoCDIngressManifest
            if ($LASTEXITCODE -ne 0) { Write-Error "Failed to apply Argo CD infrastructure ingress."; exit }
        }

        Write-Host "SUCCESS: Addon '$($Addon.ChartName)' is fully active!" -ForegroundColor Green
        Write-Output "" 
    }

    foreach ($Namespace in $NetworkNamespaces) {
        kubectl create namespace $Namespace --dry-run=client --output yaml | kubectl apply --filename -
        if ($LASTEXITCODE -ne 0) { Write-Error "Failed to ensure network namespace '$Namespace' exists."; exit }
    }

    kubectl apply --filename $NetworkDir
    if ($LASTEXITCODE -ne 0) { Write-Error "Failed to apply network policies."; exit }

    Write-Host "All enabled addons successfully deployed." -ForegroundColor Green
}
finally {
    if (Test-Path $TempKubeConfig) { Remove-Item -Force $TempKubeConfig | Out-Null }
}
