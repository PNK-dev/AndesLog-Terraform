#requires -Version 5.1
<#
.SYNOPSIS
  Ejecuta pruebas reversibles de continuidad para el laboratorio AndesLog.
.EXAMPLE
  .\scripts\failover-test.ps1 -Scenario WebNode -Execute
.EXAMPLE
  .\scripts\failover-test.ps1 -Scenario Database -Execute -ConfirmNoActiveTransactions
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('WebNode', 'Database', 'VpnTunnel')]
    [string]$Scenario,
    [switch]$Execute,
    [switch]$ConfirmNoActiveTransactions,
    [switch]$ConfirmVpnClientConnected,
    [ValidateRange(1, 30)]
    [int]$TimeoutMinutes = 20
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'failover-observation.ps1')
. (Join-Path $PSScriptRoot 'failover-readiness.ps1')
if (-not $env:TF_CLOUD_ORGANIZATION) { $env:TF_CLOUD_ORGANIZATION = 'AndesLog' }
if (-not $env:AWS_PROFILE) { $env:AWS_PROFILE = 'andeslog-academy' }

$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$awsRoot = Join-Path $repo 'environments\lab\aws'
$expectedAccount = '406197219647'
$script:awsRegion = ''
$metrics = @{ Samples = (New-Object 'System.Collections.Generic.List[double]'); Failures = 0 }
$script:failoverWatch = $null
$script:webVictim = ''
$script:originalWebIds = @()
$script:originalDbZone = ''
$script:dbIdentifier = ''
$script:probeWorker = $null
$script:injectionTick = 0L
Add-Type -AssemblyName System.Net.Http
$http = [System.Net.Http.HttpClient]::new()
$http.Timeout = [TimeSpan]::FromSeconds(4)

function Need([string]$Name) {
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) { throw "Falta $Name en PATH." }
}

function TfOutput([string]$Name) {
    Push-Location $awsRoot
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

function GetAppInstances([string]$GroupName) {
    $rows = AwsJson @('autoscaling', 'describe-auto-scaling-groups', '--auto-scaling-group-names', $GroupName, '--query', 'AutoScalingGroups[0].Instances', '--output', 'json')
    return @($rows)
}

function GetHealthyTargets([string]$TargetGroupArn) {
    $rows = AwsJson @('elbv2', 'describe-target-health', '--target-group-arn', $TargetGroupArn, '--query', 'TargetHealthDescriptions[?TargetHealth.State==`healthy`].Target.Id', '--output', 'json')
    return @($rows)
}

function GetRdsStatus([string]$Identifier) {
    return AwsJson @('rds', 'describe-db-instances', '--db-instance-identifier', $Identifier, '--query', 'DBInstances[0].{Status:DBInstanceStatus,MultiAZ:MultiAZ,Endpoint:Endpoint.Address,AZ:AvailabilityZone}', '--output', 'json')
}

function InvokeProbe([string]$Url) {
    $watch = [Diagnostics.Stopwatch]::StartNew()
    try {
        $response = $http.GetAsync($Url).GetAwaiter().GetResult()
        $body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        $status = [int]$response.StatusCode
        $response.Dispose()
        $watch.Stop()
        $ready = $false
        if ($status -eq 200) {
            try {
                $json = $body | ConvertFrom-Json
                $ready = $json.status -eq 'ready' -and $json.database -eq 'ok'
            } catch { }
        }
        return [pscustomobject]@{ Ok = $ready; StatusCode = $status; Milliseconds = $watch.Elapsed.TotalMilliseconds }
    } catch {
        $watch.Stop()
        return [pscustomobject]@{ Ok = $false; StatusCode = 0; Milliseconds = $watch.Elapsed.TotalMilliseconds }
    }
}

function PrintMetrics {
    if ($metrics.Samples.Count -eq 0) { return }
    $sorted = @($metrics.Samples | Sort-Object)
    $p95 = $sorted[[Math]::Max(0, [Math]::Ceiling($sorted.Count * 0.95) - 1)]
    $p99 = $sorted[[Math]::Max(0, [Math]::Ceiling($sorted.Count * 0.99) - 1)]
    Write-Host "Sondas: $($metrics.Samples.Count); fallidas: $($metrics.Failures); p95: $([Math]::Round($p95,1)) ms; p99: $([Math]::Round($p99,1)) ms."
}

function MonitorRecovery([string]$Url, [string]$GroupName, [string]$TargetGroupArn, [string]$DbIdentifier) {
    $healthyStreak = 0
    $probeNumber = 0
    $lastReviewed = 0
    $lastProbe = $null
    $recoveredAt = $null
    $lastFleetHealthy = $false
    $lastDbAvailable = $false
    $lastDbZone = ''
    $nextProgressSeconds = 60
    while ($script:failoverWatch.Elapsed.TotalMinutes -lt $TimeoutMinutes) {
        $probes = @(Receive-Job -Job $script:probeWorker -ErrorAction Stop)
        if ($script:probeWorker.State -ne 'Running') { throw 'El monitor independiente se detuvo; no se puede verificar la recuperación.' }
        foreach ($probe in $probes) {
            # Include requests already in flight when the fault was requested.
            if ([long]$probe.FinishedTick -lt $script:injectionTick) { continue }
            $lastProbe = $probe
            $probeNumber++
            Add-AndeslogProbe $metrics $probe.Ok ([double]$probe.Milliseconds)
            if ($probe.Ok) { $healthyStreak++ } else { $healthyStreak = 0 }
        }

        if ($probeNumber -ge $lastReviewed + 10) {
            $lastReviewed = $probeNumber
            if ($Scenario -eq 'WebNode') {
                $fleet = @(GetAppInstances $GroupName)
                $healthyTargetIds = @(GetHealthyTargets $TargetGroupArn)
                $lastFleetHealthy = Test-AndeslogWebRecovery $fleet $healthyTargetIds $script:webVictim $script:originalWebIds
            } elseif ($Scenario -eq 'Database') {
                $db = GetRdsStatus $DbIdentifier
                $lastDbAvailable = Test-AndeslogDatabaseRecovery $db $script:originalDbZone
                $lastDbZone = [string]$db.AZ
            }
        }

        if ($Scenario -eq 'Database' -and $script:failoverWatch.Elapsed.TotalSeconds -ge $nextProgressSeconds) {
            Write-Host "RDS: zona inicial $($script:originalDbZone), zona observada $lastDbZone; sondas $probeNumber."
            $nextProgressSeconds += 60
        }

        $probeFresh = $lastProbe -and (([Diagnostics.Stopwatch]::GetTimestamp() - [long]$lastProbe.FinishedTick) / [double][Diagnostics.Stopwatch]::Frequency -le 5)
        if ($Scenario -eq 'WebNode' -and $lastFleetHealthy -and $probeFresh -and $lastProbe.Ok) { $recoveredAt = [DateTime]::UtcNow; break }
        if ($Scenario -eq 'Database' -and $lastDbAvailable -and $probeFresh -and $healthyStreak -ge 5) { $recoveredAt = [DateTime]::UtcNow; break }
        Start-Sleep -Milliseconds 250
    }
    if (-not $recoveredAt) { throw "No se verificó la recuperación antes de $TimeoutMinutes minutos. Revisa las alarmas y no repitas la inyección." }
    PrintMetrics
    Write-Host "Recuperación observada desde la solicitud en $([Math]::Round($script:failoverWatch.Elapsed.TotalSeconds,1)) s; sondas independientes activas durante la solicitud."
}

function StartFaultObservation([string]$Url) {
    $script:probeWorker = Start-AndeslogReadinessWorker $Url ($TimeoutMinutes * 60 + 60)
    Wait-AndeslogInitialReadiness $script:probeWorker
    $script:injectionTick = [Diagnostics.Stopwatch]::GetTimestamp()
    $script:failoverWatch = [Diagnostics.Stopwatch]::StartNew()
}

try {
    Need 'terraform'; Need 'aws'
    if (-not $Execute) { throw 'Modo seguro: vuelve a ejecutar con -Execute para activar la prueba de failover.' }
    if ($Scenario -eq 'VpnTunnel') { throw 'La inyección de falla VPN no está implementada: AWS CLI no ofrece disable-vpn-tunnel ni enable-vpn-tunnel. No se ha modificado ningún túnel.' }
    $script:awsRegion = TfOutput 'aws_region'
    if ($script:awsRegion -notmatch '^[a-z0-9-]+$') { throw "Región AWS inesperada ('$script:awsRegion') en los outputs Terraform." }
    if ($Scenario -eq 'Database' -and -not $ConfirmNoActiveTransactions) { throw 'La prueba de RDS interrumpe sesiones. Confirma que no hay transacciones activas con -ConfirmNoActiveTransactions.' }
    $account = (& aws sts get-caller-identity --query Account --output text --no-cli-pager 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $account -ne $expectedAccount) { throw "Cuenta AWS inesperada ('$account'); se requiere $expectedAccount." }

    $alb = TfOutput 'alb_dns_name'
    $group = TfOutput 'web_auto_scaling_group_name'
    $targetGroup = TfOutput 'web_target_group_arn'
    $url = "http://$alb/api/health/ready"
    $probeUrl = $url
    $beforeProbe = InvokeProbe $url
    if (-not $beforeProbe.Ok) { throw "La prueba previa de readiness falló (HTTP $($beforeProbe.StatusCode)); no se inyectó ningún fallo." }

    if ($Scenario -eq 'WebNode') {
        $instances = @(GetAppInstances $group | Where-Object { $_.LifecycleState -eq 'InService' -and $_.HealthStatus -eq 'Healthy' })
        $healthyTargetIds = @(GetHealthyTargets $targetGroup)
        $ready = @($instances | Where-Object { $_.InstanceId -in $healthyTargetIds })
        $readyZones = @($ready | Select-Object -ExpandProperty AvailabilityZone -Unique)
        if ($ready.Count -lt 2 -or $readyZones.Count -lt 2) {
            throw 'Precondición fallida: se requieren dos instancias y dos targets saludables distribuidos en AZ distintas.'
        }
        $victim = $ready[0].InstanceId
        $script:webVictim = $victim
        $script:originalWebIds = @($instances | Select-Object -ExpandProperty InstanceId)
        Write-Host "Se terminará $victim; ASG conserva desired capacity y debe reemplazarlo."
        StartFaultObservation $url
        $null = AwsJson @('autoscaling', 'terminate-instance-in-auto-scaling-group', '--instance-id', $victim, '--no-should-decrement-desired-capacity', '--output', 'json')
        $probeUrl = $url
    } elseif ($Scenario -eq 'Database') {
        $identifier = TfOutput 'db_instance_identifier'
        $db = GetRdsStatus $identifier
        if (-not $db.MultiAZ -or $db.Status -ne 'available') { throw 'Precondición fallida: RDS no está disponible en Multi-AZ.' }
        if (-not $db.AZ) { throw 'Precondición fallida: no se pudo determinar la zona actual de RDS.' }
        $script:originalDbZone = $db.AZ
        Write-Host "Solicitando reinicio con failover de $identifier desde la zona $($db.AZ); no se enviarán escrituras durante la prueba."
        StartFaultObservation $url
        $null = AwsJson @('rds', 'reboot-db-instance', '--db-instance-identifier', $identifier, '--force-failover', '--output', 'json')
        $script:dbIdentifier = $identifier
        $probeUrl = $url
    }

    MonitorRecovery $probeUrl $group $targetGroup $script:dbIdentifier
} catch {
    if ($null -ne $script:probeWorker -and $script:injectionTick -gt 0) {
        try {
            foreach ($probe in @(Receive-Job -Job $script:probeWorker -ErrorAction Stop)) {
                if ([long]$probe.FinishedTick -ge $script:injectionTick) {
                    Add-AndeslogProbe $metrics $probe.Ok ([double]$probe.Milliseconds)
                }
            }
        } catch { Write-Warning 'No se pudieron recuperar todas las sondas pendientes.' }
    }
    PrintMetrics
    throw
} finally {
    if ($null -ne $script:probeWorker) { Stop-AndeslogReadinessWorker $script:probeWorker }
    $http.Dispose()
}
