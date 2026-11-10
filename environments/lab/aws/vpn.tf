locals {
  vpn_connection_keys = ["azure-gateway-a", "azure-gateway-b"]
  vpn_tunnel_metrics = var.enable_intercloud_vpn ? merge([
    for key, connection in aws_vpn_connection.intercloud : {
      "${key}-1" = { vpn_id = connection.id, tunnel_address = connection.tunnel1_address }
      "${key}-2" = { vpn_id = connection.id, tunnel_address = connection.tunnel2_address }
    }
  ]...) : {}
}

# A managed AWS Virtual Private Gateway replaces the single WireGuard EC2.
# Azure's active-active gateway exposes two public IPs, represented here by
# two Customer Gateways and two BGP/IPsec connections (four tunnels total).
resource "aws_vpn_gateway" "main" {
  count           = var.enable_intercloud_vpn ? 1 : 0
  vpc_id          = aws_vpc.main.id
  amazon_side_asn = 64512
  tags            = merge(local.common_tags, { Name = "${local.prefix}-vgw", Purpose = "intercloud-vpn" })
}

resource "aws_customer_gateway" "azure" {
  for_each = var.enable_intercloud_vpn ? {
    azure-gateway-a = var.azure_gateway_public_ips[0]
    azure-gateway-b = var.azure_gateway_public_ips[1]
  } : {}

  bgp_asn    = 65000
  ip_address = each.value
  type       = "ipsec.1"
  tags       = merge(local.common_tags, { Name = "${local.prefix}-${each.key}-cgw", Purpose = "intercloud-vpn" })
}

resource "random_password" "vpn_tunnel" {
  for_each = var.enable_intercloud_vpn ? toset(flatten([
    for key in local.vpn_connection_keys : ["${key}-1", "${key}-2"]
  ])) : toset([])

  length           = 63
  min_lower        = 1
  min_upper        = 1
  min_numeric      = 1
  special          = false
  override_special = "._"
}

resource "aws_vpn_connection" "intercloud" {
  for_each = var.enable_intercloud_vpn ? aws_customer_gateway.azure : {}

  customer_gateway_id    = each.value.id
  type                   = "ipsec.1"
  vpn_gateway_id         = aws_vpn_gateway.main[0].id
  static_routes_only     = false
  preshared_key_storage  = "SecretsManager"
  tunnel1_inside_cidr    = each.key == "azure-gateway-a" ? "169.254.21.0/30" : "169.254.21.4/30"
  tunnel2_inside_cidr    = each.key == "azure-gateway-a" ? "169.254.22.0/30" : "169.254.22.4/30"
  tunnel1_preshared_key  = "A${substr(random_password.vpn_tunnel["${each.key}-1"].result, 0, 63)}"
  tunnel2_preshared_key  = "A${substr(random_password.vpn_tunnel["${each.key}-2"].result, 0, 63)}"
  tunnel1_startup_action = "start"
  tunnel2_startup_action = "start"
  tunnel1_ike_versions   = ["ikev2"]
  tunnel2_ike_versions   = ["ikev2"]
  tags                   = merge(local.common_tags, { Name = "${local.prefix}-${each.key}-s2s", Purpose = "intercloud-vpn" })
}

resource "aws_vpn_gateway_route_propagation" "app" {
  for_each = var.enable_intercloud_vpn ? local.app_subnets : {}

  vpn_gateway_id = aws_vpn_gateway.main[0].id
  route_table_id = aws_route_table.private[each.key].id
}

output "vpn_tunnel_configs" {
  description = "Sensitive IPsec tunnel data for the Azure root. Do not display or commit this output."
  sensitive   = true
  value = var.enable_intercloud_vpn ? flatten([
    for key, connection in aws_vpn_connection.intercloud : [
      { name = "${key}-1", address = connection.tunnel1_address, bgp_peer_address = connection.tunnel1_vgw_inside_address, shared_key = "A${substr(random_password.vpn_tunnel["${key}-1"].result, 0, 63)}" },
      { name = "${key}-2", address = connection.tunnel2_address, bgp_peer_address = connection.tunnel2_vgw_inside_address, shared_key = "A${substr(random_password.vpn_tunnel["${key}-2"].result, 0, 63)}" }
    ]
  ]) : []
}
