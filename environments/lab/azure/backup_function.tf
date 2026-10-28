locals {
  backup_function_name = "${local.prefix}-audit-${substr(sha256(var.subscription_id), 0, 8)}"
  function_host_name   = "${substr(replace(lower(var.project), "-", ""), 0, 11)}fn${substr(sha256(var.subscription_id), 0, 11)}"
}

# The Functions host needs its own storage. The backup account deliberately has
# shared keys disabled; the function accesses it only through managed identity.
resource "azurerm_storage_account" "function_host" {
  count                           = var.enable_backup_audit ? 1 : 0
  name                            = local.function_host_name
  resource_group_name             = azurerm_resource_group.main.name
  location                        = azurerm_resource_group.main.location
  account_kind                    = "StorageV2"
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  min_tls_version                 = "TLS1_2"
  https_traffic_only_enabled      = true
  allow_nested_items_to_be_public = false
  tags                            = merge(local.common_tags, { Purpose = "function-host" })
}

resource "azurerm_user_assigned_identity" "backup_audit" {
  count               = var.enable_backup_audit ? 1 : 0
  name                = "${local.prefix}-audit-id"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  tags                = merge(local.common_tags, { Purpose = "backup-audit" })
}

resource "azurerm_role_assignment" "backup_audit_blob" {
  count                = var.enable_backup_audit ? 1 : 0
  scope                = azurerm_storage_account.backups.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_user_assigned_identity.backup_audit[0].principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_storage_container" "backup_audit" {
  count                 = var.enable_backup_audit ? 1 : 0
  name                  = "backup-audit"
  storage_account_id    = azurerm_storage_account.backups.id
  container_access_type = "private"
  depends_on            = [azurerm_role_assignment.blob_data_contributor]
}

resource "azurerm_service_plan" "backup_audit" {
  count               = var.enable_backup_audit ? 1 : 0
  name                = "${local.prefix}-audit-plan"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  os_type             = "Linux"
  sku_name            = "Y1"
  tags                = merge(local.common_tags, { Purpose = "backup-audit" })
}

resource "azurerm_linux_function_app" "backup_audit" {
  count                       = var.enable_backup_audit ? 1 : 0
  name                        = local.backup_function_name
  resource_group_name         = azurerm_resource_group.main.name
  location                    = azurerm_resource_group.main.location
  service_plan_id             = azurerm_service_plan.backup_audit[0].id
  storage_account_name        = azurerm_storage_account.function_host[0].name
  storage_account_access_key  = azurerm_storage_account.function_host[0].primary_access_key
  functions_extension_version = "~4"
  https_only                  = true

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.backup_audit[0].id]
  }

  app_settings = {
    FUNCTIONS_WORKER_RUNTIME       = "python"
    SCM_DO_BUILD_DURING_DEPLOYMENT = "true"
    ENABLE_ORYX_BUILD              = "true"
    BACKUP_ACCOUNT_NAME            = azurerm_storage_account.backups.name
    BACKUP_CONTAINER               = azurerm_storage_container.backups.name
    AUDIT_CONTAINER                = azurerm_storage_container.backup_audit[0].name
    MAX_BACKUP_BYTES               = tostring(var.backup_audit_max_bytes)
    AZURE_CLIENT_ID                = azurerm_user_assigned_identity.backup_audit[0].client_id
  }

  site_config {
    application_stack {
      python_version = "3.12"
    }
  }

  tags       = merge(local.common_tags, { Purpose = "backup-audit" })
  depends_on = [azurerm_role_assignment.backup_audit_blob]
}

# The function code must be published before this resource can be created.
# scripts/lab.ps1 performs that two-stage apply without editing tracked files.
resource "azurerm_eventgrid_event_subscription" "backup_audit" {
  count                = var.enable_backup_audit && var.enable_backup_event_subscription ? 1 : 0
  name                 = "${local.prefix}-backup-created"
  scope                = azurerm_storage_account.backups.id
  included_event_types = ["Microsoft.Storage.BlobCreated"]

  subject_filter {
    subject_begins_with = "/blobServices/default/containers/${azurerm_storage_container.backups.name}/blobs/backups/"
    case_sensitive      = true
  }

  azure_function_endpoint {
    function_id = "${azurerm_linux_function_app.backup_audit[0].id}/functions/BackupAudit"
  }
}
