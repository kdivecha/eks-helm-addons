#!/usr/bin/env pwsh
[CmdletBinding(SupportsShouldProcess = $true)]
param (
    [Parameter(HelpMessage = "AWS CLI profile used to create or update IAM roles")]
    [ValidateNotNullOrEmpty()]
    [string]$Profile = "admin",

    [Parameter(HelpMessage = "Allow policy documents that still contain REPLACE_WITH_ placeholders")]
    [switch]$AllowUnresolvedPlaceholders
)

$ErrorActionPreference = "Stop"
$CurrentDir = $PSScriptRoot
$RoleInventoryPath = Join-Path $CurrentDir "role-inventory.yaml"

Install-Module -Name powershell-yaml -Scope CurrentUser -Force

if (-not (Get-Module -ListAvailable -Name powershell-yaml)) {
    throw "Required module 'powershell-yaml' is missing. Run: Install-Module powershell-yaml -Scope CurrentUser"
}

if (-not (Get-Command aws -ErrorAction SilentlyContinue)) {
    throw "Prerequisite tool missing from PATH: aws"
}

if (-not (Test-Path -Path $RoleInventoryPath -PathType Leaf)) {
    throw "Role inventory not found: $RoleInventoryPath"
}

$RoleInventory = Get-Content -Raw -Path $RoleInventoryPath | ConvertFrom-Yaml
$Roles = @($RoleInventory.Roles)
if ($Roles.Count -eq 0) {
    throw "No roles are defined in: $RoleInventoryPath"
}

function Invoke-AwsCli {
    param([string[]]$Arguments)

    & aws @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "AWS CLI command failed: aws $($Arguments -join ' ')"
    }
}

$OriginalAwsProfile = $env:AWS_PROFILE
$env:AWS_PROFILE = $Profile

try {
    $CallerIdentity = & aws sts get-caller-identity --output json
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to authenticate with AWS profile '$Profile'."
    }

    $AccountId = (($CallerIdentity | ConvertFrom-Json).Account)
    Write-Host "Provisioning $($Roles.Count) Pod Identity role(s) in account $AccountId..." -ForegroundColor Cyan

    foreach ($Role in $Roles) {
        foreach ($PropertyName in @("RoleName", "TrustPolicyFile", "PermissionPolicyFile")) {
            if ([string]::IsNullOrWhiteSpace([string]$Role.$PropertyName)) {
                throw "Role inventory entry for '$($Role.RoleName)' is missing '$PropertyName'."
            }
        }

        $TrustPolicyPath = Join-Path $CurrentDir $Role.TrustPolicyFile
        $PermissionPolicyPath = Join-Path $CurrentDir $Role.PermissionPolicyFile
        foreach ($PolicyPath in @($TrustPolicyPath, $PermissionPolicyPath)) {
            if (-not (Test-Path -Path $PolicyPath -PathType Leaf)) {
                throw "Policy document not found: $PolicyPath"
            }

            $PolicyDocument = Get-Content -Raw -Path $PolicyPath
            $null = $PolicyDocument | ConvertFrom-Json
            if (-not $AllowUnresolvedPlaceholders -and $PolicyDocument -match "REPLACE_WITH_") {
                throw "Policy document contains unresolved placeholders: $PolicyPath. Replace them before provisioning, or explicitly use -AllowUnresolvedPlaceholders."
            }
        }

        $RoleName = [string]$Role.RoleName
        $PolicyName = $RoleName
        $ExistingRoleName = & aws iam list-roles --query "Roles[?RoleName=='$RoleName'].RoleName | [0]" --output text
        if ($LASTEXITCODE -ne 0) {
            throw "Unable to determine whether IAM role '$RoleName' exists."
        }

        if (-not [string]::IsNullOrWhiteSpace($ExistingRoleName) -and $ExistingRoleName -ne "None") {
            if ($PSCmdlet.ShouldProcess($RoleName, "update its Pod Identity trust policy")) {
                Invoke-AwsCli @("iam", "update-assume-role-policy", "--role-name", $RoleName, "--policy-document", "file://$TrustPolicyPath")
            }
        }
        else {
            if ($PSCmdlet.ShouldProcess($RoleName, "create Pod Identity IAM role")) {
                Invoke-AwsCli @("iam", "create-role", "--role-name", $RoleName, "--assume-role-policy-document", "file://$TrustPolicyPath")
            }
        }

        if ($PSCmdlet.ShouldProcess($RoleName, "put inline policy '$PolicyName'")) {
            Invoke-AwsCli @("iam", "put-role-policy", "--role-name", $RoleName, "--policy-name", $PolicyName, "--policy-document", "file://$PermissionPolicyPath")
        }

        Write-Host "Reconciled role '$RoleName' and inline policy '$PolicyName'." -ForegroundColor Green
    }
}
finally {
    if ($null -eq $OriginalAwsProfile) {
        Remove-Item Env:AWS_PROFILE -ErrorAction SilentlyContinue
    }
    else {
        $env:AWS_PROFILE = $OriginalAwsProfile
    }
}
