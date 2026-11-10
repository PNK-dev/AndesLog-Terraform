#requires -Version 5.1
<# Mirror an already-published immutable ERP image between two regional ECR repositories. #>
param(
    [string]$SourceRegion = 'us-east-1',
    [string]$DestinationRegion = 'us-west-2',
    [string]$Repository = 'andeslog-lab-erp',
    [string]$ImageTag = '',
    [string]$ExpectedAccount = '',
    [string]$RegionalDrEnabled = '',
    [string]$SourceRepositoryUrl = '',
    [string]$DestinationRepositoryUrl = '',
    [switch]$LibraryOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-MirrorAccount {
    $value = & aws sts get-caller-identity --query Account --output text --no-cli-pager
    if ($LASTEXITCODE -ne 0) { throw 'No se pudo verificar la identidad de AWS.' }
    return [string]$value
}

function Get-MirrorDigest([string]$Region, [string]$RepositoryName, [string]$Tag) {
    # The tag is validated before interpolation; list-images avoids treating
    # the expected absence of a destination tag as an AWS CLI error.
    $raw = & aws ecr list-images --region $Region --repository-name $RepositoryName --filter tagStatus=TAGGED --query "imageIds[?imageTag=='$Tag'].imageDigest" --output json --no-cli-pager
    if ($LASTEXITCODE -ne 0) { throw "No se pudo consultar el repositorio ECR en $Region." }
    $items = @((ConvertFrom-Json -InputObject ($raw | Out-String)) | Where-Object { $null -ne $_ })
    if ($items.Count -eq 0) { return '' }
    if ($items.Count -ne 1 -or [string]$items[0] -notmatch '^sha256:[0-9a-f]{64}$') { throw 'ECR devolvió un digest inesperado.' }
    return [string]$items[0]
}

function Connect-MirrorRegistry([string]$Region, [string]$Registry) {
    # Credentials are streamed to Docker and never placed in arguments or logs.
    & aws ecr get-login-password --region $Region --no-cli-pager | & docker login --username AWS --password-stdin $Registry
    if ($LASTEXITCODE -ne 0) { throw "Falló la autenticación del registro ECR en $Region." }
}

function Invoke-MirrorDocker([string[]]$Arguments) {
    & docker @Arguments
    if ($LASTEXITCODE -ne 0) { throw "Falló docker $($Arguments[0])." }
}

function Sync-AndeslogImage([string]$From, [string]$To, [string]$RepositoryName, [string]$Tag, [string]$Account) {
    if ($From -notmatch '^[a-z]{2}(-[a-z]+)+-[0-9]+$' -or $To -notmatch '^[a-z]{2}(-[a-z]+)+-[0-9]+$' -or $From -eq $To) { throw 'Las regiones deben ser distintas y tener un formato válido.' }
    if ($From.StartsWith('cn-') -or $To.StartsWith('cn-')) { throw 'La partición de China usa un dominio ECR distinto y no está soportada por este comando.' }
    if ($RepositoryName -notmatch '^[a-z0-9]+(?:[._/-][a-z0-9]+)*$') { throw 'El repositorio ECR tiene un formato inválido.' }
    if ($Tag -notmatch '^img-[A-Za-z0-9_.-]{1,120}$') { throw 'Usa una etiqueta de imagen inmutable img- válida.' }
    if ($Account -notmatch '^[0-9]{12}$' -or (Get-MirrorAccount) -ne $Account) { throw 'La cuenta AWS activa no coincide con la cuenta esperada.' }

    $sourceDigest = Get-MirrorDigest $From $RepositoryName $Tag
    if (-not $sourceDigest) { throw 'La etiqueta no existe en el repositorio ECR de origen.' }
    $targetDigest = Get-MirrorDigest $To $RepositoryName $Tag
    if ($targetDigest) {
        if ($targetDigest -ne $sourceDigest) { throw 'La etiqueta inmutable ya existe en destino con un digest distinto; no se reemplazó.' }
        Write-Host 'La imagen regional ya coincide con el digest de origen.'
        return
    }

    $sourceRegistry = "$Account.dkr.ecr.$From.amazonaws.com"
    $targetRegistry = "$Account.dkr.ecr.$To.amazonaws.com"
    $sourceImage = "$sourceRegistry/$RepositoryName@$sourceDigest"
    $targetImage = "${targetRegistry}/${RepositoryName}:$Tag"
    Connect-MirrorRegistry $From $sourceRegistry
    Connect-MirrorRegistry $To $targetRegistry
    Invoke-MirrorDocker -Arguments @('pull', $sourceImage)
    Invoke-MirrorDocker -Arguments @('tag', $sourceImage, $targetImage)
    Invoke-MirrorDocker -Arguments @('push', $targetImage)
    $verifiedDigest = Get-MirrorDigest $To $RepositoryName $Tag
    if ($verifiedDigest -ne $sourceDigest) { throw 'El digest de destino difiere del origen; no habilites el ERP de recuperación.' }
    Write-Host 'La imagen regional quedó publicada y verificada por digest.'
}

function Sync-AndeslogConfiguredImage([string]$Enabled, [string]$SourceUrl, [string]$DestinationUrl, [string]$Tag, [string]$Account) {
    if ($Enabled -notin @('true', 'false')) { throw 'No se pudo determinar si la recuperación regional está habilitada.' }
    if ($Enabled -eq 'false') {
        if ($DestinationUrl) { throw 'El estado regional está deshabilitado pero se recibió un registro de recuperación.' }
        Write-Host 'La publicación regional está deshabilitada.'
        return
    }

    $pattern = '^(?<account>[0-9]{12})\.dkr\.ecr\.(?<region>[a-z0-9-]+)\.amazonaws\.com/(?<repository>[a-z0-9]+(?:[._/-][a-z0-9]+)*)$'
    $sourceMatch = [regex]::Match($SourceUrl, $pattern)
    $targetMatch = [regex]::Match($DestinationUrl, $pattern)
    if (-not $sourceMatch.Success -or -not $targetMatch.Success) { throw 'Las URLs de ECR primaria y regional deben ser válidas.' }
    if ($sourceMatch.Groups['account'].Value -ne $Account -or $targetMatch.Groups['account'].Value -ne $Account -or $sourceMatch.Groups['repository'].Value -ne $targetMatch.Groups['repository'].Value) {
        throw 'Los registros ECR deben usar la cuenta esperada y el mismo repositorio.'
    }
    Sync-AndeslogImage $sourceMatch.Groups['region'].Value $targetMatch.Groups['region'].Value $sourceMatch.Groups['repository'].Value $Tag $Account
}

if (-not $LibraryOnly) {
    if ($RegionalDrEnabled) {
        Sync-AndeslogConfiguredImage $RegionalDrEnabled $SourceRepositoryUrl $DestinationRepositoryUrl $ImageTag $ExpectedAccount
    } else {
        Sync-AndeslogImage $SourceRegion $DestinationRegion $Repository $ImageTag $ExpectedAccount
    }
}
