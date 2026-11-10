locals {
  erp_ingest_monitoring_name = "${local.prefix}-erp-monitor-${substr(sha256(var.subscription_id), 0, 6)}"
}

resource "azurerm_log_analytics_workspace" "erp_ingest" {
  count               = var.enable_erp_integration ? 1 : 0
  name                = "${local.erp_ingest_monitoring_name}-logs"
  location            = var.backup_function_location
  resource_group_name = azurerm_resource_group.main.name
  sku                 = "PerGB2018"
  retention_in_days   = 30
  daily_quota_gb      = 0.1

  local_authentication_enabled   = false
  internet_ingestion_access_type = "Enabled"
  internet_query_access_type     = "Enabled"

  tags = merge(local.common_tags, { Purpose = "erp-function-monitoring" })
}

resource "azurerm_application_insights" "erp_ingest" {
  count               = var.enable_erp_integration ? 1 : 0
  name                = "${local.erp_ingest_monitoring_name}-appinsights"
  location            = var.backup_function_location
  resource_group_name = azurerm_resource_group.main.name
  application_type    = "web"
  workspace_id        = azurerm_log_analytics_workspace.erp_ingest[0].id

  retention_in_days                    = 30
  sampling_percentage                  = 100
  daily_data_cap_in_gb                 = 0.1
  daily_data_cap_notifications_enabled = true
  local_authentication_enabled         = false

  tags = merge(local.common_tags, { Purpose = "erp-function-monitoring" })
}

resource "azurerm_role_assignment" "erp_ingest_monitoring" {
  count                = var.enable_erp_integration ? 1 : 0
  scope                = azurerm_application_insights.erp_ingest[0].id
  role_definition_name = "Monitoring Metrics Publisher"
  principal_id         = azurerm_user_assigned_identity.erp_ingest[0].principal_id
  principal_type       = "ServicePrincipal"
  description          = "Permite a la identidad de la Function enviar telemetría a Application Insights con Microsoft Entra ID."
}

resource "azurerm_monitor_metric_alert" "erp_ingest_failures" {
  count               = var.enable_erp_integration && var.notification_email != "" ? 1 : 0
  name                = "${local.erp_ingest_monitoring_name}-failed-requests"
  resource_group_name = azurerm_resource_group.main.name
  scopes              = [azurerm_application_insights.erp_ingest[0].id]
  description         = "Notifies when Application Insights records a failed HTTP request from the Azure ERP ingest Function."
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

  tags = merge(local.common_tags, { Purpose = "erp-function-monitoring" })
}
