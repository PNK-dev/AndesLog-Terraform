#requires -Version 5.1
<#
.SYNOPSIS
  Sincroniza Azure Files a la región secundaria o prepara el acceso P2S regional de contingencia.
.EXAMPLE
  .\scripts\azure-files-dr.ps1 -Action Sync -Execute
.EXAMPLE
  .\scripts\azure-files-dr.ps1 -Action Activate -Execute
.EXAMPLE
  .\scripts\azure-files-dr.ps1 -Action Deactivate -Execute
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Sync', 'Activate', 'Deactivate')]
    [string]$Action,
    [switch]$Execute,
    [string]$ExpectedHcpOrganization = 'AndesLog',
    [string]$ExpectedAzureSubscription = '75b45f81-0930-4278-8fd9-896cec6eebe1'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $env:TF_CLOUD_ORGANIZATION) { $env:TF_CLOUD_ORGANIZATION = $ExpectedHcpOrganization }

$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$azureRoot = Join-Path $repo 'environments\lab\azure'
$overlayPath = Join-Path $azureRoot '99-runtime.auto.tfvars.json'
$profileDirectory = Join-Path $repo '.lab-runtime\vpn'
. (Join-Path $PSScriptRoot 'files-dr-plan-guard.ps1')
$overlayChanged = $false
$applyStarted = $false
$overlayExisted = Test-Path -LiteralPath $overlayPath -PathType Leaf
$originalOverlay = if ($overlayExisted) { [IO.File]::ReadAllBytes($overlayPath) } else { $null }

function Need([string]$Name) {
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) { throw "Falta $Name en PATH." }
}

function TfOutput([string]$Name) {
    Push-Location $azureRoot
    try {
        $value = & terraform output -raw $Name 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) { throw "No se pudo leer el output Terraform '$Name': $value" }
        return $value.Trim()
    } finally { Pop-Location }
}

function ReadAzureOverlay {
    if (-not (Test-Path -LiteralPath $overlayPath)) { return [pscustomobject]@{} }
    return Get-Content -LiteralPath $overlayPath -Raw | ConvertFrom-Json
}

function ApplyFilesDrPlan([string]$PlanAction) {
    # Terraform plans can contain secrets. Keep the binary in the user's temp
    # directory, never print JSON, and remove it even if validation fails.
    $planPath = Join-Path ([IO.Path]::GetTempPath()) ("andeslog-files-dr-{0}.tfplan" -f [guid]::NewGuid().ToString('N'))
    Push-Location $azureRoot
    try {
        & terraform plan -input=false -no-color "-out=$planPath"
        if ($LASTEXITCODE -ne 0) { throw 'No se pudo generar el plan Azure.' }
        $rawPlan = & terraform show -json $planPath 2>$null
        if ($LASTEXITCODE -ne 0) { throw 'No se pudo inspeccionar el plan Azure de forma segura.' }
        Assert-AndeslogFilesDrPlan (($rawPlan | Out-String)) $PlanAction
        $script:applyStarted = $true
        & terraform apply -input=false -no-color $planPath
        if ($LASTEXITCODE -ne 0) { throw 'Terraform falló al aplicar el plan validado; puede haber cambios parciales.' }
    } finally {
        Pop-Location
        if (Test-Path -LiteralPath $planPath) { Remove-Item -LiteralPath $planPath -Force -ErrorAction Stop }
    }
}

try {
    Need 'terraform'
    Need 'az'
    if (-not $Execute) { throw 'Modo seguro: añade -Execute para sincronizar datos o cambiar el gateway regional.' }

    $subscription = ((& az account show --query id --output tsv 2>&1) | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $subscription -ne $ExpectedAzureSubscription) { throw 'La suscripción Azure activa no coincide con la suscripción configurada para AndesLog.' }

    if ($Action -eq 'Sync') {
        $publisher = Join-Path $PSScriptRoot 'publish-azure-functions.ps1'
        & $publisher -ExpectedSubscription $ExpectedAzureSubscription -SkipPackagePublish -RunSyncNow
        if ($LASTEXITCODE -ne 0) { throw 'La Function no aceptó la solicitud de sincronización; no se registró una copia local como exitosa.' }
        Write-Host 'Sincronización solicitada a la Function. Confirma FILES_DR_SYNC_SUCCESS en Application Insights antes de considerar válida la copia.'
        return
    }

    if (-not $env:TF_VAR_notification_email) {
        throw 'Define TF_VAR_notification_email con el correo autorizado para que Terraform conserve el Action Group y sus alertas al aplicar.'
    }
    $overlay = ReadAzureOverlay
    $overlay | Add-Member -NotePropertyName enable_remote_access -NotePropertyValue $true -Force
    $overlay | Add-Member -NotePropertyName enable_files_dr_replica -NotePropertyValue $true -Force
    $overlay | Add-Member -NotePropertyName enable_files_dr_gateway -NotePropertyValue ($Action -eq 'Activate') -Force
    $json = ConvertTo-Json -InputObject $overlay -Depth 30
    $overlayChanged = $true
    [IO.File]::WriteAllText($overlayPath, $json + "`n", (New-Object Text.UTF8Encoding($false)))

    if ($Action -eq 'Deactivate') {
        ApplyFilesDrPlan 'Deactivate'
        Write-Host 'Gateway y DNS Resolver regionales eliminados; la copia Azure Files y su Private Endpoint se conservan.'
        return
    }

    Write-Host 'Activate crea un Azure VPN Gateway zonal y un DNS Private Resolver en la región secundaria; ambos tienen coste horario mientras existan.'

    ApplyFilesDrPlan 'Activate'

    $resourceGroup = TfOutput 'resource_group_name'
    $gatewayName = TfOutput 'files_dr_gateway_name'
    $drLocation = TfOutput 'files_dr_location'
    if (-not $resourceGroup -or -not $gatewayName -or -not $drLocation) { throw 'Terraform no devolvió el grupo de recursos, región o gateway regional.' }
    $raw = & az network vnet-gateway vpn-client generate --resource-group $resourceGroup --name $gatewayName --processor-architecture Amd64 --output json 2>$null
    if ($LASTEXITCODE -ne 0) { throw 'Azure no pudo generar el perfil P2S regional; el gateway queda desplegado para diagnóstico.' }
    try { $result = ($raw | Out-String) | ConvertFrom-Json } catch { throw 'Azure devolvió un perfil P2S regional con formato inesperado.' }
    if ($result -is [string]) {
        $profileUrl = $result
    } elseif ($result -is [System.Collections.IDictionary]) {
        $profileUrl = $result['vpnProfileSASUrl']
    } else {
        $profileProperty = $result.PSObject.Properties | Where-Object Name -EQ 'vpnProfileSASUrl' | Select-Object -First 1
        if ($profileProperty) { $profileUrl = $profileProperty.Value }
    }
    if (-not $profileUrl -or $profileUrl -notmatch '^https://') { throw 'Azure no devolvió una URL temporal válida para el perfil VPN; no se imprimió.' }

    New-Item -ItemType Directory -Path $profileDirectory -Force | Out-Null
    $profilePath = Join-Path $profileDirectory "andeslog-$drLocation-vpn-client.zip"
    try { Invoke-WebRequest -Uri $profileUrl -OutFile $profilePath -TimeoutSec 90 -UseBasicParsing | Out-Null }
    catch { throw 'Se creó el gateway, pero no se pudo descargar el perfil VPN regional. Ejecuta az network vnet-gateway vpn-client generate después.' }
    Write-Host "Gateway P2S regional preparado. Perfil guardado en $profilePath; impórtalo en Azure VPN Client y conecta con Microsoft Entra ID."
} catch {
    if ($overlayChanged -and -not $applyStarted) {
        if ($overlayExisted) { [IO.File]::WriteAllBytes($overlayPath, $originalOverlay) }
        elseif (Test-Path -LiteralPath $overlayPath) { Remove-Item -LiteralPath $overlayPath -Force }
    }
    throw
}
