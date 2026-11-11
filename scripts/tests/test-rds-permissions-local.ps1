#requires -Version 5.1
param([string]$Image = 'andeslog-erp:permissions-test', [string]$ErpDirectory = '')
$ErrorActionPreference = 'Stop'
$suffix = [guid]::NewGuid().ToString('N').Substring(0, 12)
$network = "andeslog-db-perms-$suffix"
$database = "$network-db"
$scriptsPath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
if (-not $ErpDirectory) {
    foreach ($candidate in @((Join-Path $repo 'ERP-APP'), (Join-Path $repo '..\ERP-APP'), (Join-Path $repo '..\AndesLog-ERP'))) {
        if (Test-Path -LiteralPath (Join-Path $candidate 'Dockerfile')) { $ErpDirectory = [IO.Path]::GetFullPath($candidate); break }
    }
}
if (-not $ErpDirectory -or -not (Test-Path -LiteralPath (Join-Path $ErpDirectory 'Dockerfile'))) { throw 'No se encontró el repositorio ERP; usa -ErpDirectory.' }
try {
    & docker build --tag $Image $ErpDirectory
    if ($LASTEXITCODE -ne 0) { throw 'No se pudo construir la imagen ERP de prueba.' }
    & docker network create $network | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'No se pudo crear la red temporal.' }
    & docker run -d --name $database --network $network --network-alias db -e POSTGRES_PASSWORD=local-only-postgres-password postgres:16-alpine | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'No se pudo iniciar PostgreSQL temporal.' }
    $ready = $false
    for ($i = 0; $i -lt 60; $i++) {
        & docker exec $database pg_isready -U postgres 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) { $ready = $true; break }
        Start-Sleep -Seconds 1
    }
    if (-not $ready) { throw 'La base temporal no estuvo lista.' }
    & docker run --rm --network $network --mount "type=bind,source=$scriptsPath,target=/tests,readonly" $Image python /tests/tests/run_db_privileges.py
    if ($LASTEXITCODE -ne 0) { throw 'La prueba local de permisos falló.' }
    & docker exec -e PGPASSWORD=local-only-app-password $database pg_dump -h 127.0.0.1 -U andeslog_app -d andeslog --format=custom --no-owner --file=/tmp/andeslog-test.dump
    if ($LASTEXITCODE -ne 0) { throw 'El usuario limitado no pudo generar el backup de prueba.' }
    & docker exec $database psql -U postgres -d postgres -v ON_ERROR_STOP=1 -c 'CREATE DATABASE andeslog_restored OWNER lab_owner' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'No se pudo crear el destino temporal de restauración.' }
    & docker exec $database pg_restore -U lab_owner -d andeslog_restored --no-owner --no-privileges --exit-on-error /tmp/andeslog-test.dump
    if ($LASTEXITCODE -ne 0) { throw 'La restauración aislada de prueba falló.' }
    $count = (& docker exec $database psql -U lab_owner -d andeslog_restored -t -A -c "SELECT count(*) FROM warehouse WHERE code='LOCAL'" | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $count -ne '1') { throw 'Los datos de prueba no coinciden después de la restauración.' }
    Write-Host 'OK: pg_dump del usuario limitado y restauración aislada local verificaron el almacén de prueba.'
} finally {
    if ($network -notmatch '^andeslog-db-perms-[0-9a-f]{12}$') { throw 'Nombre temporal inesperado.' }
    & docker rm -f $database 2>$null | Out-Null
    & docker network rm $network 2>$null | Out-Null
}
