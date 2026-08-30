#!/usr/bin/env pwsh
# Cmd : Install-Module -Name powershell-yaml -Scope CurrentUser -Force

Install-Module -Name powershell-yaml -Scope CurrentUser -Force

if (-not (Get-Module -ListAvailable -Name powershell-yaml)) {
    Write-Error "Required module 'powershell-yaml' is missing. Run: Install-Module powershell-yaml"
    exit
}

$CurrentDir = Get-Location
$ConfigFile = Join-Path $CurrentDir "addons.yaml"

if (-not (Test-Path $ConfigFile)) {
    Write-Error "Configuration data file not found at: $ConfigFile"
    exit
}

$ChartsDir = Join-Path $CurrentDir "charts"
$OverridesDir = Join-Path $CurrentDir "overrides"

New-Item -ItemType Directory -Force -Path $ChartsDir | Out-Null
New-Item -ItemType Directory -Force -Path $OverridesDir | Out-Null

$GitIgnorePath = Join-Path $CurrentDir ".gitignore"
if (-not (Test-Path $GitIgnorePath)) {
    "kubeconfig-*.tmp" | Out-File -FilePath $GitIgnorePath -Force
}

####################################################################
###  --- STEP 1: LOADING ADDONS CONFIG ---
####################################################################

Write-Host " STEP 1: LOADING ADDONS INVENTORY CONFIG " -ForegroundColor Cyan
$Addons = Get-Content -Raw -Path $ConfigFile | ConvertFrom-Yaml

####################################################################
### --- STEP 2: CHECKING STAGING TOOLS ---
####################################################################

Write-Host " STEP 2: CHECKING STAGING TOOLS " -ForegroundColor Cyan
if (-not (Get-Command "helm" -ErrorAction SilentlyContinue)) {
    Write-Error "Prerequisite tool missing from PATH: helm"
    exit
}
if (-not (Get-Command "git" -ErrorAction SilentlyContinue)) {
    Write-Error "Prerequisite tool missing from PATH: git"
    exit
}
Write-Host "✓ Core staging command tools found." -ForegroundColor Green

####################################################################
### --- STEP 3: STAGING LOCAL ASSETS ---
####################################################################

Write-Host " STEP 3: STAGING LOCAL ASSETS " -ForegroundColor Cyan

foreach ($Addon in $Addons) {
    Write-Host "Processing Addon: $($Addon.ChartName)" -ForegroundColor Yellow
    
    $ValuesFilePath = Join-Path $OverridesDir $Addon.ValuesFile
    if (-not (Test-Path $ValuesFilePath)) {
        if ($null -ne $Addon.DefaultValues) {
            $Addon.DefaultValues | ConvertTo-Yaml | Out-File -FilePath $ValuesFilePath -Force
            Write-Host " -> Created externalized override configuration: overrides/$($Addon.ValuesFile)" -ForegroundColor Gray
        } else {
            "{}" | Out-File -FilePath $ValuesFilePath -Force
        }
    } else {
        Write-Host " -> Existing override file found: overrides/$($Addon.ValuesFile). Skipping generation." -ForegroundColor Green
    }

    $LocalChartPath = Join-Path $ChartsDir $Addon.ChartName
    $ShouldDownload = $true

    if (Test-Path $LocalChartPath) {
        $ChartYamlPath = Join-Path $LocalChartPath "Chart.yaml"
        if (Test-Path $ChartYamlPath) {
            $LocalChartData = Get-Content -Raw -Path $ChartYamlPath | ConvertFrom-Yaml
            if ($LocalChartData.version -eq $Addon.ChartVersion -or $Addon.IsGitRepoChart) {
                Write-Host " -> Local chart version ($($LocalChartData.version)) matches. Skipping download." -ForegroundColor Green
                $ShouldDownload = $false
            } else {
                $BackupDirName = "$($Addon.ChartName)-$($LocalChartData.version)"
                $BackupDirPath = Join-Path $ChartsDir $BackupDirName
                if (Test-Path $BackupDirPath) { Remove-Item -Recurse -Force $BackupDirPath | Out-Null }
                
                Rename-Item -Path $LocalChartPath -NewName $BackupDirName -Force
                Write-Host " -> Version mismatch. Archived old copy to charts/$BackupDirName" -ForegroundColor Gray
            }
        } else {
            Remove-Item -Recurse -Force $LocalChartPath | Out-Null
        }
    }

    if ($ShouldDownload) {
        Write-Host " -> Downloading version $($Addon.ChartVersion)..." -ForegroundColor Gray
        if ($Addon.IsGitRepoChart) {
            $TempGitPath = Join-Path $ChartsDir "temp-git-clone"
            if (Test-Path $TempGitPath) { Remove-Item -Recurse -Force $TempGitPath | Out-Null }
            
            git clone --depth 1 $Addon.RepoUrl $TempGitPath | Out-Null
            $GitChartSource = Join-Path $TempGitPath "charts/eks-pod-identity-agent"
            Move-Item -Path $GitChartSource -Destination $ChartsDir -Force
            Remove-Item -Recurse -Force $TempGitPath | Out-Null
        }
        elseif ($Addon.IsOCI) {
            helm pull $Addon.RepoUrl --version $Addon.ChartVersion --untar --untardir $ChartsDir
        } else {
            helm repo add $Addon.ChartName $Addon.RepoUrl | Out-Null
            helm repo update | Out-Null
            helm pull "$($Addon.ChartName)/$($Addon.ChartName)" --version $Addon.ChartVersion --untar --untardir $ChartsDir
        }

        if ($LASTEXITCODE -ne 0) { Write-Error "Failed to draw down chart archive."; exit }
        Write-Host " -> ✓ Staging successful." -ForegroundColor Green
    }
    Write-Output "" 
}
Write-Host "Staging complete: Assets ready." -ForegroundColor Green