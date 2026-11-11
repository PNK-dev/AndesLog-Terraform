#requires -Version 5.1
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\runtime-consistency-guard.ps1')

$path = Join-Path ([IO.Path]::GetTempPath()) ('andeslog-runtime-guard-' + [guid]::NewGuid().ToString('N') + '.txt')
$values = [ordered]@{
    APP_ENV = 'development'
    SECRET_KEY = 'local-test-key'
    DATABASE_URL = 'postgresql+psycopg://andeslog_app:test-password@db.example:5432/andeslog?sslmode=verify-full'
    BOOTSTRAP_ADMIN_USERNAME = 'admin'
    BOOTSTRAP_ADMIN_PASSWORD = 'local-admin-password'
    ERP_AZURE_INGEST_URL = 'https://example.azurewebsites.net/api/erp/events'
    ERP_AZURE_INGEST_HMAC_SECRET = 'local-test-hmac-secret'
}
function Write-TestRuntime([System.Collections.IDictionary]$Map, [string]$Extra = '') {
    $lines = @($Map.Keys | ForEach-Object { "$_=$($Map[$_])" })
    if ($Extra) { $lines += $Extra }
    [IO.File]::WriteAllText($path, (($lines -join "`n") + "`n"), (New-Object System.Text.UTF8Encoding($false)))
}
function Expect-Rejection([string]$Json) {
    $blocked = $false
    try { Assert-AndeslogRuntimeConsistency $path $Json } catch {
        $blocked = $true
        if ($_.Exception.Message -match 'local-test|test-password|local-admin-password|local-test-hmac') {
            throw 'El error mostró valores sensibles.'
        }
    }
    if (-not $blocked) { throw 'Se esperaba que el guard detuviera el despliegue.' }
}
try {
    $json = $values | ConvertTo-Json -Compress
    Write-TestRuntime $values
    Protect-AndeslogRuntimeSecret $path
    $protectedAcl = Get-Acl -LiteralPath $path
    if (-not $protectedAcl.AreAccessRulesProtected -or @($protectedAcl.Access | Where-Object { $_.IsInherited }).Count) { throw 'El archivo ERP existente heredó permisos.' }
    Assert-AndeslogRuntimeConsistency $path $json
    foreach ($key in @('APP_ENV', 'SECRET_KEY', 'DATABASE_URL', 'BOOTSTRAP_ADMIN_USERNAME', 'BOOTSTRAP_ADMIN_PASSWORD', 'ERP_AZURE_INGEST_URL', 'ERP_AZURE_INGEST_HMAC_SECRET')) {
        $altered = [ordered]@{}
        foreach ($name in $values.Keys) { $altered[$name] = $values[$name] }
        $altered[$key] += '-changed'
        Write-TestRuntime $altered
        Expect-Rejection $json
    }
    $incomplete = [ordered]@{}
    foreach ($name in $values.Keys) { if ($name -ne 'SECRET_KEY') { $incomplete[$name] = $values[$name] } }
    Write-TestRuntime $incomplete
    Expect-Rejection $json
    Write-TestRuntime $values 'SECRET_KEY=duplicate'
    Expect-Rejection $json
    Write-TestRuntime $values
    Expect-Rejection '{invalid-json'
    Expect-Rejection ''
    $badUrl = [ordered]@{}
    foreach ($name in $values.Keys) { $badUrl[$name] = $values[$name] }
    $badUrl['DATABASE_URL'] = 'postgresql://wrong-format/no-password'
    Write-TestRuntime $badUrl
    Expect-Rejection ($badUrl | ConvertTo-Json -Compress)
    $production = [ordered]@{}
    foreach ($name in $values.Keys) { $production[$name] = $values[$name] }
    $production['APP_ENV'] = 'production'
    Write-TestRuntime $production
    Expect-Rejection ($production | ConvertTo-Json -Compress)
    $partial = [ordered]@{}
    $noIntegration = [ordered]@{}
    foreach ($name in $values.Keys) {
        if ($name -ne 'ERP_AZURE_INGEST_HMAC_SECRET') { $partial[$name] = $values[$name] }
        if ($name -notin @('ERP_AZURE_INGEST_URL', 'ERP_AZURE_INGEST_HMAC_SECRET')) { $noIntegration[$name] = $values[$name] }
    }
    Write-TestRuntime $partial
    Expect-Rejection ($partial | ConvertTo-Json -Compress)
    Write-TestRuntime $noIntegration
    Assert-AndeslogRuntimeConsistency $path ($noIntegration | ConvertTo-Json -Compress)
    Write-TestRuntime $values
    function aws {
        $global:LASTEXITCODE = 0
        if ($args -notcontains '--region' -or $args -notcontains 'us-east-1') { throw 'wrong region' }
        return (@{ SecretString = $json } | ConvertTo-Json -Compress)
    }
    $retrieved = Get-AndeslogRuntimeSecretString 'arn:aws:secretsmanager:us-east-1:123456789012:secret:test'
    Assert-AndeslogRuntimeConsistency $path $retrieved
    function aws { $global:LASTEXITCODE = 1; throw 'local-test-secret-should-not-appear' }
    try { Get-AndeslogRuntimeSecretString 'arn:aws:secretsmanager:us-east-1:123456789012:secret:test'; throw 'expected failure' } catch {
        if ($_.Exception.Message -notmatch 'No se pudo verificar' -or $_.Exception.Message -match 'local-test') { throw }
    }
    Remove-Item -LiteralPath $path -Force
    Expect-Rejection $json
    Restore-AndeslogRuntimeSecret $path $json
    Protect-AndeslogRuntimeSecret $path
    Assert-AndeslogRuntimeConsistency $path $json
    $acl = Get-Acl -LiteralPath $path
    if (-not $acl.AreAccessRulesProtected -or @($acl.Access | Where-Object { $_.IsInherited }).Count) { throw 'El secreto restaurado heredó permisos.' }
    try { Restore-AndeslogRuntimeSecret $path $json; throw 'expected failure' } catch {
        if ($_.Exception.Message -notmatch 'No se pudo recuperar') { throw }
    }
    Assert-AndeslogRuntimeConsistency $path $json
    Remove-Item -LiteralPath $path -Force
    $invalid = [ordered]@{}
    foreach ($name in $values.Keys) { $invalid[$name] = $values[$name] }
    $invalid['SECRET_KEY'] = "invalid`nline"
    try { Restore-AndeslogRuntimeSecret $path ($invalid | ConvertTo-Json -Compress); throw 'expected failure' } catch {
        if ($_.Exception.Message -notmatch 'No se pudo recuperar') { throw }
    }
    if (Test-Path -LiteralPath $path) { throw 'No debe quedar un archivo para un secreto inválido.' }
    Write-Host 'OK: credenciales existentes ausentes, incompatibles o duplicadas bloquean Deploy sin exponer secretos.'
} finally {
    if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
}
