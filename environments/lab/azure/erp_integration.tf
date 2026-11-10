locals {
  erp_ingest_function_name = "${substr(replace(lower(local.prefix), "-", ""), 0, 12)}-erp-${substr(sha256(var.subscription_id), 0, 8)}"
  erp_ingest_host_name     = "${substr(replace(lower(var.project), "-", ""), 0, 8)}h${substr(sha256(var.subscription_id), 0, 11)}"
  erp_event_store_name     = "${substr(replace(lower(var.project), "-", ""), 0, 8)}e${substr(sha256(var.subscription_id), 0, 11)}"
}

resource "azurerm_virtual_network" "erp_integration" {
  count               = var.enable_erp_integration ? 1 : 0
  name                = "${local.prefix}-erp-int-vnet"
  resource_group_name = azurerm_resource_group.main.name
  location            = var.backup_function_location
  address_space       = ["10.30.0.0/16"]
  tags                = merge(local.common_tags, { Purpose = "erp-private-integration" })
}

resource "azurerm_subnet" "erp_function_integration" {
  count                = var.enable_erp_integration ? 1 : 0
  name                 = "snet-erp-function"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.erp_integration[0].name
  address_prefixes     = ["10.30.0.0/27"]

  delegation {
    name = "flex-consumption"
    service_delegation {
      name    = "Microsoft.App/environments"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

resource "azurerm_subnet" "erp_private_endpoints" {
  count                = var.enable_erp_integration ? 1 : 0
  name                 = "snet-erp-private-endpoints"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.erp_integration[0].name
  address_prefixes     = ["10.30.1.0/27"]

  private_endpoint_network_policies = "Disabled"
}

resource "azurerm_virtual_network_peering" "erp_to_files_primary" {
  count                     = local.files_dr_sync_enabled ? 1 : 0
  name                      = "${local.prefix}-erp-to-files-primary"
  resource_group_name       = azurerm_resource_group.main.name
  virtual_network_name      = azurerm_virtual_network.erp_integration[0].name
  remote_virtual_network_id = azurerm_virtual_network.main.id

  allow_virtual_network_access = true
}

resource "azurerm_virtual_network_peering" "files_primary_to_erp" {
  count                     = local.files_dr_sync_enabled ? 1 : 0
  name                      = "${local.prefix}-files-primary-to-erp"
  resource_group_name       = azurerm_resource_group.main.name
  virtual_network_name      = azurerm_virtual_network.main.name
  remote_virtual_network_id = azurerm_virtual_network.erp_integration[0].id

  allow_virtual_network_access = true
}

resource "azurerm_virtual_network_peering" "erp_to_files_dr" {
  count                     = local.files_dr_sync_enabled ? 1 : 0
  name                      = "${local.prefix}-erp-to-files-dr"
  resource_group_name       = azurerm_resource_group.main.name
  virtual_network_name      = azurerm_virtual_network.erp_integration[0].name
  remote_virtual_network_id = azurerm_virtual_network.files_dr[0].id

  allow_virtual_network_access = true
}

resource "azurerm_virtual_network_peering" "files_dr_to_erp" {
  count                     = local.files_dr_sync_enabled ? 1 : 0
  name                      = "${local.prefix}-files-dr-to-erp"
  resource_group_name       = azurerm_resource_group.main.name
  virtual_network_name      = azurerm_virtual_network.files_dr[0].name
  remote_virtual_network_id = azurerm_virtual_network.erp_integration[0].id

  allow_virtual_network_access = true
}

resource "azurerm_private_dns_zone_virtual_network_link" "erp_files" {
  count                = local.files_dr_sync_enabled ? 1 : 0
  name                 = "${local.prefix}-erp-files-link"
  private_dns_zone_id  = azurerm_private_dns_zone.files[0].id
  virtual_network_id   = azurerm_virtual_network.erp_integration[0].id
  registration_enabled = false
  tags                 = merge(local.common_tags, { Purpose = "files-dr-sync-private-dns" })
}

resource "azurerm_private_dns_zone" "erp_blob" {
  count               = var.enable_erp_integration ? 1 : 0
  name                = "privatelink.blob.core.windows.net"
  resource_group_name = azurerm_resource_group.main.name
  tags                = merge(local.common_tags, { Purpose = "erp-private-integration-dns" })
}

resource "azurerm_private_dns_zone_virtual_network_link" "erp_blob" {
  count                = var.enable_erp_integration ? 1 : 0
  name                 = "${local.prefix}-erp-blob-link"
  private_dns_zone_id  = azurerm_private_dns_zone.erp_blob[0].id
  virtual_network_id   = azurerm_virtual_network.erp_integration[0].id
  registration_enabled = false
  tags                 = merge(local.common_tags, { Purpose = "erp-private-integration-dns" })
}

resource "random_password" "erp_ingest" {
  count   = var.enable_erp_integration ? 1 : 0
  length  = 48
  special = false
}

# Zone-redundant storage for the Flex Consumption deployment package.
# Shared keys are limited to this host account; business events use a separate
# account and managed identity.
resource "azurerm_storage_account" "erp_ingest_host" {
  count                           = var.enable_erp_integration ? 1 : 0
  name                            = local.erp_ingest_host_name
  resource_group_name             = azurerm_resource_group.main.name
  location                        = var.backup_function_location
  account_kind                    = "StorageV2"
  account_tier                    = "Standard"
  account_replication_type        = "ZRS"
  min_tls_version                 = "TLS1_2"
  https_traffic_only_enabled      = true
  allow_nested_items_to_be_public = false
  tags                            = merge(local.common_tags, { Purpose = "erp-function-host" })
}

resource "azurerm_storage_container" "erp_ingest_deploy" {
  count                 = var.enable_erp_integration ? 1 : 0
  name                  = "erp-function-code"
  storage_account_id    = azurerm_storage_account.erp_ingest_host[0].id
  container_access_type = "private"
}

# The event archive has its own account so the Function identity's data-plane
# role cannot read the separate database backup container.
resource "azurerm_storage_account" "erp_events" {
  count                            = var.enable_erp_integration ? 1 : 0
  name                             = local.erp_event_store_name
  resource_group_name              = azurerm_resource_group.main.name
  location                         = var.backup_function_location
  account_kind                     = "StorageV2"
  account_tier                     = "Standard"
  account_replication_type         = "ZRS"
  min_tls_version                  = "TLS1_2"
  https_traffic_only_enabled       = true
  allow_nested_items_to_be_public  = false
  public_network_access            = "Disabled"
  shared_access_key_enabled        = false
  default_to_oauth_authentication  = true
  local_user_enabled               = false
  cross_tenant_replication_enabled = var.enable_erp_event_archive_replication ? false : null

  blob_properties {
    versioning_enabled  = var.enable_erp_event_archive_replication
    change_feed_enabled = var.enable_erp_event_archive_replication
  }
  tags = merge(local.common_tags, { Purpose = "erp-event-archive" })
}

resource "azurerm_storage_container" "erp_events" {
  count                 = var.enable_erp_integration ? 1 : 0
  name                  = "erp-events"
  storage_account_id    = azurerm_storage_account.erp_events[0].id
  container_access_type = "private"
}

resource "azurerm_private_endpoint" "erp_events_blob" {
  count               = var.enable_erp_integration ? 1 : 0
  name                = "${local.prefix}-erp-events-pe"
  resource_group_name = azurerm_resource_group.main.name
  location            = var.backup_function_location
  subnet_id           = azurerm_subnet.erp_private_endpoints[0].id
  tags                = merge(local.common_tags, { Purpose = "erp-event-archive" })

  private_service_connection {
    name                           = "${local.prefix}-erp-events-blob"
    private_connection_resource_id = azurerm_storage_account.erp_events[0].id
    subresource_names              = ["blob"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "default"
    private_dns_zone_ids = [azurerm_private_dns_zone.erp_blob[0].id]
  }
}

resource "azurerm_user_assigned_identity" "erp_ingest" {
  count               = var.enable_erp_integration ? 1 : 0
  name                = "${local.prefix}-erp-ingest-id"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  tags                = merge(local.common_tags, { Purpose = "erp-event-ingest" })
}

resource "azurerm_role_assignment" "erp_ingest_events" {
  count                = var.enable_erp_integration ? 1 : 0
  scope                = "${azurerm_storage_account.erp_events[0].id}/blobServices/default/containers/${azurerm_storage_container.erp_events[0].name}"
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_user_assigned_identity.erp_ingest[0].principal_id
  principal_type       = "ServicePrincipal"

  lifecycle {
    create_before_destroy = true
  }
}

resource "azurerm_service_plan" "erp_ingest" {
  count                  = var.enable_erp_integration ? 1 : 0
  name                   = "${local.prefix}-erp-ingest-plan"
  resource_group_name    = azurerm_resource_group.main.name
  location               = var.backup_function_location
  os_type                = "Linux"
  sku_name               = "FC1"
  zone_balancing_enabled = true
  tags                   = merge(local.common_tags, { Purpose = "erp-event-ingest" })
}

resource "azurerm_function_app_flex_consumption" "erp_ingest" {
  count                         = var.enable_erp_integration ? 1 : 0
  name                          = local.erp_ingest_function_name
  resource_group_name           = azurerm_resource_group.main.name
  location                      = var.backup_function_location
  service_plan_id               = azurerm_service_plan.erp_ingest[0].id
  storage_container_type        = "blobContainer"
  storage_container_endpoint    = "${azurerm_storage_account.erp_ingest_host[0].primary_blob_endpoint}${azurerm_storage_container.erp_ingest_deploy[0].name}"
  storage_authentication_type   = "StorageAccountConnectionString"
  storage_access_key            = azurerm_storage_account.erp_ingest_host[0].primary_access_key
  runtime_name                  = "python"
  runtime_version               = "3.12"
  instance_memory_in_mb         = 512
  maximum_instance_count        = 3
  https_only                    = true
  public_network_access_enabled = true
  virtual_network_subnet_id     = azurerm_subnet.erp_function_integration[0].id

  always_ready {
    name           = "http"
    instance_count = 2
  }

  identity {
    type = "UserAssigned"
    identity_ids = local.files_dr_sync_enabled ? [
      azurerm_user_assigned_identity.erp_ingest[0].id,
      azurerm_user_assigned_identity.files_dr_sync[0].id,
    ] : [azurerm_user_assigned_identity.erp_ingest[0].id]
  }

  app_settings = {
    ERP_EVENTS_ACCOUNT_NAME                   = azurerm_storage_account.erp_events[0].name
    ERP_EVENTS_CONTAINER                      = azurerm_storage_container.erp_events[0].name
    ERP_INGEST_HMAC_SECRET                    = random_password.erp_ingest[0].result
    AZURE_CLIENT_ID                           = azurerm_user_assigned_identity.erp_ingest[0].client_id
    APPLICATIONINSIGHTS_AUTHENTICATION_STRING = "Authorization=AAD;ClientId=${azurerm_user_assigned_identity.erp_ingest[0].client_id}"
    FILES_DR_SYNC_ENABLED                     = local.files_dr_sync_enabled ? "true" : "false"
    FILES_DR_SYNC_CRON                        = local.files_dr_sync_enabled ? "0 * * * * *" : "0 0 0 1 1 *"
    FILES_DR_PRIMARY_ACCOUNT                  = local.files_dr_sync_enabled ? local.files_account_name : ""
    FILES_DR_SECONDARY_ACCOUNT                = local.files_dr_sync_enabled ? local.files_dr_account_name : ""
    FILES_DR_SHARE_NAME                       = var.existing_files_share_name
    FILES_DR_SYNC_IDENTITY_CLIENT_ID          = local.files_dr_sync_enabled ? azurerm_user_assigned_identity.files_dr_sync[0].client_id : ""
    FILES_DR_CHECKPOINT_ENABLED               = local.files_dr_checkpoint_enabled ? "true" : "false"
    FILES_DR_CHECKPOINT_ACCOUNT               = local.files_dr_checkpoint_enabled ? azurerm_storage_account.erp_events[0].name : ""
    FILES_DR_CHECKPOINT_CONTAINER             = local.files_dr_checkpoint_enabled ? azurerm_storage_container.files_dr_checkpoint[0].name : ""
  }

  site_config {
    application_insights_connection_string = azurerm_application_insights.erp_ingest[0].connection_string
    vnet_route_all_enabled                 = false
  }

  tags = merge(local.common_tags, { Purpose = "erp-event-ingest" })
  depends_on = [
    azurerm_private_dns_zone_virtual_network_link.erp_blob,
    azurerm_role_assignment.erp_ingest_events,
    azurerm_role_assignment.erp_ingest_monitoring,
    azurerm_virtual_network_peering.erp_to_files_primary,
    azurerm_virtual_network_peering.erp_to_files_dr,
    azurerm_private_dns_zone_virtual_network_link.erp_files,
    azurerm_role_assignment.files_dr_sync_primary,
    azurerm_role_assignment.files_dr_sync_secondary,
    azurerm_role_assignment.files_dr_checkpoint,
  ]
}
