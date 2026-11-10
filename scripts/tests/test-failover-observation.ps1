#requires -Version 5.1
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\failover-observation.ps1')

function Require([bool]$Condition, [string]$Reason) { if (-not $Condition) { throw $Reason } }
function Node([string]$Id, [string]$Zone) {
    return [pscustomobject]@{ InstanceId = $Id; AvailabilityZone = $Zone; LifecycleState = 'InService'; HealthStatus = 'Healthy' }
}

$metrics = @{ Samples = (New-Object 'System.Collections.Generic.List[double]'); Failures = 0 }
Add-AndeslogProbe $metrics $true 10
Add-AndeslogProbe $metrics $false 20
Add-AndeslogProbe $metrics $false 30
Require ($metrics.Samples.Count -eq 3 -and $metrics.Failures -eq 2) 'Conteo de sondas incorrecto.'

$original = @('i-old-a', 'i-old-b')
$before = @((Node 'i-old-a' 'az-a'), (Node 'i-old-b' 'az-b'))
$after = @((Node 'i-new-a' 'az-a'), (Node 'i-old-b' 'az-b'))
Require (-not (Test-AndeslogWebRecovery $before $original 'i-old-a' $original)) 'No debe aceptar la flota anterior.'
Require (Test-AndeslogWebRecovery $after @('i-new-a', 'i-old-b') 'i-old-a' $original) 'No detectó el reemplazo saludable.'
Require (-not (Test-AndeslogWebRecovery $after @('i-new-a') 'i-old-a' $original)) 'No debe aceptar un único target saludable.'
$sameZone = @((Node 'i-new-a' 'az-b'), (Node 'i-old-b' 'az-b'))
Require (-not (Test-AndeslogWebRecovery $sameZone @('i-new-a', 'i-old-b') 'i-old-a' $original)) 'No debe aceptar una única zona.'
$victimStillPresent = $after + @((Node 'i-old-a' 'az-a'))
Require (-not (Test-AndeslogWebRecovery $victimStillPresent @('i-new-a', 'i-old-b') 'i-old-a' $original)) 'No debe aceptar la víctima aún presente.'

Require (-not (Test-AndeslogDatabaseRecovery ([pscustomobject]@{ Status='available'; MultiAZ=$true; AZ='az-a' }) 'az-a')) 'No debe aceptar RDS en la zona original.'
Require (Test-AndeslogDatabaseRecovery ([pscustomobject]@{ Status='available'; MultiAZ=$true; AZ='az-b' }) 'az-a') 'No detectó el cambio de zona.'
Require (-not (Test-AndeslogDatabaseRecovery ([pscustomobject]@{ Status='rebooting'; MultiAZ=$true; AZ='az-b' }) 'az-a')) 'No debe aceptar RDS reiniciando.'

# Exercise the real monitoring loop with simulated readiness and RDS responses,
# without loading the main script or invoking AWS.
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot '..\failover-test.ps1'), [ref]$tokens, [ref]$parseErrors)
Require ($parseErrors.Count -eq 0) 'El script de failover tiene errores de sintaxis.'
foreach ($name in @('PrintMetrics', 'MonitorRecovery')) {
    $definition = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
    Require ($null -ne $definition) "Falta la función $name."
    . ([scriptblock]::Create($definition.Extent.Text))
}
function Receive-Job {
    [CmdletBinding()]
    param($Job)
    foreach ($index in 1..10) {
        $tick = [Diagnostics.Stopwatch]::GetTimestamp()
        [pscustomobject]@{ Ok = ($index -gt 3); Milliseconds = 15; StartedTick = $tick; FinishedTick = $tick }
    }
}
function GetRdsStatus([string]$Identifier) { return [pscustomobject]@{ Status='available'; MultiAZ=$true; AZ='az-b' } }
function Start-Sleep { }
$Scenario = 'Database'
$TimeoutMinutes = 1
$script:failoverWatch = [Diagnostics.Stopwatch]::StartNew()
$script:probeWorker = [pscustomobject]@{ State = 'Running' }
$script:injectionTick = 0L
$script:originalDbZone = 'az-a'
$metrics = @{ Samples = (New-Object 'System.Collections.Generic.List[double]'); Failures = 0 }
MonitorRecovery 'http://127.0.0.1' '' '' 'test-db'
Require ($metrics.Samples.Count -eq 10 -and $metrics.Failures -eq 3) 'El bucle real no contabilizó las fallas observadas.'
$script:probeWorker.State = 'Failed'
try { MonitorRecovery 'http://127.0.0.1' '' '' 'test-db'; throw 'Se aceptó un monitor fallido.' }
catch { if ($_.Exception.Message -notmatch 'monitor independiente se detuvo') { throw } }

$vpnError = ''
try { & (Join-Path $PSScriptRoot '..\failover-test.ps1') -Scenario VpnTunnel -Execute }
catch { $vpnError = $_.Exception.Message }
Require ($vpnError -match 'no est.* implementada') "El escenario VPN debe detenerse antes de contactar AWS: $vpnError"
Write-Host 'OK: observación de fallos, reemplazo y cambio de zona.'
