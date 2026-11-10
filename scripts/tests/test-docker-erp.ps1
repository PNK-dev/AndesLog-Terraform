#requires -Version 5.1
# Isolated local smoke test. No cloud credentials or user volumes are used.
param([string]$Image = 'andeslog-erp:deadline-check')
$ErrorActionPreference = 'Stop'
$suffix = [guid]::NewGuid().ToString('N').Substring(0, 12)
$net = "andeslog-smoke-$suffix"; $db = "$net-db"; $web = "$net-web"
$secret = Join-Path ([IO.Path]::GetTempPath()) "$net.secret"
try {
    & docker network create $net | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'No se pudo crear la red temporal.' }
    & docker run -d --name $db --network $net --network-alias db -e POSTGRES_USER=smoke -e POSTGRES_DB=andeslog -e POSTGRES_PASSWORD=local-test-only postgres:16-alpine | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'No se pudo iniciar PostgreSQL temporal.' }
    $ready = $false
    for ($i = 0; $i -lt 60; $i++) {
        & docker exec $db pg_isready -U smoke -d andeslog 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) { $ready = $true; break }
        Start-Sleep -Seconds 1
    }
    if (-not $ready) { throw 'PostgreSQL temporal no estuvo listo.' }
    & docker run -d --name $web --network $net -p '127.0.0.1::8000' -e SECRET_KEY=local-only-test-secret -e APP_ENV=development -e BOOTSTRAP_ADMIN_USERNAME=admin -e BOOTSTRAP_ADMIN_PASSWORD=local-only-test-password -e 'DATABASE_URL=postgresql+psycopg://smoke:local-test-only@db:5432/andeslog' $Image | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'No se pudo iniciar ERP temporal.' }
    $mapping = (& docker port $web '8000/tcp' | Out-String).Trim()
    if ($mapping -notmatch '^127\.0\.0\.1:(\d+)$') { throw 'Puerto temporal inesperado.' }
    $url = "http://127.0.0.1:$($matches[1])"
    $ready = $false
    for ($i = 0; $i -lt 60; $i++) {
        try {
            $result = Invoke-RestMethod "$url/api/health/ready" -TimeoutSec 2
            if ($result.status -eq 'ready' -and $result.database -eq 'ok') { $ready = $true; break }
        } catch { }
        Start-Sleep -Seconds 1
    }
    if (-not $ready) { throw 'El ERP temporal no alcanzó readiness.' }
    $login = Invoke-WebRequest "$url/login" -UseBasicParsing -TimeoutSec 5
    if ($login.StatusCode -ne 200 -or $login.Content -notmatch 'csrf_token') { throw 'El formulario de acceso temporal no está disponible.' }
    [IO.File]::WriteAllText($secret, "BOOTSTRAP_ADMIN_USERNAME=admin`nBOOTSTRAP_ADMIN_PASSWORD=local-only-test-password`n")
    & (Join-Path $PSScriptRoot '..\test-erp-demo.ps1') -BaseUrl $url -SecretFile $secret -Execute
    Write-Output 'OK: la imagen inicia, migra PostgreSQL local y sirve readiness y login.'
} finally {
    if ($net -notmatch '^andeslog-smoke-[0-9a-f]{12}$') { throw 'Nombre temporal inesperado.' }
    & docker rm -f $web $db 2>$null | Out-Null
    & docker network rm $net 2>$null | Out-Null
    if (Test-Path -LiteralPath $secret) { Remove-Item -LiteralPath $secret -Force }
}
