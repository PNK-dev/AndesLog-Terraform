#requires -Version 5.1
<#
.SYNOPSIS
  Packages and publishes the AndesLog Python Functions after Terraform apply.
.DESCRIPTION
  Packages the Azure Functions source, deploys it, and checks that the expected
  HTTP and Timer triggers load. Azure Files replication uses the official SDK.
  No credentials or function keys are written to the console.
.EXAMPLE
  .\scripts\publish-azure-functions.ps1
#>
[CmdletBinding()]
param(
    [string]$ExpectedSubscription = '75b45f81-0930-4278-8fd9-896cec6eebe1',
    [switch]$RunSyncNow,
    [switch]$SkipPackagePublish
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$source = Join-Path $repo 'functions\erp-ingest'
$terraformRoot = Join-Path $repo 'environments\lab\azure'
$tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$work = [IO.Path]::GetFullPath((Join-Path $tempRoot ('andeslog-functions-' + [guid]::NewGuid().ToString('N'))))
$stage = Join-Path $work 'stage'

function Require-Command([string]$Name) {
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) { throw "Required command not found: $Name" }
}

function Get-TerraformOutput([string]$Name) {
    Push-Location $terraformRoot
    try {
        $value = & terraform output -raw $Name 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $value) { throw "Terraform output '$Name' is unavailable. Apply the Azure workspace first." }
        return ($value | Out-String).Trim()
    } finally { Pop-Location }
}

Require-Command 'terraform'
Require-Command 'az'
if (-not $env:TF_CLOUD_ORGANIZATION) { $env:TF_CLOUD_ORGANIZATION = 'AndesLog' }

$subscription = Get-TerraformOutput 'subscription_id'
$resourceGroup = Get-TerraformOutput 'resource_group_name'
$functionApp = Get-TerraformOutput 'erp_event_function_name'
if ($subscription -ne $ExpectedSubscription) { throw 'The Azure Terraform output does not match the expected subscription.' }

$accountSubscription = (& az account show --query id -o tsv 2>$null | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or $accountSubscription -ne $subscription) {
    throw 'Azure CLI is not logged in to the Azure subscription selected by Terraform.'
}

$syncEnabled = (& az functionapp config appsettings list --resource-group $resourceGroup --name $functionApp --query "[?name=='FILES_DR_SYNC_ENABLED'].value | [0]" -o tsv 2>$null | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or $syncEnabled -ne 'true') {
    throw 'Azure Files DR sync is not enabled in Terraform app settings. Apply the Azure workspace first.'
}

try {
    if (-not $SkipPackagePublish) {
        New-Item -ItemType Directory -Path $stage -Force | Out-Null
        Copy-Item -Path (Join-Path $source '*') -Destination $stage -Recurse -Force
        $package = Join-Path $work 'erp-ingest.zip'
        Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $package -Force
        Write-Host "Publishing Function package to $functionApp in $resourceGroup."
        & az functionapp deployment source config-zip --resource-group $resourceGroup --name $functionApp --src $package --build-remote true --timeout 300 --output none
        if ($LASTEXITCODE -ne 0) { throw 'Azure Function package deployment failed.' }
    }

    $expectedFunctions = @('ErpEventIngest', 'AzureFilesDisasterRecoverySync')
    $ready = $false
    for ($attempt = 0; $attempt -lt 24; $attempt++) {
        $loaded = @(& az functionapp function list --resource-group $resourceGroup --name $functionApp --query '[].name' -o tsv 2>$null)
        $loadedNames = @($loaded | ForEach-Object { (($_ -split '/')[-1]).Trim() })
        if ($LASTEXITCODE -eq 0 -and @($expectedFunctions | Where-Object { $_ -notin $loadedNames }).Count -eq 0) {
            $ready = $true
            break
        }
        Start-Sleep -Seconds 5
    }
    if (-not $ready) { throw 'The HTTP and Timer triggers did not both become visible after deployment.' }
    Write-Host 'Function package deployment succeeded; ErpEventIngest and AzureFilesDisasterRecoverySync are loaded.'

    if ($RunSyncNow) {
        $masterKey = (& az functionapp keys list --resource-group $resourceGroup --name $functionApp --query masterKey -o tsv 2>$null | Out-String).Trim()
        if ($LASTEXITCODE -ne 0 -or -not $masterKey) { throw 'Could not obtain the Function host key required for the one-time Timer invocation.' }
        try {
            $headers = @{ 'x-functions-key' = $masterKey }
            $response = Invoke-WebRequest -Uri "https://$functionApp.azurewebsites.net/admin/functions/AzureFilesDisasterRecoverySync" `
                -Method Post -Headers $headers -ContentType 'application/json' -Body '{}' -UseBasicParsing
            if ([int]$response.StatusCode -ne 202) { throw "Timer invocation returned HTTP $([int]$response.StatusCode), expected 202." }
        } finally {
            $masterKey = $null
            $headers = $null
        }
        Write-Host 'One-time Timer invocation accepted over HTTPS; check Application Insights for FILES_DR_SYNC_SUCCESS.'
    }
}
finally {
    $resolvedTempRoot = [IO.Path]::GetFullPath($tempRoot).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    $resolvedWork = [IO.Path]::GetFullPath($work)
    if ($resolvedWork.StartsWith($resolvedTempRoot, [StringComparison]::OrdinalIgnoreCase) -and
        (Split-Path -Leaf $resolvedWork).StartsWith('andeslog-functions-', [StringComparison]::OrdinalIgnoreCase)) {
        if (Test-Path -LiteralPath $resolvedWork) { Remove-Item -LiteralPath $resolvedWork -Recurse -Force }
    } else {
        throw 'Refusing to remove a temporary path outside the dedicated AndesLog temp directory.'
    }
}
