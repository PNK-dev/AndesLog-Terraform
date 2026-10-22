output "subscription_id" {
  description = "Suscripción objetivo."
  value       = var.subscription_id
}

output "resource_group_name" {
  description = "Resource Group del laboratorio."
  value       = azurerm_resource_group.main.name
}

output "vpn_public_ip" {
  description = "IP pública estática del peer WireGuard Azure."
  value       = azurerm_public_ip.vpn.ip_address
}

output "vpn_private_ip" {
  description = "IP privada estática de la VM VPN Azure."
  value       = azurerm_network_interface.vpn.private_ip_address
}

output "storage_account_name" {
  description = "Cuenta StorageV2 para respaldos."
  value       = azurerm_storage_account.backups.name
}

output "blob_container_name" {
  description = "Contenedor privado de respaldos."
  value       = azurerm_storage_container.backups.name
}

output "blob_endpoint" {
  description = "Endpoint HTTPS del servicio Blob."
  value       = azurerm_storage_account.backups.primary_blob_endpoint
}

output "wireguard_peer_cidr_for_aws" {
  description = "Copiar este valor a azure_peer_public_cidr del archivo AWS tfvars."
  value       = "${azurerm_public_ip.vpn.ip_address}/32"
}
