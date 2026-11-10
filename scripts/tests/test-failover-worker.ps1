#requires -Version 5.1
param([Parameter(Mandatory)][string]$Url)
$ErrorActionPreference = 'Stop'
if ($Url -notmatch '^http://127\.0\.0\.1:[0-9]+/ready$') { throw 'Solo se permite el servidor local de prueba.' }
. (Join-Path $PSScriptRoot '..\failover-readiness.ps1')
. (Join-Path $PSScriptRoot '..\failover-observation.ps1')
$job = Start-AndeslogReadinessWorker $Url 15 250
try {
    Wait-AndeslogInitialReadiness $job
    $start = [Diagnostics.Stopwatch]::GetTimestamp()
    $script:failoverWatch = [Diagnostics.Stopwatch]::StartNew()
    # Simulate a blocking cloud API call while the worker continues independently.
    Start-Sleep -Milliseconds 1800
    $finish = [Diagnostics.Stopwatch]::GetTimestamp()
    $samples = @(Receive-Job -Job $job -Keep -ErrorAction Stop)
    $during = @($samples | Where-Object { $_.StartedTick -ge $start -and $_.FinishedTick -le $finish })
    if ($during.Count -lt 3 -or @($during | Where-Object { -not $_.Ok }).Count -lt 1) {
        throw 'La sonda independiente no registró la caída durante la llamada bloqueante.'
    }
    Write-Host "OK: $($during.Count) sondas durante la llamada, con errores observados."

    $tokens = $null; $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot '..\failover-test.ps1'), [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count) { throw 'Script de failover inválido.' }
    foreach ($name in @('PrintMetrics', 'MonitorRecovery')) {
        $definition = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
        . ([scriptblock]::Create($definition.Extent.Text))
    }
    function GetRdsStatus([string]$Identifier) { return [pscustomobject]@{ Status='available'; MultiAZ=$true; AZ='az-b' } }
    $Scenario = 'Database'; $TimeoutMinutes = 1
    $script:probeWorker = $job; $script:injectionTick = $start; $script:originalDbZone = 'az-a'
    $metrics = @{ Samples = (New-Object 'System.Collections.Generic.List[double]'); Failures = 0 }
    MonitorRecovery $Url '' '' 'simulated-db'
    if ($metrics.Samples.Count -lt 10 -or $metrics.Failures -lt 1) { throw 'El bucle no procesó las sondas de la llamada bloqueante.' }
    Stop-Job -Job $job
    try { MonitorRecovery $Url '' '' 'simulated-db'; throw 'Se aceptó un monitor detenido.' }
    catch { if ($_.Exception.Message -notmatch 'monitor independiente se detuvo') { throw } }
} finally { Stop-AndeslogReadinessWorker $job }
