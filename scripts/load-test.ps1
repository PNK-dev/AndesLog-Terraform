#requires -Version 5.1
<#
.SYNOPSIS
  Ejecuta una prueba pequeña, acotada y concurrente de solo lectura contra el ERP.
.DESCRIPTION
  El destino predeterminado se obtiene del workspace Terraform AWS y usa el ALB.
  Primero exige readiness. Después ejecuta la rampa 1, 2, 5 y hasta 10 según el
  máximo configurado, con 75 GET por etapa como máximo. Se detiene ante la primera
  respuesta inválida o lenta. No escribe datos ni intenta saturar el servicio.
.EXAMPLE
  .\scripts\load-test.ps1
.EXAMPLE
  .\scripts\load-test.ps1 -MaxConcurrency 5 -RequestsPerStage 40
#>
[CmdletBinding()]
param(
    [ValidateRange(1, 10)]
    [int]$MaxConcurrency = 10,
    [ValidateRange(10, 75)]
    [int]$RequestsPerStage = 75,
    [ValidateRange(1, 30)]
    [int]$TimeoutSeconds = 10,
    [ValidateRange(100, 10000)]
    [int]$LatencyThresholdMs = 2000,
    [string]$BaseUrl = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $env:TF_CLOUD_ORGANIZATION) {
    $env:TF_CLOUD_ORGANIZATION = 'AndesLog'
}

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$awsRoot = Join-Path $repoRoot 'environments\lab\aws'
$completed = 0
$failedRequests = 0
$allLatenciesMs = New-Object 'System.Collections.Generic.List[double]'
$client = $null
$failure = $null
$script:totalTimer = [Diagnostics.Stopwatch]::new()

function Get-Percentile([double[]]$Values, [double]$Percentile) {
    if (-not $Values -or $Values.Count -eq 0) { return 0.0 }
    $ordered = @($Values | Sort-Object)
    $index = [Math]::Max(0, [Math]::Ceiling($ordered.Count * $Percentile) - 1)
    return [double]$ordered[$index]
}

function Test-HealthBody([string]$Body) {
    try {
        $health = $Body | ConvertFrom-Json
        return $health.status -eq 'ready' -and $health.database -eq 'ok' -and $health.service -eq 'andeslog-erp'
    } catch {
        return $false
    }
}

function Invoke-OneRequest([string]$Url) {
    $timer = [Diagnostics.Stopwatch]::StartNew()
    try {
        $response = $client.GetAsync($Url).GetAwaiter().GetResult()
        try {
            $body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
            $status = [int]$response.StatusCode
            return [pscustomobject]@{
                StatusCode = $status
                Valid      = ($status -eq 200 -and (Test-HealthBody $body))
                LatencyMs  = $timer.Elapsed.TotalMilliseconds
                Error      = ''
            }
        } finally {
            $response.Dispose()
        }
    } catch {
        return [pscustomobject]@{
            StatusCode = 0
            Valid      = $false
            LatencyMs  = $timer.Elapsed.TotalMilliseconds
            Error      = $_.Exception.Message
        }
    } finally {
        $timer.Stop()
    }
}

function Invoke-Batch([string]$Url, [int]$Count) {
    # PowerShell 5.1 .NET Framework does not contain modern parallel cmdlets;
    # schedule at most MaxConcurrency async HttpClient requests per batch.
    $pending = New-Object 'System.Collections.Generic.List[System.Threading.Tasks.Task[System.Net.Http.HttpResponseMessage]]'
    $timers = New-Object 'System.Collections.Generic.List[System.Diagnostics.Stopwatch]'
    for ($n = 0; $n -lt $Count; $n++) {
        $watch = [Diagnostics.Stopwatch]::StartNew()
        $timers.Add($watch)
        $pending.Add($client.GetAsync($Url))
    }

    $tasks = [System.Threading.Tasks.Task[]]$pending.ToArray()
    try {
        $null = [System.Threading.Tasks.Task]::WhenAll($tasks).GetAwaiter().GetResult()
    } catch {
        # Inspect every result below so a network exception is reported with its
        # corresponding request and any successful response is always disposed.
    }

    $results = New-Object 'System.Collections.Generic.List[object]'
    for ($n = 0; $n -lt $pending.Count; $n++) {
        $watch = $timers[$n]
        $watch.Stop()
        $task = $pending[$n]
        if ($task.IsFaulted -or $task.IsCanceled) {
            if ($task.Exception) {
                $exceptionParts = New-Object 'System.Collections.Generic.List[string]'
                $currentException = $task.Exception
                while ($currentException) {
                    $exceptionParts.Add("$($currentException.GetType().Name): $($currentException.Message)")
                    $currentException = $currentException.InnerException
                }
                $message = $exceptionParts -join ' -> '
            } else {
                $message = 'Solicitud cancelada o agotó el tiempo.'
            }
            $results.Add([pscustomobject]@{ StatusCode = 0; Valid = $false; LatencyMs = $watch.Elapsed.TotalMilliseconds; Error = $message })
            continue
        }

        $response = $task.Result
        try {
            $body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
            $status = [int]$response.StatusCode
            $results.Add([pscustomobject]@{
                StatusCode = $status
                Valid      = ($status -eq 200 -and (Test-HealthBody $body))
                LatencyMs  = $watch.Elapsed.TotalMilliseconds
                Error      = ''
            })
        } catch {
            $results.Add([pscustomobject]@{ StatusCode = 0; Valid = $false; LatencyMs = $watch.Elapsed.TotalMilliseconds; Error = $_.Exception.Message })
        } finally {
            $response.Dispose()
        }
    }
    return $results.ToArray()
}

function Write-StageMetrics([string]$Name, [object[]]$Results, [double]$ElapsedSeconds) {
    $latencies = @($Results | ForEach-Object { [double]$_.LatencyMs })
    $errors = @($Results | Where-Object { -not $_.Valid }).Count
    $rps = if ($ElapsedSeconds -gt 0) { [Math]::Round($Results.Count / $ElapsedSeconds, 2) } else { 0 }
    Write-Host ("{0}: {1} solicitudes, errores {2}, RPS {3}, p50 {4} ms, p95 {5} ms, p99 {6} ms." -f `
        $Name, $Results.Count, $errors, $rps,
        [Math]::Round((Get-Percentile $latencies 0.50), 1),
        [Math]::Round((Get-Percentile $latencies 0.95), 1),
        [Math]::Round((Get-Percentile $latencies 0.99), 1))
}

try {
    if (-not (Get-Command terraform -ErrorAction SilentlyContinue)) {
        throw 'No encuentro terraform en PATH.'
    }
    Add-Type -AssemblyName System.Net.Http

    if (-not $BaseUrl) {
        Push-Location $awsRoot
        try {
            $albDns = (& terraform output -raw alb_dns_name 2>&1 | Out-String).Trim()
            if ($LASTEXITCODE -ne 0 -or -not $albDns) {
                throw "No pude leer alb_dns_name del workspace HCP Terraform: $albDns"
            }
        } finally {
            Pop-Location
        }
        if ($albDns -notmatch '^[a-zA-Z0-9.-]+\.elb\.amazonaws\.com$') {
            throw "El output alb_dns_name no parece un DNS de ALB AWS: $albDns"
        }
        $BaseUrl = "http://$albDns"
    }

    $baseUri = $null
    if (-not [Uri]::TryCreate($BaseUrl, [UriKind]::Absolute, [ref]$baseUri) -or $baseUri.Scheme -notin @('http', 'https')) {
        throw 'BaseUrl debe ser una URL HTTP o HTTPS absoluta.'
    }
    $url = $BaseUrl.TrimEnd('/') + '/api/health/ready'

    $handler = [System.Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect = $false
    $client = [System.Net.Http.HttpClient]::new($handler)
    $client.Timeout = [TimeSpan]::FromSeconds($TimeoutSeconds)
    [void]$client.DefaultRequestHeaders.UserAgent.ParseAdd('AndesLog-ControlledLoadTest/2.0')

    $concurrencyStages = @(1, 2, 5, 10) | Where-Object { $_ -le $MaxConcurrency }
    if ($concurrencyStages[-1] -ne $MaxConcurrency) { $concurrencyStages += $MaxConcurrency }
    $concurrencyStages = @($concurrencyStages | Select-Object -Unique)
    $expectedRequests = $RequestsPerStage * $concurrencyStages.Count

    Write-Host "Destino: $url"
    Write-Host ("Límite: {0} GET; concurrencia máxima {1}; sin escrituras." -f $expectedRequests, $MaxConcurrency)

    # Fail closed: do not produce load when the application is already unhealthy.
    $preflight = Invoke-OneRequest $url
    if (-not $preflight.Valid) {
        $detail = if ($preflight.Error) { $preflight.Error } else { "HTTP $($preflight.StatusCode) o cuerpo de salud inesperado" }
        throw "Preflight falló ($detail); no se generó carga."
    }
    Write-Host "Preflight readiness OK en $([Math]::Round($preflight.LatencyMs,1)) ms."

    $script:totalTimer.Start()
    foreach ($concurrency in $concurrencyStages) {
        $stageResults = New-Object 'System.Collections.Generic.List[object]'
        $stageTimer = [Diagnostics.Stopwatch]::StartNew()
        $remaining = $RequestsPerStage
        while ($remaining -gt 0) {
            $batchSize = [Math]::Min($concurrency, $remaining)
            $batch = Invoke-Batch $url $batchSize
            foreach ($item in $batch) {
                $stageResults.Add($item)
                $allLatenciesMs.Add([double]$item.LatencyMs)
                $completed++
                if (-not $item.Valid -or $item.LatencyMs -gt $LatencyThresholdMs) { $failedRequests++ }
            }
            $remaining -= $batchSize

            $bad = @($batch | Where-Object { -not $_.Valid -or $_.LatencyMs -gt $LatencyThresholdMs })
            if ($bad.Count -gt 0) {
                $first = $bad[0]
                $detail = if ($first.Error) { $first.Error } else { "HTTP $($first.StatusCode), $([Math]::Round($first.LatencyMs)) ms" }
                throw "Etapa de concurrencia $concurrency detenida: $detail. Se detuvo el ensayo para limitar impacto."
            }
        }
        $stageTimer.Stop()
        $stageRows = $stageResults.ToArray()
        Write-StageMetrics "Concurrencia $concurrency" $stageRows $stageTimer.Elapsed.TotalSeconds
        if ($concurrency -ne $concurrencyStages[-1]) { Start-Sleep -Milliseconds 500 }
    }
    $script:totalTimer.Stop()
} catch {
    $failure = "$($_.Exception.Message) (línea $($_.InvocationInfo.ScriptLineNumber))."
} finally {
    if ($script:totalTimer.IsRunning) { $script:totalTimer.Stop() }
    if ($client) { $client.Dispose() }
}

if ($allLatenciesMs.Count -gt 0) {
    Write-Host "Solicitudes completadas: $completed / máximo $expectedRequests; errores/lentas: $failedRequests"
    Write-Host ("p50 {0} ms; p95 {1} ms; p99 {2} ms; máximo {3} ms; duración {4} s." -f `
        [Math]::Round((Get-Percentile ([double[]]$allLatenciesMs.ToArray()) 0.50), 1),
        [Math]::Round((Get-Percentile ([double[]]$allLatenciesMs.ToArray()) 0.95), 1),
        [Math]::Round((Get-Percentile ([double[]]$allLatenciesMs.ToArray()) 0.99), 1),
        [Math]::Round((($allLatenciesMs | Measure-Object -Maximum).Maximum), 1),
        [Math]::Round($script:totalTimer.Elapsed.TotalSeconds, 1))
}

if ($failure) {
    Write-Host "Prueba detenida: $failure" -ForegroundColor Red
    exit 1
}

Write-Host 'Prueba completada correctamente.' -ForegroundColor Green
