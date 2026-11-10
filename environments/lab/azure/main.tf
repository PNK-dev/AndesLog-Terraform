data "azurerm_client_config" "current" {}

locals {
  prefix = "${var.project}-${var.environment}"

  common_tags = {
    Project     = "AndesLog"
    Environment = var.environment
    ManagedBy   = "Terraform"
    Owner       = var.owner
    TTL         = var.ttl_date
    CostCenter  = "academic"
  }

  # Azure Storage names are globally unique, lowercase alphanumeric, and at most 24 characters.
  storage_account_name = "${substr(replace(lower(var.project), "-", ""), 0, 11)}${substr(sha256(var.subscription_id), 0, 13)}"
}

resource "azurerm_resource_group" "main" {
  name     = "${local.prefix}-rg"
  location = var.azure_location
  tags     = merge(local.common_tags, { Purpose = "resource-group" })
}

# The retained Azure Files account lives in this pre-existing resource group.
# Adopt the group when that account is selected so a fresh HCP state does not
# try to create a conflicting group. lab.ps1 removes it from state on Destroy.
import {
  for_each = var.enable_remote_access && !var.create_files_storage_account ? { retained = true } : {}
  to       = azurerm_resource_group.main
  id       = "/subscriptions/${var.subscription_id}/resourceGroups/${local.prefix}-rg"
}

resource "azurerm_virtual_network" "main" {
  name                = "${local.prefix}-vnet"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  address_space       = [var.azure_vnet_cidr]
  dns_servers         = var.enable_remote_access ? ["10.20.254.4"] : []
  tags                = merge(local.common_tags, { Purpose = "network" })
}

resource "azurerm_subnet" "gateway" {
  count                = var.enable_intercloud_vpn || var.enable_remote_access ? 1 : 0
  name                 = "GatewaySubnet"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = ["10.20.255.0/27"]
}

resource "azurerm_subnet" "private" {
  name                 = "snet-private"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = ["10.20.11.0/24"]
}

resource "azurerm_subnet" "dns_inbound" {
  count                = var.enable_remote_access ? 1 : 0
  name                 = "snet-dns-inbound"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = ["10.20.254.0/28"]

  delegation {
    name = "dns-resolver"
    service_delegation {
      name    = "Microsoft.Network/dnsResolvers"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

resource "azurerm_private_dns_resolver" "main" {
  count               = var.enable_remote_access ? 1 : 0
  name                = "${local.prefix}-dns-resolver"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  virtual_network_id  = azurerm_virtual_network.main.id
  tags                = merge(local.common_tags, { Purpose = "private-dns-resolution" })
}

resource "azurerm_private_dns_resolver_inbound_endpoint" "main" {
  count                   = var.enable_remote_access ? 1 : 0
  name                    = "${local.prefix}-dns-inbound"
  private_dns_resolver_id = azurerm_private_dns_resolver.main[0].id
  location                = azurerm_resource_group.main.location
  tags                    = merge(local.common_tags, { Purpose = "private-dns-resolution" })

  ip_configurations {
    private_ip_allocation_method = "Static"
    private_ip_address           = "10.20.254.4"
    subnet_id                    = azurerm_subnet.dns_inbound[0].id
  }
}

locals {
  gateway_public_ip_names = var.enable_intercloud_vpn || var.enable_remote_access ? (
    var.enable_remote_access ? ["gateway-a", "gateway-b", "p2s"] : ["gateway-a", "gateway-b"]
  ) : []
  aws_vpn_tunnel_names = ["azure-gateway-a-1", "azure-gateway-a-2", "azure-gateway-b-1", "azure-gateway-b-2"]
  # APIPA layout follows Microsoft's Azure active-active + AWS BGP topology.
  aws_tunnel_custom_bgp_addresses = {
    "azure-gateway-a-1" = { primary = "169.254.21.2", secondary = "169.254.21.6" }
    "azure-gateway-a-2" = { primary = "169.254.22.2", secondary = "169.254.21.6" }
    "azure-gateway-b-1" = { primary = "169.254.21.2", secondary = "169.254.21.6" }
    "azure-gateway-b-2" = { primary = "169.254.21.2", secondary = "169.254.22.6" }
  }
}

resource "azurerm_public_ip" "gateway" {
  for_each            = toset(local.gateway_public_ip_names)
  name                = "${local.prefix}-vpn-${each.key}-pip"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  allocation_method   = "Static"
  sku                 = "Standard"
  zones               = var.azure_gateway_zones
  tags                = merge(local.common_tags, { Purpose = "vpn-gateway" })
}

resource "azurerm_virtual_network_gateway" "main" {
  count               = var.enable_intercloud_vpn || var.enable_remote_access ? 1 : 0
  name                = "${local.prefix}-vpngw"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  type                = "Vpn"
  vpn_type            = "RouteBased"
  active_active       = true
  bgp_enabled         = var.enable_intercloud_vpn
  sku                 = var.azure_vpn_gateway_sku

  dynamic "ip_configuration" {
    for_each = local.gateway_public_ip_names
    content {
      name                          = "${ip_configuration.value}-config"
      public_ip_address_id          = azurerm_public_ip.gateway[ip_configuration.value].id
      private_ip_address_allocation = "Dynamic"
      subnet_id                     = azurerm_subnet.gateway[0].id
    }
  }

  dynamic "vpn_client_configuration" {
    for_each = var.enable_remote_access ? [1] : []
    content {
      address_space        = [var.vpn_client_address_pool]
      vpn_client_protocols = ["OpenVPN"]
      vpn_auth_types       = ["AAD"]
      aad_tenant           = "https://login.microsoftonline.com/${data.azurerm_client_config.current.tenant_id}/"
      aad_audience         = var.vpn_client_aad_audience
      aad_issuer           = "https://sts.windows.net/${data.azurerm_client_config.current.tenant_id}/"
    }
  }

  dynamic "custom_route" {
    for_each = var.enable_remote_access && var.enable_intercloud_vpn ? [1] : []
    content { address_prefixes = [var.aws_vpc_cidr] }
  }

  dynamic "bgp_settings" {
    for_each = var.enable_intercloud_vpn ? [1] : []
    content {
      asn = 65000

      peering_addresses {
        ip_configuration_name = "gateway-a-config"
        apipa_addresses       = ["169.254.21.2", "169.254.22.2"]
      }

      peering_addresses {
        ip_configuration_name = "gateway-b-config"
        apipa_addresses       = ["169.254.21.6", "169.254.22.6"]
      }
    }
  }

  tags = merge(local.common_tags, { Purpose = "zone-redundant-vpn-gateway" })
}

resource "azurerm_local_network_gateway" "aws" {
  for_each = var.enable_aws_vpn_connections ? toset(local.aws_vpn_tunnel_names) : toset([])

  name                = "${local.prefix}-aws-${each.key}-lng"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  gateway_address     = [for tunnel in var.aws_vpn_tunnel_configs : tunnel.address if tunnel.name == each.key][0]

  bgp_settings {
    asn                 = 64512
    bgp_peering_address = [for tunnel in var.aws_vpn_tunnel_configs : tunnel.bgp_peer_address if tunnel.name == each.key][0]
  }

  tags = merge(local.common_tags, { Purpose = "intercloud-vpn" })
}

resource "azurerm_virtual_network_gateway_connection" "aws" {
  for_each = var.enable_aws_vpn_connections ? toset(local.aws_vpn_tunnel_names) : toset([])

  name                               = "${local.prefix}-aws-${each.key}-connection"
  resource_group_name                = azurerm_resource_group.main.name
  location                           = azurerm_resource_group.main.location
  type                               = "IPsec"
  virtual_network_gateway_id         = azurerm_virtual_network_gateway.main[0].id
  local_network_gateway_id           = azurerm_local_network_gateway.aws[each.key].id
  shared_key                         = [for tunnel in var.aws_vpn_tunnel_configs : tunnel.shared_key if tunnel.name == each.key][0]
  bgp_enabled                        = true
  use_policy_based_traffic_selectors = false

  custom_bgp_addresses {
    primary   = local.aws_tunnel_custom_bgp_addresses[each.key].primary
    secondary = local.aws_tunnel_custom_bgp_addresses[each.key].secondary
  }

  tags = merge(local.common_tags, { Purpose = "intercloud-vpn" })
}
resource "azurerm_storage_account" "backups" {
  name                            = local.storage_account_name
  resource_group_name             = azurerm_resource_group.main.name
  location                        = azurerm_resource_group.main.location
  account_kind                    = "StorageV2"
  account_tier                    = "Standard"
  account_replication_type        = "ZRS"
  min_tls_version                 = "TLS1_2"
  https_traffic_only_enabled      = true
  allow_nested_items_to_be_public = false
  public_network_access           = "Enabled"
  shared_access_key_enabled       = false
  default_to_oauth_authentication = true

  tags = merge(local.common_tags, { Name = local.storage_account_name, Purpose = "backup" })
}

resource "azurerm_role_assignment" "blob_data_contributor" {
  count                = var.create_blob_role_assignment ? 1 : 0
  scope                = azurerm_storage_account.backups.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = data.azurerm_client_config.current.object_id
  description          = "Permite a la identidad que ejecuta Terraform administrar respaldos en el contenedor de AndesLog."
}

resource "azurerm_storage_container" "backups" {
  name                  = "backups"
  storage_account_id    = azurerm_storage_account.backups.id
  container_access_type = "private"

  depends_on = [azurerm_role_assignment.blob_data_contributor]
}

resource "azurerm_monitor_action_group" "email" {
  count = var.notification_email == "" ? 0 : 1

  name                = "${local.prefix}-email-alerts"
  resource_group_name = azurerm_resource_group.main.name
  short_name          = "andeslog"

  email_receiver {
    name                    = "project-owner"
    email_address           = var.notification_email
    use_common_alert_schema = true
  }

  tags = merge(local.common_tags, { Purpose = "alarm-notifications" })
}

resource "azurerm_monitor_metric_alert" "files_availability" {
  count = var.enable_remote_access && var.notification_email != "" ? 1 : 0

  name                = "${local.prefix}-files-availability-low"
  resource_group_name = azurerm_resource_group.main.name
  scopes              = [local.files_account_id]
  description         = "Azure Files availability dropped below 99% over a 15-minute window."
  severity            = 1
  frequency           = "PT5M"
  window_size         = "PT15M"

  criteria {
    metric_namespace = "Microsoft.Storage/storageAccounts"
    metric_name      = "Availability"
    aggregation      = "Average"
    operator         = "LessThan"
    threshold        = 99
  }

  action {
    action_group_id = azurerm_monitor_action_group.email[0].id
  }

  tags = merge(local.common_tags, { Purpose = "files-availability-monitoring" })
}
