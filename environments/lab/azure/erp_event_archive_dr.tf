# Experimental archive only. Object replication is asynchronous; it does not
# provide an ingress endpoint, writable failover, reconciliation, or RPO proof.
locals {
  erp_event_archive_dr_enabled = var.enable_erp_integration && var.enable_erp_event_archive_replication
  erp_event_archive_dr_name    = "${substr(replace(lower(var.project), "-", ""), 0, 6)}edr${substr(sha256("${var.subscription_id}-${var.erp_event_archive_dr_location}"), 0, 15)}"
}

resource "azurerm_virtual_network" "erp_archive_dr" {
  count               = local.erp_event_archive_dr_enabled ? 1 : 0
  name                = "${local.prefix}-erp-archive-dr-vnet"
  resource_group_name = azurerm_resource_group.main.name
  location            = var.erp_event_archive_dr_location
  address_space       = ["10.40.0.0/16"]
  tags                = merge(local.common_tags, { Purpose = "erp-event-archive-dr" })
}

resource "azurerm_subnet" "erp_archive_dr_private" {
  count                             = local.erp_event_archive_dr_enabled ? 1 : 0
  name                              = "snet-erp-archive-private-endpoints"
  resource_group_name               = azurerm_resource_group.main.name
  virtual_network_name              = azurerm_virtual_network.erp_archive_dr[0].name
  address_prefixes                  = ["10.40.1.0/27"]
  private_endpoint_network_policies = "Disabled"
}

resource "azurerm_storage_account" "erp_archive_dr" {
  count                            = local.erp_event_archive_dr_enabled ? 1 : 0
  name                             = local.erp_event_archive_dr_name
  resource_group_name              = azurerm_resource_group.main.name
  location                         = var.erp_event_archive_dr_location
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
  cross_tenant_replication_enabled = false

  blob_properties {
    versioning_enabled = true
  }
  tags = merge(local.common_tags, { Purpose = "erp-event-archive-regional-copy" })
}

resource "azurerm_storage_container" "erp_archive_dr" {
  count                 = local.erp_event_archive_dr_enabled ? 1 : 0
  name                  = "erp-events-replica"
  storage_account_id    = azurerm_storage_account.erp_archive_dr[0].id
  container_access_type = "private"
}

resource "azurerm_private_dns_zone_virtual_network_link" "erp_archive_dr" {
  count                = local.erp_event_archive_dr_enabled ? 1 : 0
  name                 = "${local.prefix}-erp-archive-dr-link"
  private_dns_zone_id  = azurerm_private_dns_zone.erp_blob[0].id
  virtual_network_id   = azurerm_virtual_network.erp_archive_dr[0].id
  registration_enabled = false
  tags                 = merge(local.common_tags, { Purpose = "erp-event-archive-dr-dns" })
}

resource "azurerm_private_endpoint" "erp_archive_dr" {
  count               = local.erp_event_archive_dr_enabled ? 1 : 0
  name                = "${local.prefix}-erp-archive-dr-pe"
  resource_group_name = azurerm_resource_group.main.name
  location            = var.erp_event_archive_dr_location
  subnet_id           = azurerm_subnet.erp_archive_dr_private[0].id

  private_service_connection {
    name                           = "${local.prefix}-erp-archive-dr-blob"
    private_connection_resource_id = azurerm_storage_account.erp_archive_dr[0].id
    subresource_names              = ["blob"]
    is_manual_connection           = false
  }
  private_dns_zone_group {
    name                 = "default"
    private_dns_zone_ids = [azurerm_private_dns_zone.erp_blob[0].id]
  }
  tags = merge(local.common_tags, { Purpose = "erp-event-archive-dr-private-access" })
}

resource "azurerm_storage_object_replication" "erp_archive_dr" {
  count                          = local.erp_event_archive_dr_enabled ? 1 : 0
  source_storage_account_id      = azurerm_storage_account.erp_events[0].id
  destination_storage_account_id = azurerm_storage_account.erp_archive_dr[0].id
  metrics_enabled                = true

  rules {
    source_container_name      = azurerm_storage_container.erp_events[0].name
    destination_container_name = azurerm_storage_container.erp_archive_dr[0].name
    copy_blobs_created_after   = "Everything"
  }
}

resource "azurerm_monitor_metric_alert" "erp_archive_dr_pending" {
  count               = local.erp_event_archive_dr_enabled ? 1 : 0
  name                = "${local.prefix}-erp-archive-pending"
  resource_group_name = azurerm_resource_group.main.name
  scopes              = [azurerm_storage_object_replication.erp_archive_dr[0].source_object_replication_id]
  description         = "Detects observed pending replication operations; missing metrics and short delays may go undetected."
  severity            = 2
  frequency           = "PT1M"
  window_size         = "PT5M"
  enabled             = true
  auto_mitigate       = true

  criteria {
    metric_namespace = "Microsoft.Storage/storageAccounts/objectReplicationPolicies"
    metric_name      = "PendingOperationsForReplication"
    aggregation      = "Minimum"
    operator         = "GreaterThan"
    threshold        = 0
  }

  dynamic "action" {
    for_each = var.notification_email != "" ? [1] : []
    content {
      action_group_id = azurerm_monitor_action_group.email[0].id
    }
  }
  tags = merge(local.common_tags, { Purpose = "erp-event-archive-replication-alert" })
}

output "erp_event_archive_replication_enabled" {
  description = "Indica si Terraform configura la réplica regional experimental del archivo de eventos."
  value       = local.erp_event_archive_dr_enabled
}

output "erp_event_archive_dr_account_name" {
  description = "Cuenta secundaria de la copia experimental de eventos."
  value       = try(azurerm_storage_account.erp_archive_dr[0].name, "")
}
