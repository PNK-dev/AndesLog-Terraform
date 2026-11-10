locals {
  files_account_name       = var.existing_files_storage_account_name != "" ? var.existing_files_storage_account_name : "${substr(replace(lower(var.project), "-", ""), 0, 11)}fs${substr(sha256(var.subscription_id), 0, 11)}"
  files_dr_enabled         = var.enable_remote_access && var.enable_files_dr_replica
  files_dr_gateway_enabled = local.files_dr_enabled && var.enable_files_dr_gateway
  files_dr_account_name    = "${substr(replace(lower(var.project), "-", ""), 0, 6)}dr${substr(sha256("${var.subscription_id}-${var.azure_files_dr_location}"), 0, 16)}"
  files_account_id = var.enable_remote_access ? (
    var.create_files_storage_account ? azurerm_storage_account.shared_files[0].id : azurerm_storage_account.shared_files_existing[0].id
  ) : ""
}

resource "azurerm_storage_account" "shared_files" {
  count                           = var.enable_remote_access && var.create_files_storage_account ? 1 : 0
  name                            = local.files_account_name
  resource_group_name             = azurerm_resource_group.main.name
  location                        = azurerm_resource_group.main.location
  account_kind                    = "StorageV2"
  account_tier                    = "Standard"
  account_replication_type        = "ZRS"
  min_tls_version                 = "TLS1_2"
  https_traffic_only_enabled      = true
  allow_nested_items_to_be_public = false
  public_network_access           = "Disabled"
  shared_access_key_enabled       = true
  tags                            = merge(local.common_tags, { Purpose = "corporate-files" })
}

# Keep the retained academic share, but move its account from LRS to ZRS so an
# Availability Zone failure does not remove its only local copy. The import
# block adopts the existing account into Terraform; Terraform Destroy explicitly
# removes it from state before deleting the rest of the lab.
resource "azurerm_storage_account" "shared_files_existing" {
  count                           = var.enable_remote_access && !var.create_files_storage_account ? 1 : 0
  name                            = local.files_account_name
  resource_group_name             = azurerm_resource_group.main.name
  location                        = azurerm_resource_group.main.location
  account_kind                    = "StorageV2"
  account_tier                    = "Standard"
  account_replication_type        = "ZRS"
  min_tls_version                 = "TLS1_2"
  https_traffic_only_enabled      = true
  allow_nested_items_to_be_public = false
  public_network_access           = "Disabled"
  shared_access_key_enabled       = true
  tags                            = merge(local.common_tags, { Purpose = "corporate-files" })

  lifecycle {
    prevent_destroy = true
  }
}

import {
  for_each = var.enable_remote_access && !var.create_files_storage_account ? { retained = true } : {}
  to       = azurerm_storage_account.shared_files_existing[0]
  id       = "/subscriptions/${var.subscription_id}/resourceGroups/${local.prefix}-rg/providers/Microsoft.Storage/storageAccounts/${local.files_account_name}"
}

resource "azurerm_storage_share" "corporate" {
  count              = var.enable_remote_access && var.create_files_storage_account ? 1 : 0
  name               = var.existing_files_share_name
  storage_account_id = azurerm_storage_account.shared_files[0].id
  quota              = var.azure_files_quota_gb
  enabled_protocol   = "SMB"
}

resource "azurerm_private_dns_zone" "files" {
  count               = var.enable_remote_access ? 1 : 0
  name                = "privatelink.file.core.windows.net"
  resource_group_name = azurerm_resource_group.main.name
  tags                = merge(local.common_tags, { Purpose = "corporate-files-dns" })
}

resource "azurerm_private_dns_zone_virtual_network_link" "files" {
  count                = var.enable_remote_access ? 1 : 0
  name                 = "${local.prefix}-files-link"
  private_dns_zone_id  = azurerm_private_dns_zone.files[0].id
  virtual_network_id   = azurerm_virtual_network.main.id
  registration_enabled = false
  tags                 = merge(local.common_tags, { Purpose = "corporate-files-dns" })
}

resource "azurerm_private_endpoint" "files" {
  count               = var.enable_remote_access ? 1 : 0
  name                = "${local.prefix}-files-pe"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  subnet_id           = azurerm_subnet.private.id

  private_service_connection {
    name                           = "${local.prefix}-files-connection"
    private_connection_resource_id = local.files_account_id
    subresource_names              = ["file"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "files-dns"
    private_dns_zone_ids = [azurerm_private_dns_zone.files[0].id]
  }

  tags = merge(local.common_tags, { Purpose = "corporate-files" })
}
