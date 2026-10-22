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

resource "azurerm_virtual_network" "main" {
  name                = "${local.prefix}-vnet"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  address_space       = [var.azure_vnet_cidr]
  tags                = merge(local.common_tags, { Purpose = "network" })
}

resource "azurerm_subnet" "vpn" {
  name                 = "snet-vpn"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = ["10.20.1.0/24"]
}

resource "azurerm_subnet" "private" {
  name                 = "snet-private"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = ["10.20.11.0/24"]
}

resource "azurerm_public_ip" "vpn" {
  name                = "${local.prefix}-vpn-pip"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = merge(local.common_tags, { Purpose = "wireguard" })
}

resource "azurerm_network_security_group" "vpn" {
  name                = "${local.prefix}-nsg-vpn"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  tags                = merge(local.common_tags, { Purpose = "wireguard" })
}

resource "azurerm_network_security_rule" "ssh_admin" {
  count                       = var.admin_public_cidr == "" ? 0 : 1
  name                        = "ssh-admin-ipv4"
  priority                    = 100
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "22"
  source_address_prefix       = var.admin_public_cidr
  destination_address_prefix  = "10.20.1.10"
  resource_group_name         = azurerm_resource_group.main.name
  network_security_group_name = azurerm_network_security_group.vpn.name
}

resource "azurerm_network_security_rule" "wireguard_from_aws" {
  count                       = var.aws_peer_public_cidr == "" ? 0 : 1
  name                        = "wireguard-from-aws-peer"
  priority                    = 110
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Udp"
  source_port_range           = "*"
  destination_port_range      = "51820"
  source_address_prefix       = var.aws_peer_public_cidr
  destination_address_prefix  = "10.20.1.10"
  resource_group_name         = azurerm_resource_group.main.name
  network_security_group_name = azurerm_network_security_group.vpn.name
}

resource "azurerm_network_security_rule" "deny_other_inbound" {
  name                        = "deny-other-inbound"
  priority                    = 4096
  direction                   = "Inbound"
  access                      = "Deny"
  protocol                    = "*"
  source_port_range           = "*"
  destination_port_range      = "*"
  source_address_prefix       = "*"
  destination_address_prefix  = "*"
  resource_group_name         = azurerm_resource_group.main.name
  network_security_group_name = azurerm_network_security_group.vpn.name
}

resource "azurerm_network_security_rule" "http_bootstrap" {
  name                        = "http-https-bootstrap"
  priority                    = 120
  direction                   = "Outbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_ranges     = ["80", "443"]
  source_address_prefix       = "VirtualNetwork"
  destination_address_prefix  = "Internet"
  resource_group_name         = azurerm_resource_group.main.name
  network_security_group_name = azurerm_network_security_group.vpn.name
}

resource "azurerm_network_security_rule" "wireguard_to_aws" {
  count                       = var.aws_peer_public_cidr == "" ? 0 : 1
  name                        = "wireguard-to-aws-peer"
  priority                    = 110
  direction                   = "Outbound"
  access                      = "Allow"
  protocol                    = "Udp"
  source_port_range           = "*"
  destination_port_range      = "51820"
  source_address_prefix       = "10.20.1.10"
  destination_address_prefix  = var.aws_peer_public_cidr
  resource_group_name         = azurerm_resource_group.main.name
  network_security_group_name = azurerm_network_security_group.vpn.name
}

resource "azurerm_network_security_rule" "probe_aws_web_a" {
  name                        = "probe-aws-web-a"
  priority                    = 130
  direction                   = "Outbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "8080"
  source_address_prefix       = "10.20.1.10"
  destination_address_prefix  = "10.10.11.0/24"
  resource_group_name         = azurerm_resource_group.main.name
  network_security_group_name = azurerm_network_security_group.vpn.name
}

resource "azurerm_network_security_rule" "probe_aws_web_b" {
  name                        = "probe-aws-web-b"
  priority                    = 131
  direction                   = "Outbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "8080"
  source_address_prefix       = "10.20.1.10"
  destination_address_prefix  = "10.10.12.0/24"
  resource_group_name         = azurerm_resource_group.main.name
  network_security_group_name = azurerm_network_security_group.vpn.name
}

resource "azurerm_network_security_rule" "deny_internet_egress_other" {
  name                        = "deny-other-internet-egress"
  priority                    = 4090
  direction                   = "Outbound"
  access                      = "Deny"
  protocol                    = "*"
  source_port_range           = "*"
  destination_port_range      = "*"
  source_address_prefix       = "VirtualNetwork"
  destination_address_prefix  = "Internet"
  resource_group_name         = azurerm_resource_group.main.name
  network_security_group_name = azurerm_network_security_group.vpn.name
}

resource "azurerm_subnet_network_security_group_association" "vpn" {
  subnet_id                 = azurerm_subnet.vpn.id
  network_security_group_id = azurerm_network_security_group.vpn.id
}

resource "azurerm_route_table" "private" {
  name                = "${local.prefix}-rt-private"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  tags                = merge(local.common_tags, { Purpose = "private-routes" })
}

resource "azurerm_route" "aws_web_a" {
  name                   = "aws-web-a-via-wireguard"
  resource_group_name    = azurerm_resource_group.main.name
  route_table_name       = azurerm_route_table.private.name
  address_prefix         = "10.10.11.0/24"
  next_hop_type          = "VirtualAppliance"
  next_hop_in_ip_address = "10.20.1.10"
}

resource "azurerm_route" "aws_web_b" {
  name                   = "aws-web-b-via-wireguard"
  resource_group_name    = azurerm_resource_group.main.name
  route_table_name       = azurerm_route_table.private.name
  address_prefix         = "10.10.12.0/24"
  next_hop_type          = "VirtualAppliance"
  next_hop_in_ip_address = "10.20.1.10"
}

resource "azurerm_subnet_route_table_association" "private" {
  subnet_id      = azurerm_subnet.private.id
  route_table_id = azurerm_route_table.private.id
}

resource "azurerm_network_interface" "vpn" {
  name                  = "${local.prefix}-vpn-nic"
  resource_group_name   = azurerm_resource_group.main.name
  location              = azurerm_resource_group.main.location
  ip_forwarding_enabled = true

  ip_configuration {
    name                          = "primary"
    subnet_id                     = azurerm_subnet.vpn.id
    private_ip_address_allocation = "Static"
    private_ip_address            = "10.20.1.10"
    public_ip_address_id          = azurerm_public_ip.vpn.id
  }

  tags = merge(local.common_tags, { Name = "${local.prefix}-vpn-nic", Purpose = "wireguard" })
}

resource "azurerm_linux_virtual_machine" "vpn" {
  name                            = "${local.prefix}-vpn"
  resource_group_name             = azurerm_resource_group.main.name
  location                        = azurerm_resource_group.main.location
  size                            = var.vm_size
  admin_username                  = var.admin_username
  disable_password_authentication = true
  network_interface_ids           = [azurerm_network_interface.vpn.id]
  custom_data                     = filebase64("${path.module}/../../../scripts/azure-vpn-cloud-init.yml")

  admin_ssh_key {
    username   = var.admin_username
    public_key = var.admin_ssh_public_key
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
    disk_size_gb         = 30
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }

  tags = merge(local.common_tags, { Name = "${local.prefix}-vpn", Purpose = "wireguard-recovery" })
}

resource "azurerm_storage_account" "backups" {
  name                            = local.storage_account_name
  resource_group_name             = azurerm_resource_group.main.name
  location                        = azurerm_resource_group.main.location
  account_kind                    = "StorageV2"
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
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

resource "azurerm_monitor_metric_alert" "vm_cpu" {
  name                     = "${local.prefix}-vpn-cpu-high"
  resource_group_name      = azurerm_resource_group.main.name
  scopes                   = [azurerm_linux_virtual_machine.vpn.id]
  target_resource_type     = "Microsoft.Compute/virtualMachines"
  target_resource_location = azurerm_resource_group.main.location
  description              = "CPU promedio de la VM VPN sobre 70% durante cinco minutos."
  severity                 = 2
  enabled                  = true
  frequency                = "PT1M"
  window_size              = "PT5M"
  auto_mitigate            = true

  criteria {
    metric_namespace = "Microsoft.Compute/virtualMachines"
    metric_name      = "Percentage CPU"
    aggregation      = "Average"
    operator         = "GreaterThan"
    threshold        = 70
  }

  tags = merge(local.common_tags, { Purpose = "monitoring" })
}
