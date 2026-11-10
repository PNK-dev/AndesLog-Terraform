#requires -Version 5.1
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\files-dr-plan-guard.ps1')

function Resource([string]$Address, [string[]]$Actions, $Before = $null, $After = $null) {
    return @{ address = $Address; mode = 'managed'; change = @{ actions = $Actions; before = $Before; after = $After; after_unknown = @{} } }
}
function Plan($Resources) { return (ConvertTo-Json -Depth 30 -Compress @{ format_version = '1.2'; complete = $true; errored = $false; resource_changes = @($Resources) }) }
function Blocked([string]$Json, [string]$Action) {
    try { Assert-AndeslogFilesDrPlan $Json $Action } catch {
        if ($_.Exception.Message -match 'plan incluye cambios inesperados') { return }
        throw
    }
    throw 'Se esperaba que el plan fuera rechazado.'
}

$create = Resource 'azurerm_subnet.files_dr_gateway[0]' @('create')
$delete = Resource 'azurerm_subnet.files_dr_gateway[0]' @('delete')
$vnet = Resource 'azurerm_virtual_network.files_dr[0]' @('update') @{ name = 'dr'; dns_servers = @() } @{ name = 'dr'; dns_servers = @('10.22.254.4') }
$peer = Resource 'azurerm_virtual_network_peering.files_dr_to_primary[0]' @('update') @{ name = 'peer'; use_remote_gateways = $true } @{ name = 'peer'; use_remote_gateways = $false }
Assert-AndeslogFilesDrPlan (Plan @($create, $vnet, $peer)) 'Activate'
Assert-AndeslogFilesDrPlan (Plan @($delete)) 'Deactivate'
Assert-AndeslogFilesDrPlan (Plan @((Resource 'azurerm_storage_account.files_dr[0]' @('no-op')))) 'Deactivate'
Assert-AndeslogFilesDrPlan (Plan @((Resource 'azurerm_virtual_network.files_dr[0]' @('update') @{ dns_servers = @('10.22.254.4') } @{ dns_servers = @() }))) 'Deactivate'
Assert-AndeslogFilesDrPlan (Plan @((Resource 'azurerm_virtual_network_peering.files_dr_to_primary[0]' @('update') @{ use_remote_gateways = $false } @{ use_remote_gateways = $true }))) 'Deactivate'
Blocked (Plan @($delete)) 'Activate'
Blocked (Plan @($create)) 'Deactivate'
Blocked (Plan @((Resource 'azurerm_storage_account.files_dr[0]' @('delete')))) 'Deactivate'
Blocked (Plan @((Resource 'azurerm_virtual_network_gateway.files_dr[0]' @('delete', 'create')))) 'Activate'
Blocked (Plan @((Resource 'azurerm_virtual_network.files_dr[0]' @('update') @{ name = 'dr'; dns_servers = @() } @{ name = 'wrong'; dns_servers = @('10.22.254.4') }))) 'Activate'
Blocked (Plan @((Resource 'azurerm_virtual_network.files_dr[0]' @('update') @{ dns_servers = @() } @{ dns_servers = @('192.0.2.1') }))) 'Activate'
Blocked (Plan @((Resource 'azurerm_virtual_network_peering.files_dr_to_primary[0]' @('update') @{ use_remote_gateways = $true } @{ use_remote_gateways = $true }))) 'Activate'
$unknown = Resource 'azurerm_virtual_network.files_dr[0]' @('update') @{ dns_servers = @() } @{ dns_servers = @('10.22.254.4') }; $unknown.change.after_unknown = @{ some_property = $true }
Blocked (Plan @($unknown)) 'Activate'
$import = Resource 'azurerm_subnet.files_dr_gateway[0]' @('create'); $import.change.importing = @{ id = 'example' }
Blocked (Plan @($import)) 'Activate'
$moved = Resource 'azurerm_subnet.files_dr_gateway[0]' @('create'); $moved.previous_address = 'old'
Blocked (Plan @($moved)) 'Activate'
Blocked '{"format_version":"1.2","complete":false,"resource_changes":[]}' 'Activate'
Blocked '{"format_version":"2.0","resource_changes":[]}' 'Activate'
Blocked '{"format_version":"1.2"}' 'Activate'
Blocked '{"bad":' 'Activate'
Write-Host 'OK: el plan de contingencia acepta únicamente cambios acotados del gateway regional.'
