resource "azurerm_storage_account" "files_dr" {
  count                           = local.files_dr_enabled ? 1 : 0
  name                            = local.files_dr_account_name
  resource_group_name             = azurerm_resource_group.main.name
  location                        = var.azure_files_dr_location
  account_kind                    = "StorageV2"
  account_tier                    = "Standard"
  account_replication_type        = "ZRS"
  min_tls_version                 = "TLS1_2"
  https_traffic_only_enabled      = true
  allow_nested_items_to_be_public = false
  public_network_access           = "Disabled"
  shared_access_key_enabled       = true

  tags = merge(local.common_tags, { Purpose = "corporate-files-regional-replica" })
}

resource "azurerm_storage_share" "files_dr" {
  count              = local.files_dr_enabled ? 1 : 0
  name               = var.existing_files_share_name
  storage_account_id = azurerm_storage_account.files_dr[0].id
  quota              = var.azure_files_quota_gb
  enabled_protocol   = "SMB"
}

resource "azurerm_virtual_network" "files_dr" {
  count               = local.files_dr_enabled ? 1 : 0
  name                = "${local.prefix}-files-dr-vnet"
  resource_group_name = azurerm_resource_group.main.name
  location            = var.azure_files_dr_location
  address_space       = [var.azure_files_dr_vnet_cidr]
  dns_servers         = local.files_dr_gateway_enabled ? ["10.22.254.4"] : []

  tags = merge(local.common_tags, { Purpose = "corporate-files-regional-recovery" })
}

resource "azurerm_subnet" "files_dr_private_endpoints" {
  count                = local.files_dr_enabled ? 1 : 0
  name                 = "snet-files-private-endpoints"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.files_dr[0].name
  address_prefixes     = ["10.22.11.0/24"]

  private_endpoint_network_policies = "Disabled"
}

resource "azurerm_virtual_network_peering" "primary_to_files_dr" {
  count                     = local.files_dr_enabled ? 1 : 0
  name                      = "${local.prefix}-primary-to-files-dr"
  resource_group_name       = azurerm_resource_group.main.name
  virtual_network_name      = azurerm_virtual_network.main.name
  remote_virtual_network_id = azurerm_virtual_network.files_dr[0].id

  allow_virtual_network_access = true
  allow_forwarded_traffic      = true
  allow_gateway_transit        = true
}

resource "azurerm_virtual_network_peering" "files_dr_to_primary" {
  count                     = local.files_dr_enabled ? 1 : 0
  name                      = "${local.prefix}-files-dr-to-primary"
  resource_group_name       = azurerm_resource_group.main.name
  virtual_network_name      = azurerm_virtual_network.files_dr[0].name
  remote_virtual_network_id = azurerm_virtual_network.main.id

  allow_virtual_network_access = true
  allow_forwarded_traffic      = true
  use_remote_gateways          = !local.files_dr_gateway_enabled

  # Azure rejects gateway transit until the remote gateway and its peering
  # with allow_gateway_transit have finished provisioning.
  depends_on = [azurerm_virtual_network_gateway.main, azurerm_virtual_network_peering.primary_to_files_dr]
}

resource "azurerm_private_dns_zone_virtual_network_link" "files_dr" {
  count                = local.files_dr_enabled ? 1 : 0
  name                 = "${local.prefix}-files-dr-link"
  private_dns_zone_id  = azurerm_private_dns_zone.files[0].id
  virtual_network_id   = azurerm_virtual_network.files_dr[0].id
  registration_enabled = false

  tags = merge(local.common_tags, { Purpose = "corporate-files-dns" })
}

resource "azurerm_private_endpoint" "files_dr" {
  count               = local.files_dr_enabled ? 1 : 0
  name                = "${local.prefix}-files-dr-pe"
  resource_group_name = azurerm_resource_group.main.name
  location            = var.azure_files_dr_location
  subnet_id           = azurerm_subnet.files_dr_private_endpoints[0].id

  private_service_connection {
    name                           = "${local.prefix}-files-dr-connection"
    private_connection_resource_id = azurerm_storage_account.files_dr[0].id
    subresource_names              = ["file"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "files-dr-dns"
    private_dns_zone_ids = [azurerm_private_dns_zone.files[0].id]
  }

  tags = merge(local.common_tags, { Purpose = "corporate-files-regional-recovery" })
}

# AzCopy uses Microsoft Entra OAuth for the server-to-server mirror; it never
# needs to print or place either storage account key on the command line.
resource "azurerm_role_assignment" "files_sync_primary" {
  count                = local.files_dr_enabled ? 1 : 0
  scope                = "${local.files_account_id}/fileServices/default/fileshares/${var.existing_files_share_name}"
  role_definition_name = "Storage File Data Privileged Reader"
  principal_id         = data.azurerm_client_config.current.object_id
  description          = "Permite al operador leer origen Azure Files con OAuth para sincronización unidireccional."
}

resource "azurerm_role_assignment" "files_sync_dr" {
  count                = local.files_dr_enabled ? 1 : 0
  scope                = "${azurerm_storage_account.files_dr[0].id}/fileServices/default/fileshares/${var.existing_files_share_name}"
  role_definition_name = "Storage File Data Privileged Contributor"
  principal_id         = data.azurerm_client_config.current.object_id
  description          = "Permite al operador escribir en el share secundario Azure Files con OAuth."
  depends_on           = [azurerm_storage_share.files_dr]
}

resource "azurerm_subnet" "files_dr_gateway" {
  count                = local.files_dr_gateway_enabled ? 1 : 0
  name                 = "GatewaySubnet"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.files_dr[0].name
  address_prefixes     = ["10.22.255.0/27"]
}

resource "azurerm_subnet" "files_dr_dns_inbound" {
  count                = local.files_dr_gateway_enabled ? 1 : 0
  name                 = "snet-dns-inbound"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.files_dr[0].name
  address_prefixes     = ["10.22.254.0/28"]

  delegation {
    name = "dns-resolver"
    service_delegation {
      name    = "Microsoft.Network/dnsResolvers"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

resource "azurerm_private_dns_resolver" "files_dr" {
  count               = local.files_dr_gateway_enabled ? 1 : 0
  name                = "${local.prefix}-files-dr-dns-resolver"
  resource_group_name = azurerm_resource_group.main.name
  location            = var.azure_files_dr_location
  virtual_network_id  = azurerm_virtual_network.files_dr[0].id

  tags = merge(local.common_tags, { Purpose = "files-dr-private-dns-resolution" })
}

resource "azurerm_private_dns_resolver_inbound_endpoint" "files_dr" {
  count                   = local.files_dr_gateway_enabled ? 1 : 0
  name                    = "${local.prefix}-files-dr-dns-inbound"
  private_dns_resolver_id = azurerm_private_dns_resolver.files_dr[0].id
  location                = var.azure_files_dr_location

  ip_configurations {
    private_ip_allocation_method = "Static"
    private_ip_address           = "10.22.254.4"
    subnet_id                    = azurerm_subnet.files_dr_dns_inbound[0].id
  }

  tags = merge(local.common_tags, { Purpose = "files-dr-private-dns-resolution" })
}

resource "azurerm_public_ip" "files_dr_gateway" {
  for_each            = local.files_dr_gateway_enabled ? toset(["gateway-a", "gateway-b", "p2s"]) : toset([])
  name                = "${local.prefix}-files-dr-vpn-${each.key}-pip"
  resource_group_name = azurerm_resource_group.main.name
  location            = var.azure_files_dr_location
  allocation_method   = "Static"
  sku                 = "Standard"
  zones               = var.azure_gateway_zones

  tags = merge(local.common_tags, { Purpose = "files-dr-p2s-gateway" })
}

resource "azurerm_virtual_network_gateway" "files_dr" {
  count               = local.files_dr_gateway_enabled ? 1 : 0
  name                = "${local.prefix}-files-dr-vpngw"
  resource_group_name = azurerm_resource_group.main.name
  location            = var.azure_files_dr_location
  type                = "Vpn"
  vpn_type            = "RouteBased"
  active_active       = true
  bgp_enabled         = false
  sku                 = var.azure_vpn_gateway_sku

  dynamic "ip_configuration" {
    for_each = local.files_dr_gateway_enabled ? ["gateway-a", "gateway-b", "p2s"] : []
    content {
      name                          = "${ip_configuration.value}-config"
      public_ip_address_id          = azurerm_public_ip.files_dr_gateway[ip_configuration.value].id
      private_ip_address_allocation = "Dynamic"
      subnet_id                     = azurerm_subnet.files_dr_gateway[0].id
    }
  }

  dynamic "vpn_client_configuration" {
    for_each = local.files_dr_gateway_enabled ? [1] : []
    content {
      address_space        = [var.azure_files_dr_vpn_client_address_pool]
      vpn_client_protocols = ["OpenVPN"]
      vpn_auth_types       = ["AAD"]
      aad_tenant           = "https://login.microsoftonline.com/${data.azurerm_client_config.current.tenant_id}/"
      aad_audience         = var.vpn_client_aad_audience
      aad_issuer           = "https://sts.windows.net/${data.azurerm_client_config.current.tenant_id}/"
    }
  }

  tags = merge(local.common_tags, { Purpose = "manual-files-regional-failover" })

  # A VNet using the primary's remote gateway cannot create its own gateway.
  # Update the peering before creating this gateway and reverse the order when
  # tearing it down. See Azure gateway transit restrictions.
  depends_on = [
    azurerm_private_dns_resolver_inbound_endpoint.files_dr,
    azurerm_virtual_network_peering.files_dr_to_primary,
  ]
}
