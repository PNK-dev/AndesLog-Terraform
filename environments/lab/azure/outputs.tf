output "subscription_id" {
  description = "Suscripción objetivo."
  value       = var.subscription_id
}

output "resource_group_name" {
  description = "Resource Group del laboratorio."
  value       = azurerm_resource_group.main.name
}

output "vpn_gateway_id" {
  description = "ID de Azure VPN Gateway activo-activo cuando está habilitado."
  value       = try(azurerm_virtual_network_gateway.main[0].id, "")
}

output "vpn_gateway_public_ips" {
  description = "Dos direcciones públicas de Azure VPN Gateway usadas para redundancia AWS Site-to-Site."
  value = var.enable_intercloud_vpn ? [
    azurerm_public_ip.gateway["gateway-a"].ip_address,
    azurerm_public_ip.gateway["gateway-b"].ip_address
  ] : []
}

output "vpn_gateway_name" {
  description = "Nombre del gateway para exportar el perfil P2S Windows desde Azure CLI."
  value       = try(azurerm_virtual_network_gateway.main[0].name, "")
}

output "vpn_s2s_connection_names" {
  description = "Nombres de las cuatro conexiones IPsec/BGP de respaldo a AWS."
  value       = sort([for connection in azurerm_virtual_network_gateway_connection.aws : connection.name])
}

output "storage_account_name" {
  description = "Cuenta StorageV2 para respaldos."
  value       = try(azurerm_storage_account.backups.name, "")
}

output "blob_container_name" {
  description = "Contenedor privado de respaldos."
  value       = try(azurerm_storage_container.backups.name, "")
}

output "blob_endpoint" {
  description = "Endpoint HTTPS del servicio Blob."
  value       = try(azurerm_storage_account.backups.primary_blob_endpoint, "")
}

output "backup_audit_function_name" {
  description = "Nombre de la Azure Function de auditoría, si está activada."
  value       = try(azurerm_function_app_flex_consumption.backup_audit[0].name, "")
}

output "erp_event_function_name" {
  description = "Nombre de la Azure Function que recibe eventos firmados del ERP."
  value       = try(azurerm_function_app_flex_consumption.erp_ingest[0].name, "")
}

output "erp_event_ingest_url" {
  description = "Endpoint HTTPS de ingreso de eventos del ERP en Azure."
  value       = try("https://${azurerm_function_app_flex_consumption.erp_ingest[0].default_hostname}/api/erp/events", "")
}

output "erp_event_hmac_secret" {
  description = "Clave compartida entre el ERP y la Function para autenticar los eventos."
  value       = try(random_password.erp_ingest[0].result, "")
  sensitive   = true
}

output "erp_event_storage_account_name" {
  description = "Storage ZRS privado lógicamente para la outbox archivada del ERP."
  value       = try(azurerm_storage_account.erp_events[0].name, "")
}

output "erp_event_container_name" {
  description = "Contenedor privado que guarda los eventos entregados por el ERP."
  value       = try(azurerm_storage_container.erp_events[0].name, "")
}

output "backup_audit_container_name" {
  description = "Contenedor privado con los resultados JSON de auditoría."
  value       = try(azurerm_storage_container.backup_audit[0].name, "")
}

output "files_storage_account_name" {
  description = "Cuenta privada Azure Files corporativa, si está activada."
  value = var.enable_remote_access ? (
    var.create_files_storage_account ? azurerm_storage_account.shared_files[0].name : azurerm_storage_account.shared_files_existing[0].name
  ) : ""
}

output "files_share_name" {
  description = "Nombre del recurso compartido SMB."
  value       = var.enable_remote_access ? (var.create_files_storage_account ? azurerm_storage_share.corporate[0].name : var.existing_files_share_name) : ""
}

output "files_private_ip" {
  description = "IP privada del endpoint Azure Files; el cliente VPN debe resolver el FQDN a esta dirección."
  value       = try(azurerm_private_endpoint.files[0].private_service_connection[0].private_ip_address, "")
}

output "files_dns_resolver_ip" {
  description = "Private Resolver inbound IP address for VPN clients to resolve Azure Files private DNS."
  value       = var.enable_remote_access ? "10.20.254.4" : ""
}

output "files_dr_storage_account_name" {
  description = "Cuenta Azure Files independiente en la región secundaria para sincronización y recuperación manual."
  value       = try(azurerm_storage_account.files_dr[0].name, "")
}

output "files_dr_location" {
  description = "Región de la copia manual de Azure Files."
  value       = local.files_dr_enabled ? var.azure_files_dr_location : ""
}

output "files_dr_share_name" {
  description = "Nombre de la copia SMB regional de Azure Files."
  value       = try(azurerm_storage_share.files_dr[0].name, "")
}

output "files_dr_private_ip" {
  description = "IP privada del Private Endpoint regional de Azure Files."
  value       = try(azurerm_private_endpoint.files_dr[0].private_service_connection[0].private_ip_address, "")
}

output "files_dr_vnet_cidr" {
  description = "Prefijo de red de la VNet de recuperación de Azure Files."
  value       = local.files_dr_enabled ? var.azure_files_dr_vnet_cidr : ""
}

output "files_dr_gateway_name" {
  description = "Nombre del gateway P2S opcional para la conmutación manual regional."
  value       = try(azurerm_virtual_network_gateway.files_dr[0].name, "")
}

output "files_dr_checkpoint_enabled" {
  description = "Indica si está activada la reanudación experimental del recorrido de Azure Files."
  value       = local.files_dr_checkpoint_enabled
}
