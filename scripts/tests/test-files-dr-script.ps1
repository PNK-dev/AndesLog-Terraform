#requires -Version 5.1
$ErrorActionPreference = 'Stop'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ("andeslog-files-dr-test-{0}" -f [guid]::NewGuid().ToString('N'))
$savedEmail = $env:TF_VAR_notification_email
$savedOrg = $env:TF_CLOUD_ORGANIZATION
$global:mockApplyCount = 0
try {
    New-Item -ItemType Directory -Force -Path (Join-Path $testRoot 'scripts'), (Join-Path $testRoot 'environments\lab\azure') | Out-Null
    Copy-Item (Join-Path $PSScriptRoot '..\azure-files-dr.ps1') (Join-Path $testRoot 'scripts')
    Copy-Item (Join-Path $PSScriptRoot '..\files-dr-plan-guard.ps1') (Join-Path $testRoot 'scripts')
    $overlayPath = Join-Path $testRoot 'environments\lab\azure\99-runtime.auto.tfvars.json'
    $initial = '{"enable_files_dr_replica":true,"enable_files_dr_gateway":true,"other":"keep"}'
    [IO.File]::WriteAllText($overlayPath, $initial)
    $env:TF_VAR_notification_email = 'example@example.invalid'
    $env:TF_CLOUD_ORGANIZATION = 'AndesLog'
    function az { $global:LASTEXITCODE = 0; return '75b45f81-0930-4278-8fd9-896cec6eebe1' }
    function terraform {
        $global:LASTEXITCODE = 0
        switch ($args[0]) {
            'plan' {
                $out = @($args | Where-Object { $_ -like '-out=*' })[0].Substring(5)
                [IO.File]::WriteAllText($out, 'simulated plan')
            }
            'show' { return $global:mockPlan }
            'apply' {
                $planPath = $args[-1]
                if (-not (Test-Path -LiteralPath $planPath)) { throw 'No se usó el plan guardado.' }
                $global:mockAppliedPlan = $planPath
                $global:mockApplyCount++
                if ($global:mockApplyFails) { $global:LASTEXITCODE = 1 }
            }
            default { throw 'Comando Terraform inesperado.' }
        }
    }
    $global:mockPlan = '{"format_version":"1.2","complete":true,"resource_changes":[{"address":"azurerm_storage_account.files_dr[0]","mode":"managed","change":{"actions":["delete"]}}]}'
    $global:mockApplyFails = $false
    $blocked = $false
    try { & (Join-Path $testRoot 'scripts\azure-files-dr.ps1') -Action Deactivate -Execute } catch { $blocked = $true }
    if (-not $blocked -or $global:mockApplyCount -ne 0 -or [IO.File]::ReadAllText($overlayPath) -cne $initial) { throw 'El plan peligroso no se detuvo o el overlay no se restauró.' }
    $global:mockPlan = '{"format_version":"1.2","complete":true,"resource_changes":[{"address":"azurerm_subnet.files_dr_gateway[0]","mode":"managed","change":{"actions":["delete"]}}]}'
    & (Join-Path $testRoot 'scripts\azure-files-dr.ps1') -Action Deactivate -Execute
    $overlay = Get-Content -LiteralPath $overlayPath -Raw | ConvertFrom-Json
    if ($global:mockApplyCount -ne 1 -or $overlay.enable_files_dr_gateway -ne $false -or $overlay.other -ne 'keep' -or (Test-Path -LiteralPath $global:mockAppliedPlan)) {
        throw 'El plan aceptado, el overlay o la limpieza no fueron correctos.'
    }
    [IO.File]::WriteAllText($overlayPath, $initial)
    $global:mockApplyFails = $true
    $failed = $false
    try { & (Join-Path $testRoot 'scripts\azure-files-dr.ps1') -Action Deactivate -Execute } catch { $failed = $true }
    $overlay = Get-Content -LiteralPath $overlayPath -Raw | ConvertFrom-Json
    if (-not $failed -or $global:mockApplyCount -ne 2 -or $overlay.enable_files_dr_gateway -ne $false -or (Test-Path -LiteralPath $global:mockAppliedPlan)) {
        throw 'Un apply parcial debe dejar el overlay previsto y limpiar el plan.'
    }
    Write-Host 'OK: el script bloquea cambios ajenos, recupera el overlay y aplica solo el plan validado.'
} finally {
    $env:TF_VAR_notification_email = $savedEmail
    $env:TF_CLOUD_ORGANIZATION = $savedOrg
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
    Remove-Item function:terraform, function:az -ErrorAction SilentlyContinue
    Remove-Variable mockPlan, mockApplyCount, mockAppliedPlan, mockApplyFails -Scope Global -ErrorAction SilentlyContinue
}
