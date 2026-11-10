#requires -Version 5.1
$ErrorActionPreference = 'Stop'
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot '..\lab.ps1'), [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw 'No se pudo analizar lab.ps1.' }
$definition = $ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'TestErpAzureFlow' }, $true)
if (@($definition).Count -ne 1) { throw 'No se encontró la prueba intercloud.' }
Invoke-Expression $definition[0].Extent.Text
$script:erpIntegrationRequested = $true
$global:eventId = '7b709a48-2c59-422c-8698-6168ec326be1'
$global:statuses = @(); $global:attempt = 0; $global:calls = 0
function Say([string]$Message) {}
function Start-Sleep { }
function Remote([string]$HostName, [string]$Command) {
    if (-not $Command.Contains("--event-id $global:eventId")) { throw 'La prueba debe procesar solo el evento sintético.' }
    $global:calls++
}
function RemoteOutput([string]$HostName, [string]$Command) {
    if ($Command -match 'outbox-smoke') { return $global:eventId }
    if ($Command -match 'outbox-status') {
        $index = [Math]::Min($global:attempt, $global:statuses.Count - 1)
        $global:attempt++
        return $global:statuses[$index]
    }
    throw 'Salida remota inesperada.'
}
try {
    $global:statuses = @('pending', 'pending', 'delivered'); $global:attempt = 0; $global:calls = 0
    TestErpAzureFlow 'demo:v1'
    if ($global:calls -ne 3) { throw 'No se reintentó el evento pendiente.' }
    $global:statuses = @('dead'); $global:attempt = 0; $global:calls = 0; $failed = $false
    try { TestErpAzureFlow 'demo:v1' } catch { $failed = $true }
    if (-not $failed -or $global:calls -ne 1) { throw 'Un error permanente debe detener el proceso.' }
    $global:statuses = @('pending'); $global:attempt = 0; $global:calls = 0; $failed = $false
    try { TestErpAzureFlow 'demo:v1' } catch { $failed = $true }
    if (-not $failed -or $global:calls -ne 36) { throw 'El reintento debe tener un límite.' }
    Write-Host 'OK: la prueba intercloud reintenta solo el evento indicado y se detiene en fallo permanente o por límite.'
} finally {
    Remove-Item function:Start-Sleep -ErrorAction SilentlyContinue
    Remove-Variable eventId, statuses, attempt, calls -Scope Global -ErrorAction SilentlyContinue
}
