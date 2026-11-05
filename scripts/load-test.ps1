#requires -Version 5.1
<#
.SYNOPSIS
  Ejecuta una prueba de carga pequeña y controlada contra el ALB del workspace AWS.
.DESCRIPTION
  Envía como máximo 300 GET a /api/health: 60 a intervalos de 1 s y 240 a intervalos
  de 500 ms. No modifica datos. Se detiene ante respuesta no-200, cuerpo inesperado,
  error de red o una respuesta superior a 2 s. No genera tráfico distribuido.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $env:TF_CLOUD_ORGANIZATION) {
    $env:TF_CLOUD_ORGANIZATION = 'AndesLog'
}

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$awsRoot = Join-Path $repoRoot 'environments\lab\aws'
$completed = 0
$latenciesMs = New-Object 'System.Collections.Generic.List[double]'
$client = $null
$failure = $null

try {
    if (-not (Get-Command terraform -ErrorAction SilentlyContinue)) {
        throw 'No encuentro terraform en PATH.'
    }
    Add-Type -AssemblyName System.Net.Http

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

    $url = "http://$albDns/api/health"
    $handler = [System.Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect = $true
    $client = [System.Net.Http.HttpClient]::new($handler)
    $client.Timeout = [TimeSpan]::FromSeconds(10)
    [void]$client.DefaultRequestHeaders.UserAgent.ParseAdd('AndesLog-ControlledLoadTest/1.0')

    $stages = @(
        @{ Name = 'Inicio'; Count = 60; IntervalMs = 1000 },
        @{ Name = 'Carga moderada'; Count = 240; IntervalMs = 500 }
    )

    Write-Host "Destino: $url"
    Write-Host 'Maximo: 300 GET secuenciales; sin operaciones que escriban en la base.'

    foreach ($stage in $stages) {
        Write-Host "Etapa $($stage.Name): $($stage.Count) solicitudes, intervalo minimo $($stage.IntervalMs) ms."

        for ($i = 1; $i -le $stage.Count; $i++) {
            $timer = [Diagnostics.Stopwatch]::StartNew()
            $response = $null
            try {
                $response = $client.GetAsync($url).GetAwaiter().GetResult()
                $statusCode = [int]$response.StatusCode
                $body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
                $timer.Stop()
                $latenciesMs.Add($timer.Elapsed.TotalMilliseconds)
                $completed++

                if ($statusCode -ne 200) {
                    throw "HTTP $statusCode en solicitud $completed."
                }
                $health = $body | ConvertFrom-Json
                if ($health.status -ne 'ok' -or $health.service -ne 'andeslog-erp') {
                    throw "La respuesta de salud no coincide con AndesLog en solicitud $completed."
                }
                if ($timer.Elapsed.TotalMilliseconds -gt 2000) {
                    throw "Respuesta lenta ($([math]::Round($timer.Elapsed.TotalMilliseconds)) ms) en solicitud $completed; prueba detenida."
                }

                if (($i % 20) -eq 0 -or $i -eq $stage.Count) {
                    Write-Progress -Activity 'Prueba de carga AndesLog' -Status "$completed / 300 completadas" -PercentComplete (($completed / 300) * 100)
                }
            } finally {
                if ($response) { $response.Dispose() }
                $timer.Stop()
            }

            if ($i -lt $stage.Count) {
                Start-Sleep -Milliseconds $stage.IntervalMs
            }
        }
    }
} catch {
    $failure = $_.Exception.Message
} finally {
    Write-Progress -Activity 'Prueba de carga AndesLog' -Completed
    if ($client) { $client.Dispose() }
}

if ($latenciesMs.Count -gt 0) {
    $sorted = @($latenciesMs | Sort-Object)
    [int]$p95Index = [math]::Max(0, [math]::Ceiling($sorted.Count * 0.95) - 1)
    Write-Host "Solicitudes completadas: $completed / 300"
    Write-Host "Latencia media: $([math]::Round(($latenciesMs | Measure-Object -Average).Average, 1)) ms"
    Write-Host "Latencia p95: $([math]::Round($sorted[$p95Index], 1)) ms"
    Write-Host "Latencia máxima: $([math]::Round($sorted[-1], 1)) ms"
}

if ($failure) {
    Write-Host "Prueba detenida: $failure" -ForegroundColor Red
    exit 1
}

Write-Host 'Prueba completada correctamente.' -ForegroundColor Green
