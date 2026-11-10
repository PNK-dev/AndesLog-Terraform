#requires -Version 5.1
Set-StrictMode -Version Latest

function Test-AndeslogPlanHasUnknown($Value) {
    if ($null -eq $Value) { return $false }
    if ($Value -is [bool]) { return $Value }
    if ($Value -is [array]) {
        foreach ($item in $Value) { if (Test-AndeslogPlanHasUnknown $item) { return $true } }
        return $false
    }
    if ($Value -is [pscustomobject]) {
        foreach ($property in $Value.PSObject.Properties) { if (Test-AndeslogPlanHasUnknown $property.Value) { return $true } }
        return $false
    }
    return $true
}

function Assert-AndeslogFilesDrPlan([string]$PlanJson, [string]$Action) {
    # The plan can contain secrets: never print its contents or parsing errors.
    $failure = 'El plan incluye cambios inesperados o no se pudo comprobar. Se detiene antes de aplicar; revisa la configuración Azure y genera un plan manual.'
    try {
        if ($Action -notin @('Activate', 'Deactivate')) { throw 'invalid' }
        $plan = ConvertFrom-Json -InputObject $PlanJson -ErrorAction Stop
        if ($null -eq $plan -or $plan.format_version -notmatch '^1\.' -or
            $null -eq $plan.PSObject.Properties['resource_changes']) { throw 'invalid' }
        if ($null -ne $plan.PSObject.Properties['complete'] -and $plan.complete -ne $true) { throw 'invalid' }
        if ($null -ne $plan.PSObject.Properties['errored'] -and $plan.errored -ne $false) { throw 'invalid' }
        $expectedAction = if ($Action -eq 'Activate') { 'create' } else { 'delete' }
        $resources = @(
            'azurerm_subnet.files_dr_gateway[0]',
            'azurerm_subnet.files_dr_dns_inbound[0]',
            'azurerm_private_dns_resolver.files_dr[0]',
            'azurerm_private_dns_resolver_inbound_endpoint.files_dr[0]',
            'azurerm_public_ip.files_dr_gateway["gateway-a"]',
            'azurerm_public_ip.files_dr_gateway["gateway-b"]',
            'azurerm_public_ip.files_dr_gateway["p2s"]',
            'azurerm_virtual_network_gateway.files_dr[0]'
        )
        foreach ($resource in @($plan.resource_changes)) {
            if ($null -eq $resource -or $null -eq $resource.change -or
                $null -eq $resource.address -or $null -eq $resource.change.actions) { throw 'invalid' }
            if ($null -ne $resource.PSObject.Properties['previous_address'] -or
                $null -ne $resource.change.PSObject.Properties['importing']) { throw 'invalid' }
            $actions = @($resource.change.actions)
            if ($actions.Count -eq 1 -and ($actions[0] -eq 'no-op' -or ($resource.mode -eq 'data' -and $actions[0] -eq 'read'))) { continue }
            if ($resource.mode -ne 'managed' -or $actions.Count -ne 1) { throw 'invalid' }
            if ($resource.address -cin $resources -and $actions[0] -ceq $expectedAction) { continue }
            $allowedAttribute = switch -CaseSensitive ($resource.address) {
                'azurerm_virtual_network.files_dr[0]' { 'dns_servers' }
                'azurerm_virtual_network_peering.files_dr_to_primary[0]' { 'use_remote_gateways' }
                default { '' }
            }
            if (-not $allowedAttribute -or $actions[0] -cne 'update') { throw 'invalid' }
            $before = $resource.change.before; $after = $resource.change.after
            if ($null -eq $before -or $null -eq $after) { throw 'invalid' }
            $keys = @($before.PSObject.Properties.Name) + @($after.PSObject.Properties.Name) | Sort-Object -Unique
            foreach ($key in $keys) {
                if ($key -ceq $allowedAttribute) { continue }
                $old = $before.PSObject.Properties[$key]; $new = $after.PSObject.Properties[$key]
                if ($null -eq $old -or $null -eq $new -or
                    (ConvertTo-Json -InputObject $old.Value -Depth 100 -Compress) -cne (ConvertTo-Json -InputObject $new.Value -Depth 100 -Compress)) { throw 'invalid' }
            }
            $unknown = $resource.change.PSObject.Properties['after_unknown']
            if ($null -ne $unknown -and (Test-AndeslogPlanHasUnknown $unknown.Value)) { throw 'invalid' }
            $property = $after.PSObject.Properties[$allowedAttribute]
            if ($null -eq $property) { throw 'invalid' }
            if ($allowedAttribute -eq 'dns_servers') {
                $servers = @($property.Value)
                if ($Action -eq 'Activate' -and ($servers.Count -ne 1 -or $servers[0] -cne '10.22.254.4')) { throw 'invalid' }
                if ($Action -eq 'Deactivate' -and $servers.Count -ne 0) { throw 'invalid' }
            } elseif ($property.Value -isnot [bool] -or $property.Value -ne ($Action -eq 'Deactivate')) { throw 'invalid' }
        }
    } catch { throw $failure }
}
