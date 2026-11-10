locals {
  files_dr_sync_enabled       = local.files_dr_enabled && var.enable_erp_integration
  files_dr_checkpoint_enabled = local.files_dr_sync_enabled && var.enable_files_dr_checkpoint
}

resource "azurerm_storage_container" "files_dr_checkpoint" {
  count                 = local.files_dr_checkpoint_enabled ? 1 : 0
  name                  = "files-dr-checkpoints"
  storage_account_id    = azurerm_storage_account.erp_events[0].id
  container_access_type = "private"
}

resource "azurerm_role_assignment" "files_dr_checkpoint" {
  count                = local.files_dr_checkpoint_enabled ? 1 : 0
  scope                = "${azurerm_storage_account.erp_events[0].id}/blobServices/default/containers/${azurerm_storage_container.files_dr_checkpoint[0].name}"
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_user_assigned_identity.files_dr_sync[0].principal_id
  principal_type       = "ServicePrincipal"
  description          = "Write access restricted to the Files DR checkpoint container."
}

resource "azurerm_user_assigned_identity" "files_dr_sync" {
  count               = local.files_dr_sync_enabled ? 1 : 0
  name                = "${local.prefix}-files-dr-sync-id"
  resource_group_name = azurerm_resource_group.main.name
  location            = var.backup_function_location

  tags = merge(local.common_tags, { Purpose = "azure-files-regional-sync" })
}

# Azure Files OAuth over REST requires these built-in privileged roles. The
# assignments are restricted to the two shares; the source is read-only.
resource "azurerm_role_assignment" "files_dr_sync_primary" {
  count                = local.files_dr_sync_enabled ? 1 : 0
  scope                = "${local.files_account_id}/fileServices/default/fileshares/${var.existing_files_share_name}"
  role_definition_name = "Storage File Data Privileged Reader"
  principal_id         = azurerm_user_assigned_identity.files_dr_sync[0].principal_id
  principal_type       = "ServicePrincipal"
  description          = "Read-only OAuth access for the scheduled Azure Files DR mirror."
}

resource "azurerm_role_assignment" "files_dr_sync_secondary" {
  count                = local.files_dr_sync_enabled ? 1 : 0
  scope                = "${azurerm_storage_account.files_dr[0].id}/fileServices/default/fileshares/${var.existing_files_share_name}"
  role_definition_name = "Storage File Data Privileged Contributor"
  principal_id         = azurerm_user_assigned_identity.files_dr_sync[0].principal_id
  principal_type       = "ServicePrincipal"
  description          = "Write OAuth access for the scheduled Azure Files DR mirror."

  depends_on = [azurerm_storage_share.files_dr]
}

resource "azurerm_monitor_metric_alert" "erp_ingest_exceptions" {
  count               = var.enable_erp_integration && var.notification_email != "" ? 1 : 0
  name                = "${local.erp_ingest_monitoring_name}-function-exceptions"
  resource_group_name = azurerm_resource_group.main.name
  scopes              = [azurerm_application_insights.erp_ingest[0].id]
  description         = "Notifies when an Azure Function execution raises an unhandled exception, including the Azure Files DR timer."
  severity            = 1
  frequency           = "PT5M"
  window_size         = "PT5M"
  enabled             = true

  criteria {
    metric_namespace = "microsoft.insights/components"
    metric_name      = "exceptions/count"
    aggregation      = "Count"
    operator         = "GreaterThan"
    threshold        = 0
  }

  action {
    action_group_id = azurerm_monitor_action_group.email[0].id
  }

  tags = merge(local.common_tags, { Purpose = "function-exception-monitoring" })
}

resource "azurerm_monitor_scheduled_query_rules_alert_v2" "files_dr_sync_stale" {
  count                     = local.files_dr_sync_enabled && var.notification_email != "" ? 1 : 0
  name                      = "${local.erp_ingest_monitoring_name}-files-dr-sync-stale"
  display_name              = "AndesLog Azure Files DR sync stale"
  resource_group_name       = azurerm_resource_group.main.name
  location                  = var.backup_function_location
  description               = "Alerts when no successful Chile-to-Mexico Files scan started within five minutes; ingestion may delay or falsely trigger alerts."
  enabled                   = true
  severity                  = 1
  evaluation_frequency      = "PT1M"
  window_duration           = "PT5M"
  query_time_range_override = "PT5M"
  scopes                    = [azurerm_log_analytics_workspace.erp_ingest[0].id]
  skip_query_validation     = true
  auto_mitigation_enabled   = true

  criteria {
    query = <<-KQL
      AppTraces
      | where TimeGenerated > ago(5m)
      | where Message startswith "FILES_DR_SYNC_SUCCESS"
      | extend ScanStarted = todatetime(extract(@"started_utc=([0-9TZ:.-]+)", 1, Message))
      | where isnotnull(ScanStarted) and ScanStarted between (ago(5m) .. now())
      | summarize SyncSuccessCount = count()
    KQL

    time_aggregation_method = "Average"
    metric_measure_column   = "SyncSuccessCount"
    operator                = "LessThan"
    threshold               = 1

    failing_periods {
      minimum_failing_periods_to_trigger_alert = 1
      number_of_evaluation_periods             = 1
    }
  }

  action {
    action_groups = [azurerm_monitor_action_group.email[0].id]
  }

  tags = merge(local.common_tags, { Purpose = "files-dr-sync-monitoring" })
}
