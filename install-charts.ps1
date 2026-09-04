#!/usr/bin/env pwsh

<#
.SYNOPSIS
Installs enabled Helm add-ons into an Amazon EKS cluster.

.EXAMPLE
.\install-charts.ps1 -cluster my-production-cluster -env prod -profile admin
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory = $true, Position = 0, HelpMessage = "The name of your Amazon EKS Cluster")]
    [ValidateNotNullOrEmpty()]
    [string]$cluster,

    [Parameter(HelpMessage = "Log environment label sent by Promtail, for example dev, test, or prod")]
    [ValidateNotNullOrEmpty()]
    [string]$env = "test",

    [Parameter(HelpMessage = "AWS CLI profile to use for EKS operations")]
    [ValidateNotNullOrEmpty()]
    [string]$profile = "admin"
)

if (-not (Get-Module -ListAvailable -Name powershell-yaml)) {
    Write-Error "Required module 'powershell-yaml' is missing. Run: Install-Module powershell-yaml"
    exit
}

$ConfigFile = Join-Path $PSScriptRoot "inventory.yaml"

if (-not (Test-Path $ConfigFile)) {
    Write-Error "Configuration data file not found at: $ConfigFile"
    exit
}

$ChartsDir = Join-Path $PSScriptRoot "charts"
$OverridesDir = Join-Path $PSScriptRoot "overrides"
$SecretsDir = Join-Path $PSScriptRoot "secrets"
$PrivateCaDir = Join-Path $PSScriptRoot "private-ca"
$AppNamespace = "app-dev"
$Addons = Get-Content -Raw -Path $ConfigFile | ConvertFrom-Yaml

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

& helm diff version | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Error "Required Helm diff plugin is missing. Run: helm plugin install --verify=false https://github.com/databus23/helm-diff"
    exit
}

Write-Host "All deployment tools found." -ForegroundColor Green

####################################################################
# --- STEP 2: CREATING ISOLATED CONTEXT ---
####################################################################

Write-Host " STEP 2: CREATING ISOLATED CONTEXT " -ForegroundColor Cyan

$TempKubeConfig = Join-Path $PSScriptRoot "kubeconfig-$Cluster.tmp"
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

            kubectl apply --filename $SecretsDir
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
        $DynamicHelmArgs = @()
        
        if ($Addon.ChartName -eq "aws-load-balancer-controller") {
            $DynamicHelmArgs += @("--set", "clusterName=$Cluster")
        }
        elseif ($Addon.ChartName -eq "karpenter") {
            $DynamicHelmArgs += @("--set", "settings.clusterName=$Cluster")
        }
        elseif ($Addon.ChartName -eq "promtail") {
            $DynamicHelmArgs += @(
                "--set-string", "config.clients[0].url=http://loki-gateway.logging.svc.cluster.local/loki/api/v1/push",
                "--set-string", "config.clients[0].external_labels.cluster=$cluster",
                "--set-string", "config.clients[0].external_labels.log_environment=$env"
            )
        }
        elseif ($Addon.ChartName -eq "loki") {
            $DynamicHelmArgs += @(
                "--set-string", "loki.storage.object_store.storage_prefix=clusters/$cluster"
            )
        }

        $HelmArgs += $DynamicHelmArgs

        # --- HELM RENDER PREFLIGHT ---
        Write-Host "Rendering chart with final deployment values..." -ForegroundColor Gray
        $HelmTemplateArgs = @("template") + $HelmArgs[2..($HelmArgs.Count - 1)] + @("--include-crds")
        & helm $HelmTemplateArgs | Out-Null
        if ($LASTEXITCODE -ne 0) { Write-Error "Helm template failed for addon: $($Addon.ChartName)"; exit }

        # --- HELM DIFF GATE ---
        Write-Host "Checking rendered manifest changes..." -ForegroundColor Gray
        $HelmDiffArgs = @("diff", "upgrade", "--install", "--detailed-exitcode", "--include-crds", $ReleaseName, $LocalChartPath, "--namespace", $Addon.Namespace, "--values", $ExternalValuesPath) + $DynamicHelmArgs
        & helm $HelmDiffArgs
        $HelmDiffExitCode = $LASTEXITCODE

        if ($HelmDiffExitCode -eq 0) {
            Write-Host "No rendered manifest changes. Skipping Helm upgrade." -ForegroundColor Green
            $ShouldUpgrade = $false
        }
        elseif ($HelmDiffExitCode -eq 2) {
            $ShouldUpgrade = $true
        }
        else {
            Write-Error "Helm diff failed for addon: $($Addon.ChartName)"
            exit
        }

        # --- HELM UPGRADE ENGINE ---
        if ($ShouldUpgrade) {
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
        }

        if ($Addon.ChartName -eq "aws-privateca-issuer") {
            Write-Host "Creating AWS Private CA cluster issuer..." -ForegroundColor Gray
            kubectl apply --filename $PrivateCaDir
            if ($LASTEXITCODE -ne 0) { Write-Error "Failed to create AWS Private CA cluster issuer."; exit }
        }

        Write-Host "SUCCESS: Addon '$($Addon.ChartName)' is fully active!" -ForegroundColor Green
        Write-Output "" 
    }

    Write-Host "All enabled charts successfully deployed." -ForegroundColor Green
}
finally {
    if (Test-Path $TempKubeConfig) { Remove-Item -Force $TempKubeConfig | Out-Null }
}
