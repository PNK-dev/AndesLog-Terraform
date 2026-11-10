mock_provider "azurerm" {}
mock_provider "random" {}

variables {
  subscription_id              = "00000000-0000-0000-0000-000000000001"
  enable_remote_access         = true
  create_files_storage_account = true
  enable_files_dr_replica      = true
  enable_erp_integration       = false
}

run "primary_gateway_transit_without_regional_gateway" {
  command = plan
  variables { enable_files_dr_gateway = false }

  assert {
    condition     = length(azurerm_virtual_network_gateway.files_dr) == 0 && azurerm_virtual_network_peering.files_dr_to_primary[0].use_remote_gateways
    error_message = "Sin gateway regional, el peering debe usar el gateway primario."
  }
}

run "regional_gateway_uses_local_gateway" {
  command = plan
  variables { enable_files_dr_gateway = true }

  assert {
    condition     = length(azurerm_virtual_network_gateway.files_dr) == 1 && azurerm_virtual_network_gateway.files_dr[0].active_active && !azurerm_virtual_network_peering.files_dr_to_primary[0].use_remote_gateways
    error_message = "El gateway regional debe ser activo-activo y el peering no debe usar el gateway remoto."
  }
}
