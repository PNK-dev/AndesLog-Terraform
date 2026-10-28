locals {
  files_account_name = "${substr(replace(lower(var.project), "-", ""), 0, 11)}fs${substr(sha256(var.subscription_id), 0, 11)}"
}

resource "azurerm_network_security_rule" "openvpn_remote" {
  count                       = var.enable_remote_access ? 1 : 0
  name                        = "openvpn-remote-clients"
  priority                    = 115
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Udp"
  source_port_range           = "*"
  destination_port_range      = "1194"
  source_address_prefix       = "Internet"
  destination_address_prefix  = "10.20.1.10"
  resource_group_name         = azurerm_resource_group.main.name
  network_security_group_name = azurerm_network_security_group.vpn.name
}

resource "azurerm_storage_account" "shared_files" {
  count                           = var.enable_remote_access ? 1 : 0
  name                            = local.files_account_name
  resource_group_name             = azurerm_resource_group.main.name
  location                        = azurerm_resource_group.main.location
  account_kind                    = "StorageV2"
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  min_tls_version                 = "TLS1_2"
  https_traffic_only_enabled      = true
  allow_nested_items_to_be_public = false
  public_network_access           = "Disabled"
  shared_access_key_enabled       = true
  tags                            = merge(local.common_tags, { Purpose = "corporate-files" })
}

resource "azurerm_storage_share" "corporate" {
  count              = var.enable_remote_access ? 1 : 0
  name               = "andeslog"
  storage_account_id = azurerm_storage_account.shared_files[0].id
  quota              = var.azure_files_quota_gb
  enabled_protocol   = "SMB"
}

resource "azurerm_private_dns_zone" "files" {
  count               = var.enable_remote_access ? 1 : 0
  name                = "privatelink.file.core.windows.net"
  resource_group_name = azurerm_resource_group.main.name
  tags                = merge(local.common_tags, { Purpose = "corporate-files-dns" })
}

resource "azurerm_private_dns_zone_virtual_network_link" "files" {
  count                = var.enable_remote_access ? 1 : 0
  name                 = "${local.prefix}-files-link"
  private_dns_zone_id  = azurerm_private_dns_zone.files[0].id
  virtual_network_id   = azurerm_virtual_network.main.id
  registration_enabled = false
  tags                 = merge(local.common_tags, { Purpose = "corporate-files-dns" })
}

resource "azurerm_private_endpoint" "files" {
  count               = var.enable_remote_access ? 1 : 0
  name                = "${local.prefix}-files-pe"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  subnet_id           = azurerm_subnet.private.id

  private_service_connection {
    name                           = "${local.prefix}-files-connection"
    private_connection_resource_id = azurerm_storage_account.shared_files[0].id
    subresource_names              = ["file"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "files-dns"
    private_dns_zone_ids = [azurerm_private_dns_zone.files[0].id]
  }

  tags = merge(local.common_tags, { Purpose = "corporate-files" })
}
