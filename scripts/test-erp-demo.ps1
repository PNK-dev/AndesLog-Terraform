#requires -Version 5.1
<#
.SYNOPSIS
  Verifica login y registra un movimiento sintético en el ERP del laboratorio.
.EXAMPLE
  .\scripts\test-erp-demo.ps1 -Execute
#>
[CmdletBinding()]
param(
    [switch]$Execute,
    [string]$BaseUrl = '',
    [string]$SecretFile = ''
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $Execute) { throw 'Esta prueba crea un almacén, producto y movimiento sintéticos. Usa -Execute para ejecutarla.' }
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$awsRoot = Join-Path $repo 'environments\lab\aws'
if (-not $SecretFile) { $SecretFile = Join-Path $awsRoot 'andeslog.runtime.secret' }
if (-not $BaseUrl) {
    if (-not $env:TF_CLOUD_ORGANIZATION) { $env:TF_CLOUD_ORGANIZATION = 'AndesLog' }
    Push-Location $awsRoot
    try {
        $dns = (& terraform output -raw alb_dns_name 2>$null | Out-String).Trim()
        if ($LASTEXITCODE -ne 0 -or -not $dns) { throw 'No se pudo leer la dirección del ERP desde Terraform.' }
        $BaseUrl = "http://$dns"
    } finally { Pop-Location }
}
try { $uri = [uri]$BaseUrl } catch { throw 'Dirección ERP inválida.' }
if ($uri.Scheme -ne 'http' -or $uri.UserInfo -or $uri.Query -or $uri.Fragment -or $uri.AbsolutePath -ne '/' -or
    ($uri.Host -cne '127.0.0.1' -and $uri.Host -notmatch '^[a-z0-9-]+\.us-east-1\.elb\.amazonaws\.com$')) {
    throw 'La dirección debe ser el ALB de laboratorio us-east-1 o localhost de prueba.'
}
$base = $uri.GetLeftPart([UriPartial]::Authority)
if (-not (Test-Path -LiteralPath $SecretFile -PathType Leaf)) { throw 'No se encontró el archivo local de credenciales ERP.' }
$secrets = @{}
foreach ($line in Get-Content -LiteralPath $SecretFile -Encoding UTF8) {
    if ($line -match '^(BOOTSTRAP_ADMIN_USERNAME|BOOTSTRAP_ADMIN_PASSWORD)=(.*)$') { $secrets[$matches[1]] = $matches[2] }
}
if (-not $secrets['BOOTSTRAP_ADMIN_USERNAME'] -or -not $secrets['BOOTSTRAP_ADMIN_PASSWORD']) { throw 'Faltan credenciales iniciales del ERP.' }

function Hidden([string]$Html, [string]$Name) {
    $pattern = '<input\s+type="hidden"\s+name="' + [regex]::Escape($Name) + '"\s+value="([^"]+)"'
    $match = [regex]::Match($Html, $pattern)
    if (-not $match.Success) { throw "No se encontró el campo $Name en el formulario." }
    return [Net.WebUtility]::HtmlDecode($match.Groups[1].Value)
}
function FormPage([string]$Path, $Session) {
    $page = Invoke-WebRequest -Uri "$base$Path" -WebSession $Session -UseBasicParsing -TimeoutSec 20
    if ($page.BaseResponse.ResponseUri.AbsolutePath -ne $Path) { throw 'El ERP no mantuvo la sesión de prueba.' }
    return $page
}

try {
    $login = Invoke-WebRequest -Uri "$base/login" -SessionVariable session -UseBasicParsing -TimeoutSec 20
    $body = @{ csrf_token = (Hidden $login.Content 'csrf_token'); username = $secrets['BOOTSTRAP_ADMIN_USERNAME']; password = $secrets['BOOTSTRAP_ADMIN_PASSWORD'] }
    $null = Invoke-WebRequest -Uri "$base/login" -Method Post -Body $body -WebSession $session -UseBasicParsing -TimeoutSec 20
    $suffix = [guid]::NewGuid().ToString('N').Substring(0, 12).ToUpperInvariant()
    $code = "DEMO-$suffix"; $sku = "DEMO-$suffix"; $reason = "SMOKE-$suffix"
    $page = FormPage '/warehouses' $session
    $null = Invoke-WebRequest -Uri "$base/warehouses" -Method Post -Body @{ csrf_token=(Hidden $page.Content 'csrf_token'); code=$code; name='Almacen demostracion'; city='Lima' } -WebSession $session -UseBasicParsing -TimeoutSec 20
    $page = FormPage '/products' $session
    $null = Invoke-WebRequest -Uri "$base/products" -Method Post -Body @{ csrf_token=(Hidden $page.Content 'csrf_token'); sku=$sku; name='Producto demostracion'; unit='unidad' } -WebSession $session -UseBasicParsing -TimeoutSec 20
    $page = FormPage '/inventory' $session
    $warehouseMatch = [regex]::Match($page.Content, '(?s)<select name="warehouse_id".*?<option value="(\d+)">' + [regex]::Escape($code) + '\s*')
    $productMatch = [regex]::Match($page.Content, '(?s)<select name="product_id".*?<option value="(\d+)">' + [regex]::Escape($sku) + '\s*')
    if (-not $warehouseMatch.Success -or -not $productMatch.Success) { throw 'No se encontraron los datos sintéticos recién creados.' }
    $operation = Hidden $page.Content 'operation_id'
    $movement = @{ csrf_token=(Hidden $page.Content 'csrf_token'); operation_id=$operation; warehouse_id=$warehouseMatch.Groups[1].Value;
                   product_id=$productMatch.Groups[1].Value; movement_type='entrada'; quantity='3'; reason=$reason }
    $null = Invoke-WebRequest -Uri "$base/inventory" -Method Post -Body $movement -WebSession $session -UseBasicParsing -TimeoutSec 20
    $again = Invoke-WebRequest -Uri "$base/inventory" -Method Post -Body $movement -WebSession $session -UseBasicParsing -TimeoutSec 20
    if ($again.BaseResponse.ResponseUri.AbsolutePath -ne '/inventory' -or ([regex]::Matches($again.Content, [regex]::Escape($reason))).Count -ne 1) {
        throw 'El movimiento de prueba o su reintento no se pudo verificar.'
    }
    Write-Host "OK: acceso, almacén $code, producto $sku y un movimiento de inventario; el reintento no duplicó el registro."
    Write-Host "Datos sintéticos creados; operación $operation. La entrega a Azure se verifica por separado."
} finally {
    $secrets.Clear()
    $body = $null
    $session = $null
}
