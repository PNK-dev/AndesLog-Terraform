#requires -Version 5.1
<#
.SYNOPSIS
  Verifica que ERP mantenga los eventos durante una interrupción de Azure Function.
.DESCRIPTION
  Detiene brevemente la Function de ingestión, crea un evento de prueba en PostgreSQL,
  verifica que la outbox lo conserve como pending, vuelve a iniciar Azure y espera
  que el worker desplegado lo entregue. La Function siempre se vuelve a iniciar en finally.
.EXAMPLE
  .\scripts\test-azure-integration-recovery.ps1 -Execute
#>
[CmdletBinding()]
param(
    [switch]$Execute,
    [ValidateRange(1, 30)]
    [int]$TimeoutMinutes = 10,
    [string]$ExpectedHcpOrganization = 'AndesLog',
    [string]$ExpectedAwsAccount = '406197219647'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $env:TF_CLOUD_ORGANIZATION) { $env:TF_CLOUD_ORGANIZATION = $ExpectedHcpOrganization }
if (-not $env:AWS_PROFILE) { $env:AWS_PROFILE = 'andeslog-academy' }

$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$awsRoot = Join-Path $repo 'environments\lab\aws'
$azureRoot = Join-Path $repo 'environments\lab\azure'
$temp = Join-Path ([IO.Path]::GetTempPath()) ('andeslog-integration-recovery-' + [guid]::NewGuid().ToString('N'))
$script:awsRegion = ''
$script:functionMayBeStopped = $false
$script:resourceGroup = ''
$script:functionName = ''

function Need([string]$Name) {
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) { throw "Falta $Name en PATH." }
}

function TfOutput([string]$Root, [string]$Name) {
    Push-Location $Root
    try {
        $value = & terraform output -raw $Name 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) { throw "No se pudo leer el output Terraform '$Name': $value" }
        return $value.Trim()
    } finally { Pop-Location }
}

function AwsJson([string[]]$Arguments) {
    $commandArguments = @('--region', $script:awsRegion) + $Arguments + @('--no-cli-pager')
    $raw = & aws @commandArguments 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { throw "aws $($Arguments -join ' ') falló: $raw" }
    if (-not $raw.Trim()) { return $null }
    return $raw | ConvertFrom-Json
}

function AzValue([string[]]$Arguments) {
    $raw = & az @Arguments 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { throw "az $($Arguments -join ' ') falló: $raw" }
    return $raw.Trim()
}

function GetFunctionState {
    # `functionapp show` returns the current state inside the ARM `properties` object.
    return AzValue @('functionapp', 'show', '--resource-group', $script:resourceGroup, '--name', $script:functionName, '--query', 'properties.state', '--output', 'tsv')
}

function WaitFunctionState([string]$Expected, [int]$Seconds = 300) {
    $deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
    do {
        $state = GetFunctionState
        if ($state -eq $Expected) { return }
        Start-Sleep -Seconds 5
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Azure Function no confirmó estado $Expected dentro de $Seconds segundos. Último estado: $state."
}

function InvokeSsm([string]$InstanceId, [string]$Image, [string]$Operation, [string]$EventId = '') {
    $safeImage = $Image
    if ($safeImage -notmatch '^[0-9]{12}\.dkr\.ecr\.[a-z0-9-]+\.amazonaws\.com/[A-Za-z0-9._/-]+:img-[A-Za-z0-9_.-]+$') {
        throw 'La referencia de imagen ERP no tiene el formato esperado.'
    }
    if ($Operation -eq 'create-and-fail') {
        $body = @'
set -euo pipefail
image='__IMAGE__'
env_file=/etc/andeslog-app/erp.env
cert=/etc/ssl/certs/aws-rds-global-bundle.pem
event_id=$(sudo docker run --rm --env-file "$env_file" -v "$cert:/etc/ssl/certs/aws-rds-global-bundle.pem:ro" "$image" flask --app app:create_app outbox-smoke)
sudo docker run --rm --env-file "$env_file" -v "$cert:/etc/ssl/certs/aws-rds-global-bundle.pem:ro" "$image" python -m app.outbox_worker --once --event-id "$event_id"
status=$(sudo docker run --rm --env-file "$env_file" -v "$cert:/etc/ssl/certs/aws-rds-global-bundle.pem:ro" "$image" flask --app app:create_app outbox-status --event-id "$event_id")
printf 'event_id=%s\nstatus=%s\n' "$event_id" "$status"
'@
        $body = $body.Replace('__IMAGE__', $safeImage)
    } elseif ($Operation -eq 'status') {
        if ($EventId -notmatch '^[0-9a-fA-F]{8}-(?:[0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$') { throw 'El ID de evento no es un UUID válido.' }
        $body = @'
set -euo pipefail
image='__IMAGE__'
env_file=/etc/andeslog-app/erp.env
cert=/etc/ssl/certs/aws-rds-global-bundle.pem
status=$(sudo docker run --rm --env-file "$env_file" -v "$cert:/etc/ssl/certs/aws-rds-global-bundle.pem:ro" "$image" flask --app app:create_app outbox-status --event-id '__EVENT_ID__')
printf 'status=%s\n' "$status"
'@
        $body = $body.Replace('__IMAGE__', $safeImage).Replace('__EVENT_ID__', $EventId)
    } else {
        throw 'Operación SSM interna no reconocida.'
    }

    $bytes = [Text.Encoding]::UTF8.GetBytes($body)
    $encoded = [Convert]::ToBase64String($bytes)
    $shellCommand = "printf '%s' '$encoded' | base64 -d | sudo bash"
    New-Item -ItemType Directory -Path $temp -Force | Out-Null
    $parametersPath = Join-Path $temp ([guid]::NewGuid().ToString('N') + '.json')
    $parameters = @{ commands = @($shellCommand) } | ConvertTo-Json -Compress
    [IO.File]::WriteAllText($parametersPath, $parameters, (New-Object System.Text.UTF8Encoding($false)))
    try {
        $awsArguments = @(
            '--region', $script:awsRegion, 'ssm', 'send-command', '--instance-ids', $InstanceId,
            '--document-name', 'AWS-RunShellScript', '--timeout-seconds', '120',
            '--parameters', "file://$parametersPath", '--query', 'Command.CommandId', '--output', 'text', '--no-cli-pager'
        )
        $result = & aws @awsArguments 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) { throw "aws ssm send-command falló: $result" }
        $commandId = $result.Trim()
    } finally { Remove-Item -LiteralPath $parametersPath -Force -ErrorAction SilentlyContinue }

    if ($commandId -notmatch '^[0-9a-fA-F-]{36}$') { throw 'AWS Systems Manager no devolvió un Command ID válido.' }
    $deadline = [DateTime]::UtcNow.AddMinutes(3)
    do {
        Start-Sleep -Seconds 3
        try {
            $invocation = AwsJson @('ssm', 'get-command-invocation', '--command-id', $commandId, '--instance-id', $InstanceId, '--output', 'json')
        } catch {
            if ($_.Exception.Message -match 'InvocationDoesNotExist') { continue }
            throw
        }
        if ($invocation.Status -eq 'Success') { return [string]$invocation.StandardOutputContent }
        if ($invocation.Status -in @('Cancelled', 'TimedOut', 'Failed', 'Cancelling')) {
            throw "Comando SSM terminó en estado $($invocation.Status): $($invocation.StatusDetails)."
        }
    } while ([DateTime]::UtcNow -lt $deadline)
    throw 'El comando SSM no terminó dentro de 3 minutos.'
}

function GetEventStatus([string]$InstanceId, [string]$Image, [string]$EventId) {
    $output = InvokeSsm $InstanceId $Image 'status' $EventId
    $match = [regex]::Match($output, '(?m)^status=(pending|processing|delivered|dead)\s*$')
    if (-not $match.Success) { throw 'No se pudo leer el estado de la outbox desde SSM.' }
    return $match.Groups[1].Value
}

try {
    Need 'terraform'; Need 'aws'; Need 'az'
    if (-not $Execute) { throw 'Modo seguro: añade -Execute para detener y reactivar temporalmente la Azure Function.' }

    $script:awsRegion = TfOutput $awsRoot 'aws_region'
    $account = ((& aws sts get-caller-identity --query Account --output text --no-cli-pager 2>&1) | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $account -ne $ExpectedAwsAccount) { throw "Cuenta AWS inesperada ('$account'); se requiere $ExpectedAwsAccount." }

    $subscriptionId = TfOutput $azureRoot 'subscription_id'
    $activeSubscription = AzValue @('account', 'show', '--query', 'id', '--output', 'tsv')
    if ($activeSubscription -ne $subscriptionId) { throw 'La suscripción Azure activa no coincide con el estado Terraform.' }

    $script:resourceGroup = TfOutput $azureRoot 'resource_group_name'
    $script:functionName = TfOutput $azureRoot 'erp_event_function_name'
    if (-not $script:resourceGroup -or -not $script:functionName) { throw 'Terraform no devolvió el Resource Group o la Function de ingestión.' }

    $alb = TfOutput $awsRoot 'alb_dns_name'
    $image = "$(TfOutput $awsRoot 'web_ecr_repository_url'):$(TfOutput $awsRoot 'web_erp_image_tag')"
    $groupName = TfOutput $awsRoot 'web_auto_scaling_group_name'
    $instances = AwsJson @('autoscaling', 'describe-auto-scaling-groups', '--auto-scaling-group-names', $groupName, '--query', "AutoScalingGroups[0].Instances[?LifecycleState=='InService' && HealthStatus=='Healthy'].InstanceId", '--output', 'json')
    $instanceId = @($instances | Where-Object { $_ }) | Select-Object -First 1
    if (-not $instanceId) { throw 'No hay nodos ERP sanos para ejecutar el chequeo seguro de PostgreSQL/outbox.' }
    $ssmArguments = @('--region', $script:awsRegion, 'ssm', 'describe-instance-information', '--filters', "Key=InstanceIds,Values=$instanceId", '--query', 'InstanceInformationList[0].PingStatus', '--output', 'text', '--no-cli-pager')
    $ssmStatus = (& aws @ssmArguments 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) { throw "No se pudo consultar Systems Manager: $ssmStatus" }
    if ($ssmStatus -ne 'Online') { throw 'El nodo ERP no está Online en Systems Manager; no se interrumpió Azure.' }

    $healthUrl = "http://$alb/api/health/ready"
    $health = Invoke-RestMethod -Uri $healthUrl -TimeoutSec 10
    if ($health.status -ne 'ready' -or $health.database -ne 'ok') { throw 'La prueba previa de readiness falló; no se interrumpió Azure.' }
    if ((GetFunctionState) -ne 'Running') { throw 'Azure Function no está Running antes de la prueba.' }

    Write-Host 'Deteniendo Azure Function para una prueba breve de recuperación del ERP outbox.'
    $script:functionMayBeStopped = $true
    AzValue @('functionapp', 'stop', '--resource-group', $script:resourceGroup, '--name', $script:functionName, '--output', 'none') | Out-Null
    WaitFunctionState 'Stopped' 180

    $output = InvokeSsm $instanceId $image 'create-and-fail'
    $idMatch = [regex]::Match($output, '(?m)^event_id=([0-9a-fA-F-]{36})\s*$')
    $statusMatch = [regex]::Match($output, '(?m)^status=(pending|processing|delivered|dead)\s*$')
    if (-not $idMatch.Success -or -not $statusMatch.Success) { throw 'SSM no devolvió el resultado de prueba esperado.' }
    $eventId = $idMatch.Groups[1].Value
    if ($statusMatch.Groups[1].Value -ne 'pending') {
        throw "Durante la caída de Azure el evento quedó $($statusMatch.Groups[1].Value); se esperaba pending para reintento durable."
    }
    Write-Host "Evento $eventId conservado como pending mientras Azure estaba detenido."
} finally {
    if ($script:functionMayBeStopped) {
        Write-Host 'Iniciando Azure Function y comprobando su recuperación.'
        AzValue @('functionapp', 'start', '--resource-group', $script:resourceGroup, '--name', $script:functionName, '--output', 'none') | Out-Null
        WaitFunctionState 'Running' 300
        $script:functionMayBeStopped = $false
    }
}

try {
    $deadline = [DateTime]::UtcNow.AddMinutes($TimeoutMinutes)
    $delivered = $false
    do {
        Start-Sleep -Seconds 10
        $eventStatus = GetEventStatus $instanceId $image $eventId
        Write-Host "Estado del evento tras reactivar Azure: $eventStatus."
        if ($eventStatus -eq 'delivered') { $delivered = $true; break }
        if ($eventStatus -eq 'dead') { throw 'El evento terminó en dead después de recuperar Azure.' }
        $health = Invoke-RestMethod -Uri $healthUrl -TimeoutSec 10
        if ($health.status -ne 'ready' -or $health.database -ne 'ok') { throw 'El ERP dejó de estar listo durante la recuperación de Azure.' }
    } while ([DateTime]::UtcNow -lt $deadline)
    if (-not $delivered) { throw "Azure volvió a Running, pero el worker no entregó $eventId en $TimeoutMinutes minutos." }
    Write-Host "Prueba completada: evento $eventId llegó a delivered y ERP/PostgreSQL permanecieron listos."
} finally {
    if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Recurse -Force }
}
