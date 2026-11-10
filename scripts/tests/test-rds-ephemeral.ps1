#requires -Version 5.1
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\rds-ephemeral.ps1')

$script:mockSecret = '{"username":"andeslog_master","password":"fake-password-123"}'
$script:secretReads = 0
function Get-AndeslogRdsMasterSecret([string]$SecretArn) {
    $script:secretReads++
    return $script:mockSecret
}
function ExpectFailure([scriptblock]$Operation, [string]$Pattern) {
    try { & $Operation } catch {
        if ($_.Exception.Message -match $Pattern) { return }
        throw
    }
    throw 'La operación debía fallar.'
}

$arn = 'arn:aws:secretsmanager:us-east-1:123456789012:secret:fixture'
$prior = [Environment]::GetEnvironmentVariable('TF_VAR_rds_master_password', 'Process')
try {
    [Environment]::SetEnvironmentVariable('TF_VAR_rds_master_password', 'preexisting-fake-value', 'Process')
    $script:seen = ''
    Invoke-WithAndeslogRdsPassword $arn { $script:seen = [Environment]::GetEnvironmentVariable('TF_VAR_rds_master_password', 'Process') }
    if ($script:seen -cne 'fake-password-123' -or [Environment]::GetEnvironmentVariable('TF_VAR_rds_master_password', 'Process') -cne 'preexisting-fake-value') { throw 'El secreto efímero no se preparó o restauró correctamente.' }
    function Test-OuterScope([string[]]$arguments) {
        Invoke-WithAndeslogRdsPassword $arn { $script:seenArgs = @($arguments) }
    }
    Test-OuterScope @('plan', '-input=false')
    if (($script:seenArgs -join '|') -ne 'plan|-input=false') { throw 'Los argumentos de Terraform no llegaron al bloque envuelto.' }
    ExpectFailure { Invoke-WithAndeslogRdsPassword $arn { throw 'fallo de terraform simulado' } } 'fallo de terraform simulado'
    if ([Environment]::GetEnvironmentVariable('TF_VAR_rds_master_password', 'Process') -cne 'preexisting-fake-value') { throw 'No se restauró el entorno tras un fallo.' }
    $script:mockSecret = '{"username":"otro","password":"fake-password-123"}'
    ExpectFailure { Invoke-WithAndeslogRdsPassword $arn { throw 'no debe ejecutarse' } } 'usuario esperado'
    $script:mockSecret = '{"username":"andeslog_master","password":"invalid@password"}'
    ExpectFailure { Invoke-WithAndeslogRdsPassword $arn { throw 'no debe ejecutarse' } } 'contraseña válida'
    $reads = $script:secretReads
    Invoke-WithAndeslogRdsPassword '' { $script:emptyOperation = $true }
    if (-not $script:emptyOperation -or $script:secretReads -ne $reads) { throw 'El modo administrado por RDS no debe consultar un secreto externo.' }
    ExpectFailure { Invoke-WithAndeslogRdsPassword 'invalid-arn' {} } 'ARN'
} finally {
    [Environment]::SetEnvironmentVariable('TF_VAR_rds_master_password', $prior, 'Process')
}
Write-Host 'OK: credencial temporal, limpieza, fallo y validación comprobados con datos ficticios.'
