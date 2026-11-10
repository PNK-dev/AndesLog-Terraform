#requires -Version 5.1

function Get-AndeslogRdsMasterSecret([string]$SecretArn) {
    $region = ($SecretArn -split ':')[3]
    $raw = & aws secretsmanager get-secret-value --region $region --secret-id $SecretArn --query SecretString --output text --no-cli-pager 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $raw) { throw 'No se pudo leer el secreto maestro externo en AWS Secrets Manager.' }
    return ($raw | Out-String).Trim()
}

function Invoke-WithAndeslogRdsPassword([string]$SecretArn, [scriptblock]$Operation) {
    if (-not $SecretArn) { & $Operation; return }
    if ($SecretArn -notmatch '^arn:[^:]+:secretsmanager:[^:]+:[0-9]{12}:secret:.+$') { throw 'El ARN del secreto maestro externo no es válido.' }
    try { $secret = Get-AndeslogRdsMasterSecret $SecretArn | ConvertFrom-Json }
    catch { throw 'No se pudo leer o interpretar el secreto maestro externo.' }
    if (-not $secret -or -not ($secret.PSObject.Properties.Name -contains 'username') -or
        -not ($secret.PSObject.Properties.Name -contains 'password') -or
        $secret.username -cne 'andeslog_master' -or $secret.password -isnot [string] -or
        $secret.password -notmatch '^[!-~]{8,128}$' -or $secret.password -match '[/"@'']') {
        throw 'El secreto maestro externo debe contener el usuario esperado y una contraseña válida.'
    }

    $previous = [Environment]::GetEnvironmentVariable('TF_VAR_rds_master_password', 'Process')
    try {
        [Environment]::SetEnvironmentVariable('TF_VAR_rds_master_password', $secret.password, 'Process')
        & $Operation
    } finally {
        [Environment]::SetEnvironmentVariable('TF_VAR_rds_master_password', $previous, 'Process')
        $secret = $null
    }
}
