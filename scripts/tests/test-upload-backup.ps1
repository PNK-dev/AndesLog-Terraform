#requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$scriptPath = Join-Path $PSScriptRoot '..\upload-backup.ps1'
$path = Join-Path ([IO.Path]::GetTempPath()) ('andeslog-backup-test-' + [guid]::NewGuid().ToString('N') + '.dump')
$global:azCalls = @(); $global:awsCalls = @(); $global:azStatus = 0; $global:awsStatus = 0
function az { $global:azCalls += ,@($args); $global:LASTEXITCODE = $global:azStatus }
function aws { $global:awsCalls += ,@($args); $global:LASTEXITCODE = $global:awsStatus }
try {
    [IO.File]::WriteAllText($path, 'synthetic-backup')
    & $scriptPath -FilePath $path -AzureStorageAccount 'syntheticstorage' -S3Bucket 'syntheticbucket'
    if ($global:azCalls.Count -ne 1 -or $global:awsCalls.Count -ne 1) { throw 'No se consultaron ambos destinos esperados.' }
    $az = $global:azCalls[0]; $aws = $global:awsCalls[0]
    if ($az[($az.IndexOf('--overwrite') + 1)] -ne 'false' -or $az[($az.IndexOf('--type') + 1)] -ne 'block' -or
        $az[($az.IndexOf('--if-none-match') + 1)] -ne '*' -or $aws[0] -ne 's3api' -or $aws[1] -ne 'put-object' -or
        $aws[($aws.IndexOf('--if-none-match') + 1)] -ne '*') { throw 'Las subidas deben ser condicionales y no sobrescribir.' }
    $global:azCalls = @(); $global:awsCalls = @(); $global:azStatus = 1; $failed = $false
    try { & $scriptPath -FilePath $path -AzureStorageAccount 'syntheticstorage' -S3Bucket 'syntheticbucket' } catch { $failed = $true }
    if (-not $failed -or $global:awsCalls.Count -ne 0) { throw 'Si falla Azure, S3 no debe iniciarse.' }
    $global:azStatus = 0; $global:awsStatus = 1; $failed = $false
    try { & $scriptPath -FilePath $path -AzureStorageAccount 'syntheticstorage' -S3Bucket 'syntheticbucket' } catch {
        $failed = $_.Exception.Message -match 'Azure recibió el respaldo'
    }
    if (-not $failed) { throw 'El fallo parcial debe informar que la copia Azure permanece.' }
    [IO.File]::WriteAllText($path, '')
    $global:azCalls = @(); $failed = $false
    try { & $scriptPath -FilePath $path -AzureStorageAccount 'syntheticstorage' } catch { $failed = $true }
    if (-not $failed -or $global:azCalls.Count) { throw 'Un archivo vacío debe rechazarse antes de la carga.' }
    Write-Host 'OK: respaldos no sobrescriben y los fallos parciales se reportan.'
} finally {
    if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
}
