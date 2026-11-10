mock_provider "azurerm" {}
mock_provider "random" {}

variables {
  subscription_id = "00000000-0000-0000-0000-000000000001"
}

run "archive_replication_disabled_by_default" {
  command = plan
  assert {
    condition     = !output.erp_event_archive_replication_enabled && length(azurerm_storage_account.erp_archive_dr) == 0 && length(azurerm_storage_object_replication.erp_archive_dr) == 0
    error_message = "La réplica regional no debe crearse por defecto."
  }
}

run "archive_replication_requires_integration" {
  command = plan
  variables {
    enable_erp_event_archive_replication = true
  }
  expect_failures = [var.enable_erp_event_archive_replication]
}

run "archive_replication_rejects_same_region" {
  command = plan
  variables {
    enable_erp_integration               = true
    enable_erp_event_archive_replication = true
    erp_event_archive_dr_location        = "WESTUS2"
  }
  expect_failures = [var.enable_erp_event_archive_replication]
}

run "archive_replication_is_private_and_copies_existing_events" {
  command = plan
  variables {
    enable_erp_integration               = true
    enable_erp_event_archive_replication = true
  }
  override_resource {
    target          = azurerm_storage_account.erp_events[0]
    override_during = plan
    values = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/test/providers/Microsoft.Storage/storageAccounts/sourceevents"
    }
  }
  override_resource {
    target          = azurerm_storage_account.erp_archive_dr[0]
    override_during = plan
    values = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/test/providers/Microsoft.Storage/storageAccounts/destinationevents"
    }
  }
  override_resource {
    target          = azurerm_storage_object_replication.erp_archive_dr[0]
    override_during = plan
    values = {
      source_object_replication_id = "/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/test/providers/Microsoft.Storage/storageAccounts/sourceevents/objectReplicationPolicies/00000000-0000-0000-0000-000000000123"
    }
  }
  assert {
    condition = (
      output.erp_event_archive_replication_enabled &&
      azurerm_storage_account.erp_events[0].blob_properties[0].versioning_enabled &&
      azurerm_storage_account.erp_events[0].blob_properties[0].change_feed_enabled &&
      !azurerm_storage_account.erp_events[0].cross_tenant_replication_enabled &&
      azurerm_storage_account.erp_archive_dr[0].blob_properties[0].versioning_enabled &&
      !azurerm_storage_account.erp_archive_dr[0].cross_tenant_replication_enabled
    )
    error_message = "Ambas cuentas deben habilitar versionado, el origen change feed y la replicación debe permanecer en el tenant."
  }
  assert {
    condition = (
      azurerm_storage_account.erp_archive_dr[0].account_replication_type == "ZRS" &&
      azurerm_storage_account.erp_archive_dr[0].public_network_access == "Disabled" &&
      !azurerm_storage_account.erp_archive_dr[0].shared_access_key_enabled &&
      azurerm_storage_container.erp_archive_dr[0].container_access_type == "private" &&
      toset(azurerm_private_endpoint.erp_archive_dr[0].private_service_connection[0].subresource_names) == toset(["blob"])
    )
    error_message = "El archivo regional debe ser ZRS, privado, sin Shared Key y con Private Endpoint Blob."
  }
  assert {
    condition = (
      one(azurerm_storage_object_replication.erp_archive_dr[0].rules).source_container_name == "erp-events" &&
      one(azurerm_storage_object_replication.erp_archive_dr[0].rules).destination_container_name == "erp-events-replica" &&
      one(azurerm_storage_object_replication.erp_archive_dr[0].rules).copy_blobs_created_after == "Everything" &&
      azurerm_storage_object_replication.erp_archive_dr[0].metrics_enabled
    )
    error_message = "La regla debe copiar eventos históricos y nuevos al contenedor regional."
  }
  assert {
    condition = (
      one(azurerm_monitor_metric_alert.erp_archive_dr_pending[0].scopes) == azurerm_storage_object_replication.erp_archive_dr[0].source_object_replication_id &&
      azurerm_monitor_metric_alert.erp_archive_dr_pending[0].criteria[0].metric_name == "PendingOperationsForReplication" &&
      azurerm_monitor_metric_alert.erp_archive_dr_pending[0].criteria[0].aggregation == "Minimum" &&
      azurerm_monitor_metric_alert.erp_archive_dr_pending[0].criteria[0].threshold == 0 &&
      azurerm_monitor_metric_alert.erp_archive_dr_pending[0].window_size == "PT5M" &&
      length(azurerm_monitor_metric_alert.erp_archive_dr_pending[0].action) == 0
    )
    error_message = "La alerta debe observar la política origen; sin correo no debe configurar el grupo de acción."
  }
}

run "archive_alert_attaches_email_action_when_configured" {
  command = plan
  variables {
    enable_erp_integration               = true
    enable_erp_event_archive_replication = true
    notification_email                   = "team@example.com"
  }
  assert {
    condition     = length(azurerm_monitor_metric_alert.erp_archive_dr_pending[0].action) == 1 && length(azurerm_monitor_action_group.email) == 1
    error_message = "Si se configura correo, la alerta regional debe incluir el grupo de acción."
  }
}

run "regional_ingress_disabled_by_default" {
  command = plan
  assert {
    condition     = !output.erp_failover_ingest_enabled && length(azurerm_function_app_flex_consumption.erp_ingest_dr) == 0
    error_message = "La Function regional debe permanecer desactivada por defecto."
  }
}

run "regional_ingress_requires_archive_replication" {
  command = plan
  variables {
    enable_erp_integration     = true
    enable_erp_failover_ingest = true
  }
  expect_failures = [var.enable_erp_failover_ingest]
}

run "regional_ingress_requires_distinct_location" {
  command = plan
  variables {
    enable_erp_integration               = true
    enable_erp_event_archive_replication = true
    enable_erp_failover_ingest           = true
    erp_failover_ingest_location         = "westus2"
  }
  expect_failures = [var.enable_erp_failover_ingest]
}

run "regional_ingress_uses_isolated_intake_and_dns" {
  command = plan
  variables {
    enable_erp_integration               = true
    enable_erp_event_archive_replication = true
    enable_erp_failover_ingest           = true
  }
  override_resource {
    target          = azurerm_storage_account.erp_archive_dr[0]
    override_during = plan
    values = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/test/providers/Microsoft.Storage/storageAccounts/destinationevents"
    }
  }
  override_resource {
    target          = random_password.erp_ingest[0]
    override_during = plan
    values          = { result = "fixture-primary-not-secret" }
  }
  override_resource {
    target          = random_password.erp_ingest_dr[0]
    override_during = plan
    values          = { result = "fixture-secondary-not-secret" }
  }
  assert {
    condition = (
      output.erp_failover_ingest_enabled &&
      azurerm_function_app_flex_consumption.erp_ingest_dr[0].location == "eastus2" &&
      azurerm_function_app_flex_consumption.erp_ingest_dr[0].https_only &&
      azurerm_service_plan.erp_ingest_dr[0].zone_balancing_enabled &&
      azurerm_storage_account.erp_ingest_dr_host[0].account_replication_type == "ZRS" &&
      azurerm_storage_container.erp_failover_intake[0].name == "erp-events-failover" &&
      azurerm_storage_container.erp_failover_intake[0].name != azurerm_storage_container.erp_archive_dr[0].name
    )
    error_message = "La Function regional debe usar dos zonas, host ZRS y un contenedor de ingesta separado de la réplica."
  }
  assert {
    condition = (
      azurerm_function_app_flex_consumption.erp_ingest_dr[0].app_settings.FILES_DR_SYNC_ENABLED == "false" &&
      azurerm_function_app_flex_consumption.erp_ingest_dr[0].app_settings.ERP_EVENTS_CONTAINER == "erp-events-failover" &&
      nonsensitive(azurerm_function_app_flex_consumption.erp_ingest_dr[0].app_settings.ERP_INGEST_HMAC_SECRET) == "fixture-secondary-not-secret" &&
      endswith(azurerm_role_assignment.erp_ingest_dr_events[0].scope, "/blobServices/default/containers/erp-events-failover") &&
      azurerm_private_dns_zone.erp_ingest_dr[0].resource_group_name != azurerm_private_dns_zone.erp_blob[0].resource_group_name
    )
    error_message = "La ingesta secundaria debe limitar el rol, desactivar Files DR y aislar DNS por red."
  }
}
