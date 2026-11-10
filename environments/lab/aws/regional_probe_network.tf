# Opt-in network for an independently operated replication probe. There is no
# internet route, public IP, or probe instance here. The ERP's normal app
# subnets do not gain a route to the recovery database.
locals {
  dr_probe_enabled = var.enable_aws_regional_dr && var.enable_dr_probe_network
  dr_probe_subnets = local.dr_probe_enabled ? { a = 31, b = 32 } : {}
  dr_probe_db_nets = local.dr_probe_enabled ? { a = 21, b = 22 } : {}
}

resource "aws_subnet" "dr_probe" {
  for_each                = local.dr_probe_subnets
  vpc_id                  = aws_vpc.main.id
  cidr_block              = cidrsubnet(var.aws_vpc_cidr, 8, each.value)
  availability_zone       = data.aws_availability_zones.available.names[each.key == "a" ? 0 : 1]
  map_public_ip_on_launch = false
  tags                    = merge(local.common_tags, { Name = "${local.prefix}-probe-${each.key}", Purpose = "regional-replication-monitor" })
}

resource "aws_vpc_peering_connection" "dr_probe" {
  count         = local.dr_probe_enabled ? 1 : 0
  vpc_id        = aws_vpc.main.id
  peer_vpc_id   = aws_vpc.dr[0].id
  peer_owner_id = data.aws_caller_identity.current.account_id
  peer_region   = var.aws_dr_region
  auto_accept   = false
  tags          = merge(local.common_tags, { Name = "${local.prefix}-probe-regional", Purpose = "regional-replication-monitor" })
}

resource "aws_vpc_peering_connection_accepter" "dr_probe" {
  provider                  = aws.dr
  count                     = local.dr_probe_enabled ? 1 : 0
  vpc_peering_connection_id = aws_vpc_peering_connection.dr_probe[0].id
  auto_accept               = true
  tags                      = merge(local.common_tags, { Name = "${local.prefix}-probe-regional", Purpose = "regional-replication-monitor" })
}

resource "aws_vpc_peering_connection_options" "dr_probe_requester" {
  count                     = local.dr_probe_enabled ? 1 : 0
  vpc_peering_connection_id = aws_vpc_peering_connection_accepter.dr_probe[0].id
  requester {
    allow_remote_vpc_dns_resolution = true
  }
}

resource "aws_vpc_peering_connection_options" "dr_probe_accepter" {
  provider                  = aws.dr
  count                     = local.dr_probe_enabled ? 1 : 0
  vpc_peering_connection_id = aws_vpc_peering_connection_accepter.dr_probe[0].id
  accepter {
    allow_remote_vpc_dns_resolution = true
  }
}

resource "aws_route_table" "dr_probe" {
  count  = local.dr_probe_enabled ? 1 : 0
  vpc_id = aws_vpc.main.id
  tags   = merge(local.common_tags, { Name = "${local.prefix}-probe", Purpose = "regional-replication-monitor" })
}

resource "aws_route_table_association" "dr_probe" {
  for_each       = local.dr_probe_subnets
  subnet_id      = aws_subnet.dr_probe[each.key].id
  route_table_id = aws_route_table.dr_probe[0].id
}

resource "aws_route" "dr_probe_to_replica" {
  for_each                  = local.dr_probe_db_nets
  route_table_id            = aws_route_table.dr_probe[0].id
  destination_cidr_block    = cidrsubnet(var.aws_dr_vpc_cidr, 8, each.value)
  vpc_peering_connection_id = aws_vpc_peering_connection_accepter.dr_probe[0].id
}

# RDS subnet associations are explicit so responses return only to the two
# monitoring subnets; neither VPC is a transit path for the other.
resource "aws_route_table" "dr_probe_replica" {
  provider = aws.dr
  count    = local.dr_probe_enabled ? 1 : 0
  vpc_id   = aws_vpc.dr[0].id
  tags     = merge(local.common_tags, { Name = "${local.prefix}-dr-db-probe", Purpose = "regional-replication-monitor" })
}

resource "aws_route_table_association" "dr_probe_replica" {
  provider       = aws.dr
  for_each       = local.dr_probe_db_nets
  subnet_id      = aws_subnet.dr_database[each.key].id
  route_table_id = aws_route_table.dr_probe_replica[0].id
}

resource "aws_route" "dr_replica_to_probe" {
  provider                  = aws.dr
  for_each                  = local.dr_probe_subnets
  route_table_id            = aws_route_table.dr_probe_replica[0].id
  destination_cidr_block    = cidrsubnet(var.aws_vpc_cidr, 8, each.value)
  vpc_peering_connection_id = aws_vpc_peering_connection_accepter.dr_probe[0].id
}

resource "aws_security_group" "dr_probe" {
  count       = local.dr_probe_enabled ? 1 : 0
  name        = "${local.prefix}-dr-probe"
  description = "Dedicated monitoring client: PostgreSQL only, no inbound traffic."
  vpc_id      = aws_vpc.main.id
  ingress     = []
  egress      = []
  lifecycle { ignore_changes = [ingress, egress] }
  tags = merge(local.common_tags, { Purpose = "regional-replication-monitor" })
}

resource "aws_vpc_security_group_egress_rule" "dr_probe_primary_db" {
  count                        = local.dr_probe_enabled ? 1 : 0
  security_group_id            = aws_security_group.dr_probe[0].id
  referenced_security_group_id = aws_security_group.db.id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
}

resource "aws_vpc_security_group_ingress_rule" "primary_db_from_dr_probe" {
  count                        = local.dr_probe_enabled ? 1 : 0
  security_group_id            = aws_security_group.db.id
  referenced_security_group_id = aws_security_group.dr_probe[0].id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
  description                  = "Dedicated regional replication monitor."
}

resource "aws_vpc_security_group_egress_rule" "dr_probe_replica_db" {
  for_each          = local.dr_probe_db_nets
  security_group_id = aws_security_group.dr_probe[0].id
  cidr_ipv4         = cidrsubnet(var.aws_dr_vpc_cidr, 8, each.value)
  ip_protocol       = "tcp"
  from_port         = 5432
  to_port           = 5432
}

resource "aws_vpc_security_group_ingress_rule" "dr_db_from_probe" {
  provider          = aws.dr
  for_each          = local.dr_probe_subnets
  security_group_id = aws_security_group.dr_database[0].id
  cidr_ipv4         = cidrsubnet(var.aws_vpc_cidr, 8, each.value)
  ip_protocol       = "tcp"
  from_port         = 5432
  to_port           = 5432
  description       = "Dedicated monitoring subnet over inter-region peering."
}

output "dr_probe_network_enabled" {
  description = "Indica si el estado incluye la red de supervisión regional experimental."
  value       = local.dr_probe_enabled
}

output "dr_probe_security_group_id" {
  description = "Grupo de seguridad para un futuro ejecutor de sondas; no se crea ningún ejecutor."
  value       = local.dr_probe_enabled ? aws_security_group.dr_probe[0].id : ""
}

output "dr_probe_subnet_ids" {
  description = "Subredes privadas para el futuro ejecutor de sondas regionales."
  value       = [for key in sort(keys(aws_subnet.dr_probe)) : aws_subnet.dr_probe[key].id]
}
