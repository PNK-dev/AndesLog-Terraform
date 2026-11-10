#requires -Version 5.1
# Build an isolated checkout from the staged indexes; no cloud apply occurs.
param([string]$ErpDirectory = '')
$ErrorActionPreference = 'Stop'
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
if (-not $ErpDirectory) {
    $ErpDirectory = @((Join-Path $repo '..\ERP-APP'), (Join-Path $repo '..\AndesLog-ERP')) |
        Where-Object { Test-Path -LiteralPath (Join-Path $_ 'Dockerfile') } | Select-Object -First 1
}
if (-not $ErpDirectory) { throw 'No se encontró el repositorio ERP hermano.' }
$tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$name = 'andeslog-clean-check-' + [guid]::NewGuid().ToString('N')
$root = [IO.Path]::GetFullPath((Join-Path $tempRoot $name))
$terraformCopy = Join-Path $root 'AndesLog-Terraform'
$erpCopy = Join-Path $root 'AndesLog-ERP'
$image = 'andeslog-erp:clean-' + [guid]::NewGuid().ToString('N').Substring(0, 12)
$imageBuilt = $false
try {
    New-Item -ItemType Directory -Force -Path $terraformCopy, $erpCopy | Out-Null
    foreach ($pair in @(@($repo, $terraformCopy), @($ErpDirectory, $erpCopy))) {
        $prefix = ($pair[1].Replace('\', '/') + '/')
        & git -C $pair[0] checkout-index --all "--prefix=$prefix"
        if ($LASTEXITCODE -ne 0) { throw 'No se pudo preparar la copia desde el índice Git.' }
    }
    foreach ($directory in @('environments\lab\aws', 'environments\lab\azure')) {
        Push-Location (Join-Path $terraformCopy $directory)
        try {
            & terraform init -backend=false -input=false -no-color | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "No se pudo inicializar $directory en la copia." }
            & terraform validate -no-color | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "No se pudo validar $directory en la copia." }
            & terraform test -no-color | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "Las pruebas Terraform fallaron en $directory de la copia." }
            if ($directory -eq 'environments\lab\azure') {
                # Graph in plan mode needs a backend. Remove only the cloud
                # stanza in this disposable copy so it uses an empty local state.
                $versionsPath = Join-Path (Get-Location).Path 'versions.tf'
                $versions = [IO.File]::ReadAllText($versionsPath)
                $pattern = '(?ms)^\s*cloud\s*\{\s*workspaces\s*\{\s*name\s*=\s*"andeslog-lab-azure"\s*\}\s*\}\s*'
                $withoutCloud = ([regex]::new($pattern)).Replace($versions, "`n", 1)
                if ($withoutCloud -ceq $versions) { throw 'No se encontró el bloque HCP de la copia temporal.' }
                [IO.File]::WriteAllText($versionsPath, $withoutCloud, (New-Object Text.UTF8Encoding($false)))
                & terraform init -backend=false -input=false -no-color | Out-Null
                if ($LASTEXITCODE -ne 0) { throw 'No se pudo inicializar el grafo local.' }
                $graph = (& terraform graph -type=plan) -join "`n"
                if ($LASTEXITCODE -ne 0 -or $graph -notmatch 'azurerm_virtual_network_peering\.files_dr_to_primary \(expand\)" -> "\[root\] azurerm_virtual_network_gateway\.main \(expand\)' -or
                    $graph -notmatch 'azurerm_virtual_network_peering\.files_dr_to_primary \(expand\)" -> "\[root\] azurerm_virtual_network_peering\.primary_to_files_dr \(expand\)' -or
                    $graph -notmatch 'azurerm_virtual_network_gateway\.files_dr \(expand\)" -> "\[root\] azurerm_virtual_network_peering\.files_dr_to_primary \(expand\)') {
                    throw 'Las dependencias de peering y gateway DR no están completas.'
                }
            }
        } finally { Pop-Location }
    }
    & docker build -q -t $image $erpCopy | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'No se pudo construir el ERP desde la copia limpia.' }
    $imageBuilt = $true
    & (Join-Path $terraformCopy 'scripts\tests\test-docker-erp.ps1') -Image $image
    Write-Host 'OK: copia limpia de ambos repositorios validada con Terraform y Docker.'
} finally {
    if ($imageBuilt) { & docker image rm $image 2>$null | Out-Null }
    if ($root.StartsWith(($tempRoot.TrimEnd('\') + '\'), [StringComparison]::OrdinalIgnoreCase) -and
        (Split-Path $root -Leaf) -match '^andeslog-clean-check-[0-9a-f]{32}$' -and (Test-Path -LiteralPath $root)) {
        Remove-Item -LiteralPath $root -Recurse -Force
    }
}
