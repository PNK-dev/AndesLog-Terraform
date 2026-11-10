# Experimental regional ingest. This provisions infrastructure only; it is
# not ready until the package, ERP fallback, reconciliation, and tests exist.
locals {
  erp_failover_ingest_enabled = local.erp_event_archive_dr_enabled && var.enable_erp_failover_ingest
  erp_dr_hash                 = substr(sha256("${var.subscription_id}-${var.erp_failover_ingest_location}"), 0, 10)
  erp_dr_function_name        = "${substr(replace(lower(local.prefix), "-", ""), 0, 10)}-dr-${local.erp_dr_hash}"
  erp_dr_host_name            = "${substr(replace(lower(var.project), "-", ""), 0, 8)}dh${local.erp_dr_hash}"
}

resource "random_password" "erp_ingest_dr" {
  count   = local.erp_failover_ingest_enabled ? 1 : 0
  length  = 48
  special = false
}

resource "azurerm_virtual_network" "erp_ingest_dr" {
  count               = local.erp_failover_ingest_enabled ? 1 : 0
  name                = "${local.prefix}-erp-dr-ingest-vnet"
  resource_group_name = azurerm_resource_group.main.name
  location            = var.erp_failover_ingest_location
  address_space       = ["10.50.0.0/16"]
  tags                = merge(local.common_tags, { Purpose = "erp-regional-ingress" })
}

resource "azurerm_subnet" "erp_ingest_dr_function" {
  count                = local.erp_failover_ingest_enabled ? 1 : 0
  name                 = "snet-function"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.erp_ingest_dr[0].name
  address_prefixes     = ["10.50.0.0/27"]
  delegation {
    name = "flex-consumption"
    service_delegation {
      name    = "Microsoft.App/environments"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

resource "azurerm_subnet" "erp_ingest_dr_endpoints" {
  count                             = local.erp_failover_ingest_enabled ? 1 : 0
  name                              = "snet-private-endpoints"
  resource_group_name               = azurerm_resource_group.main.name
  virtual_network_name              = azurerm_virtual_network.erp_ingest_dr[0].name
  address_prefixes                  = ["10.50.1.0/27"]
  private_endpoint_network_policies = "Disabled"
}

resource "azurerm_resource_group" "erp_ingest_dr_dns" {
  count    = local.erp_failover_ingest_enabled ? 1 : 0
  name     = "${local.prefix}-erp-dr-dns-rg"
  location = var.erp_failover_ingest_location
  tags     = merge(local.common_tags, { Purpose = "erp-regional-ingress-dns" })
}

# A distinct zone avoids publishing two unreachable endpoint IPs to either VNet.
resource "azurerm_private_dns_zone" "erp_ingest_dr" {
  count               = local.erp_failover_ingest_enabled ? 1 : 0
  name                = "privatelink.blob.core.windows.net"
  resource_group_name = azurerm_resource_group.erp_ingest_dr_dns[0].name
  tags                = merge(local.common_tags, { Purpose = "erp-regional-ingress-dns" })
}

resource "azurerm_private_dns_zone_virtual_network_link" "erp_ingest_dr" {
  count                = local.erp_failover_ingest_enabled ? 1 : 0
  name                 = "${local.prefix}-erp-dr-ingest-link"
  private_dns_zone_id  = azurerm_private_dns_zone.erp_ingest_dr[0].id
  virtual_network_id   = azurerm_virtual_network.erp_ingest_dr[0].id
  registration_enabled = false
  tags                 = merge(local.common_tags, { Purpose = "erp-regional-ingress-dns" })
}

resource "azurerm_private_endpoint" "erp_ingest_dr_blob" {
  count               = local.erp_failover_ingest_enabled ? 1 : 0
  name                = "${local.prefix}-erp-dr-ingest-pe"
  resource_group_name = azurerm_resource_group.main.name
  location            = var.erp_failover_ingest_location
  subnet_id           = azurerm_subnet.erp_ingest_dr_endpoints[0].id
  private_service_connection {
    name                           = "${local.prefix}-erp-dr-ingest-blob"
    private_connection_resource_id = azurerm_storage_account.erp_archive_dr[0].id
    subresource_names              = ["blob"]
    is_manual_connection           = false
  }
  private_dns_zone_group {
    name                 = "default"
    private_dns_zone_ids = [azurerm_private_dns_zone.erp_ingest_dr[0].id]
  }
  tags = merge(local.common_tags, { Purpose = "erp-regional-ingress-private" })
}

resource "azurerm_storage_container" "erp_failover_intake" {
  count                 = local.erp_failover_ingest_enabled ? 1 : 0
  name                  = "erp-events-failover"
  storage_account_id    = azurerm_storage_account.erp_archive_dr[0].id
  container_access_type = "private"
}

resource "azurerm_storage_account" "erp_ingest_dr_host" {
  count                           = local.erp_failover_ingest_enabled ? 1 : 0
  name                            = local.erp_dr_host_name
  resource_group_name             = azurerm_resource_group.main.name
  location                        = var.erp_failover_ingest_location
  account_kind                    = "StorageV2"
  account_tier                    = "Standard"
  account_replication_type        = "ZRS"
  min_tls_version                 = "TLS1_2"
  https_traffic_only_enabled      = true
  allow_nested_items_to_be_public = false
  tags                            = merge(local.common_tags, { Purpose = "erp-regional-ingress-host" })
}

resource "azurerm_storage_container" "erp_ingest_dr_deploy" {
  count                 = local.erp_failover_ingest_enabled ? 1 : 0
  name                  = "erp-function-code"
  storage_account_id    = azurerm_storage_account.erp_ingest_dr_host[0].id
  container_access_type = "private"
}

resource "azurerm_user_assigned_identity" "erp_ingest_dr" {
  count               = local.erp_failover_ingest_enabled ? 1 : 0
  name                = "${local.prefix}-erp-dr-ingest-id"
  resource_group_name = azurerm_resource_group.main.name
  location            = var.erp_failover_ingest_location
  tags                = merge(local.common_tags, { Purpose = "erp-regional-ingress" })
}

resource "azurerm_role_assignment" "erp_ingest_dr_events" {
  count                = local.erp_failover_ingest_enabled ? 1 : 0
  scope                = "${azurerm_storage_account.erp_archive_dr[0].id}/blobServices/default/containers/${azurerm_storage_container.erp_failover_intake[0].name}"
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_user_assigned_identity.erp_ingest_dr[0].principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_log_analytics_workspace" "erp_ingest_dr" {
  count                          = local.erp_failover_ingest_enabled ? 1 : 0
  name                           = "${local.prefix}-erp-dr-${local.erp_dr_hash}-logs"
  resource_group_name            = azurerm_resource_group.main.name
  location                       = var.erp_failover_ingest_location
  sku                            = "PerGB2018"
  retention_in_days              = 30
  daily_quota_gb                 = 0.1
  local_authentication_enabled   = false
  internet_ingestion_access_type = "Enabled"
  internet_query_access_type     = "Enabled"
  tags                           = merge(local.common_tags, { Purpose = "erp-regional-ingress-monitoring" })
}

resource "azurerm_application_insights" "erp_ingest_dr" {
  count                                = local.erp_failover_ingest_enabled ? 1 : 0
  name                                 = "${local.prefix}-erp-dr-${local.erp_dr_hash}-insights"
  resource_group_name                  = azurerm_resource_group.main.name
  location                             = var.erp_failover_ingest_location
  application_type                     = "web"
  workspace_id                         = azurerm_log_analytics_workspace.erp_ingest_dr[0].id
  retention_in_days                    = 30
  sampling_percentage                  = 100
  daily_data_cap_in_gb                 = 0.1
  daily_data_cap_notifications_enabled = true
  local_authentication_enabled         = false
  tags                                 = merge(local.common_tags, { Purpose = "erp-regional-ingress-monitoring" })
}

resource "azurerm_role_assignment" "erp_ingest_dr_monitoring" {
  count                = local.erp_failover_ingest_enabled ? 1 : 0
  scope                = azurerm_application_insights.erp_ingest_dr[0].id
  role_definition_name = "Monitoring Metrics Publisher"
  principal_id         = azurerm_user_assigned_identity.erp_ingest_dr[0].principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_service_plan" "erp_ingest_dr" {
  count                  = local.erp_failover_ingest_enabled ? 1 : 0
  name                   = "${local.prefix}-erp-dr-ingest-plan"
  resource_group_name    = azurerm_resource_group.main.name
  location               = var.erp_failover_ingest_location
  os_type                = "Linux"
  sku_name               = "FC1"
  zone_balancing_enabled = true
  tags                   = merge(local.common_tags, { Purpose = "erp-regional-ingress" })
}

resource "azurerm_function_app_flex_consumption" "erp_ingest_dr" {
  count                         = local.erp_failover_ingest_enabled ? 1 : 0
  name                          = local.erp_dr_function_name
  resource_group_name           = azurerm_resource_group.main.name
  location                      = var.erp_failover_ingest_location
  service_plan_id               = azurerm_service_plan.erp_ingest_dr[0].id
  storage_container_type        = "blobContainer"
  storage_container_endpoint    = "${azurerm_storage_account.erp_ingest_dr_host[0].primary_blob_endpoint}${azurerm_storage_container.erp_ingest_dr_deploy[0].name}"
  storage_authentication_type   = "StorageAccountConnectionString"
  storage_access_key            = azurerm_storage_account.erp_ingest_dr_host[0].primary_access_key
  runtime_name                  = "python"
  runtime_version               = "3.12"
  instance_memory_in_mb         = 512
  maximum_instance_count        = 3
  https_only                    = true
  public_network_access_enabled = true
  virtual_network_subnet_id     = azurerm_subnet.erp_ingest_dr_function[0].id
  always_ready {
    name           = "http"
    instance_count = 2
  }
  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.erp_ingest_dr[0].id]
  }
  app_settings = {
    ERP_EVENTS_ACCOUNT_NAME                   = azurerm_storage_account.erp_archive_dr[0].name
    ERP_EVENTS_CONTAINER                      = azurerm_storage_container.erp_failover_intake[0].name
    ERP_INGEST_HMAC_SECRET                    = random_password.erp_ingest_dr[0].result
    AZURE_CLIENT_ID                           = azurerm_user_assigned_identity.erp_ingest_dr[0].client_id
    APPLICATIONINSIGHTS_AUTHENTICATION_STRING = "Authorization=AAD;ClientId=${azurerm_user_assigned_identity.erp_ingest_dr[0].client_id}"
    FILES_DR_SYNC_ENABLED                     = "false"
    FILES_DR_SYNC_CRON                        = "0 0 0 1 1 *"
  }
  site_config {
    application_insights_connection_string = azurerm_application_insights.erp_ingest_dr[0].connection_string
    vnet_route_all_enabled                 = false
  }
  tags = merge(local.common_tags, { Purpose = "erp-regional-ingress" })
  depends_on = [
    azurerm_private_dns_zone_virtual_network_link.erp_ingest_dr,
    azurerm_private_endpoint.erp_ingest_dr_blob,
    azurerm_role_assignment.erp_ingest_dr_events,
    azurerm_role_assignment.erp_ingest_dr_monitoring,
  ]
}

resource "azurerm_monitor_metric_alert" "erp_ingest_dr_failures" {
  count               = local.erp_failover_ingest_enabled && var.notification_email != "" ? 1 : 0
  name                = "${local.prefix}-erp-dr-ingest-failed-requests"
  resource_group_name = azurerm_resource_group.main.name
  scopes              = [azurerm_application_insights.erp_ingest_dr[0].id]
  description         = "Failed requests observed by the experimental regional ERP ingress."
  severity            = 1
  frequency           = "PT1M"
  window_size         = "PT5M"
  enabled             = true
  auto_mitigate       = true
  criteria {
    metric_namespace = "microsoft.insights/components"
    metric_name      = "requests/failed"
    aggregation      = "Count"
    operator         = "GreaterThan"
    threshold        = 0
  }
  action {
    action_group_id = azurerm_monitor_action_group.email[0].id
  }
  tags = merge(local.common_tags, { Purpose = "erp-regional-ingress-alert" })
}

output "erp_failover_ingest_enabled" {
  description = "Indica si la Function regional de ingesta experimental está configurada."
  value       = local.erp_failover_ingest_enabled
}

output "erp_failover_ingest_function_name" {
  description = "Nombre de la Function regional experimental."
  value       = try(azurerm_function_app_flex_consumption.erp_ingest_dr[0].name, "")
}

output "erp_failover_ingest_url" {
  description = "Endpoint HTTPS de la Function regional experimental; requiere publicar y probar el paquete."
  value       = try("https://${azurerm_function_app_flex_consumption.erp_ingest_dr[0].default_hostname}/api/erp/events", "")
}

output "erp_failover_ingest_hmac_secret" {
  description = "Clave HMAC de la Function regional experimental; debe mantenerse privada."
  value       = try(random_password.erp_ingest_dr[0].result, "")
  sensitive   = true
}
