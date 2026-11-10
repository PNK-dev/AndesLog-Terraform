mock_provider "azurerm" {}
mock_provider "random" {}

variables {
  subscription_id = "00000000-0000-0000-0000-000000000001"
}

run "checkpoint_is_disabled_by_default" {
  command = plan

  assert {
    condition     = !output.files_dr_checkpoint_enabled && length(azurerm_storage_container.files_dr_checkpoint) == 0
    error_message = "El checkpoint debe estar desactivado por defecto."
  }
}

run "checkpoint_requires_the_whole_pipeline" {
  command = plan

  variables {
    enable_files_dr_checkpoint = true
  }

  expect_failures = [var.enable_files_dr_checkpoint]
}

run "checkpoint_is_private_and_scoped" {
  command = plan

  override_resource {
    target          = azurerm_storage_account.erp_events[0]
    override_during = plan
    values = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/test/providers/Microsoft.Storage/storageAccounts/testaccount"
    }
  }

  variables {
    enable_remote_access         = true
    create_files_storage_account = true
    enable_files_dr_replica      = true
    enable_erp_integration       = true
    enable_files_dr_checkpoint   = true
  }

  assert {
    condition     = output.files_dr_checkpoint_enabled && azurerm_storage_container.files_dr_checkpoint[0].container_access_type == "private"
    error_message = "El checkpoint debe usar un contenedor privado."
  }
  assert {
    condition     = endswith(azurerm_role_assignment.files_dr_checkpoint[0].scope, "/blobServices/default/containers/files-dr-checkpoints")
    error_message = "El permiso del checkpoint debe limitarse a su contenedor."
  }
  assert {
    condition     = endswith(azurerm_role_assignment.erp_ingest_events[0].scope, "/blobServices/default/containers/erp-events")
    error_message = "El permiso del ERP debe limitarse al contenedor de eventos."
  }
  assert {
    condition     = azurerm_function_app_flex_consumption.erp_ingest[0].app_settings.FILES_DR_CHECKPOINT_ENABLED == "true"
    error_message = "La Function debe recibir la configuración de checkpoint."
  }
}
