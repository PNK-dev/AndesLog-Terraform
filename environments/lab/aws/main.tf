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

  subnet_definitions = {
    public-a = { cidr = "10.10.1.0/24", az_index = 0, public = true, purpose = "alb-vpn" }
    public-b = { cidr = "10.10.2.0/24", az_index = 1, public = true, purpose = "alb" }
    app-a    = { cidr = "10.10.11.0/24", az_index = 0, public = false, purpose = "web" }
    app-b    = { cidr = "10.10.12.0/24", az_index = 1, public = false, purpose = "web" }
    data-a   = { cidr = "10.10.21.0/24", az_index = 0, public = false, purpose = "database" }
    data-b   = { cidr = "10.10.22.0/24", az_index = 1, public = false, purpose = "reserved" }
  }

  public_subnets  = { for name, cfg in local.subnet_definitions : name => cfg if cfg.public }
  private_subnets = { for name, cfg in local.subnet_definitions : name => cfg if !cfg.public }
  app_subnets     = { for name, cfg in local.subnet_definitions : name => cfg if startswith(name, "app-") }
  db_subnet_names = { "data-a" = local.subnet_definitions["data-a"] }
  key_name = var.existing_key_name != "" ? var.existing_key_name : (
    var.ssh_public_key != "" ? aws_key_pair.admin[0].key_name : null
  )
  bucket_name = "${replace(lower(var.project), "/[^a-z0-9-]/", "-")}-${var.environment}-${data.aws_caller_identity.current.account_id}-backups"
}

data "aws_caller_identity" "current" {}

data "aws_availability_zones" "available" {
  state = "available"

  # Avoid Local Zones; the layout requires two standard AZs.
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

data "aws_ami" "ubuntu_2404" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "aws_key_pair" "admin" {
  count      = var.ssh_public_key == "" ? 0 : 1
  key_name   = "${local.prefix}-admin"
  public_key = var.ssh_public_key
  tags       = merge(local.common_tags, { Name = "${local.prefix}-admin-key", Purpose = "ssh-public-key" })
}

resource "aws_vpc" "main" {
  cidr_block           = var.aws_vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = merge(local.common_tags, { Name = "${local.prefix}-vpc", Purpose = "network" })
}

resource "aws_subnet" "this" {
  for_each = local.subnet_definitions

  vpc_id                  = aws_vpc.main.id
  cidr_block              = each.value.cidr
  availability_zone_id    = data.aws_availability_zones.available.zone_ids[each.value.az_index]
  map_public_ip_on_launch = each.value.public
  tags = merge(local.common_tags, {
    Name    = "${local.prefix}-${each.key}"
    Purpose = each.value.purpose
  })
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = merge(local.common_tags, { Name = "${local.prefix}-igw", Purpose = "internet-gateway" })
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  tags   = merge(local.common_tags, { Name = "${local.prefix}-rt-public", Purpose = "public-routes" })
}

resource "aws_route" "public_default" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.main.id
}

resource "aws_route_table_association" "public" {
  for_each       = local.public_subnets
  subnet_id      = aws_subnet.this[each.key].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private" {
  for_each = local.private_subnets
  vpc_id   = aws_vpc.main.id
  tags = merge(local.common_tags, {
    Name    = "${local.prefix}-rt-${each.key}"
    Purpose = "private-routes"
  })
}

resource "aws_route_table_association" "private" {
  for_each       = local.private_subnets
  subnet_id      = aws_subnet.this[each.key].id
  route_table_id = aws_route_table.private[each.key].id
}

resource "aws_eip" "temporary_nat" {
  count  = var.enable_temporary_nat ? 1 : 0
  domain = "vpc"
  tags   = merge(local.common_tags, { Name = "${local.prefix}-temporary-nat-eip", Purpose = "temporary-bootstrap" })
}

resource "aws_nat_gateway" "temporary" {
  count         = var.enable_temporary_nat ? 1 : 0
  allocation_id = aws_eip.temporary_nat[0].id
  subnet_id     = aws_subnet.this["public-a"].id
  depends_on    = [aws_internet_gateway.main]
  tags          = merge(local.common_tags, { Name = "${local.prefix}-temporary-nat", Purpose = "temporary-bootstrap" })
}

resource "aws_route" "temporary_nat_egress" {
  for_each               = var.enable_temporary_nat ? local.private_subnets : {}
  route_table_id         = aws_route_table.private[each.key].id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.temporary[0].id
}

resource "aws_security_group" "alb" {
  name        = "${local.prefix}-sg-alb"
  description = "HTTP de Internet al ALB; salida solo al pool web."
  vpc_id      = aws_vpc.main.id
  ingress     = []
  egress      = []
  lifecycle {
    ignore_changes = [ingress, egress]
  }
  tags = merge(local.common_tags, { Name = "${local.prefix}-sg-alb", Purpose = "load-balancer" })
}

resource "aws_security_group" "web" {
  name        = "${local.prefix}-sg-web"
  description = "Web privada: entrada del ALB y de la VM VPN Azure."
  vpc_id      = aws_vpc.main.id
  ingress     = []
  egress      = []
  lifecycle {
    ignore_changes = [ingress, egress]
  }
  tags = merge(local.common_tags, { Name = "${local.prefix}-sg-web", Purpose = "web" })
}

resource "aws_security_group" "db" {
  name        = "${local.prefix}-sg-db"
  description = "PostgreSQL accessible only from Web and administration via VPN."
  vpc_id      = aws_vpc.main.id
  ingress     = []
  egress      = []
  lifecycle {
    ignore_changes = [ingress, egress]
  }
  tags = merge(local.common_tags, { Name = "${local.prefix}-sg-db", Purpose = "database" })
}

resource "aws_security_group" "vpn" {
  name        = "${local.prefix}-sg-vpn"
  description = "Peer WireGuard y salto SSH administrativo restringido."
  vpc_id      = aws_vpc.main.id
  ingress     = []
  egress      = []
  lifecycle {
    ignore_changes = [ingress, egress]
  }
  tags = merge(local.common_tags, { Name = "${local.prefix}-sg-vpn", Purpose = "wireguard" })
}

resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  security_group_id = aws_security_group.alb.id
  description       = "HTTP al ALB; redirige a HTTPS cuando hay un certificado ACM configurado."
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
}

resource "aws_vpc_security_group_ingress_rule" "alb_https" {
  count             = var.alb_certificate_arn == "" ? 0 : 1
  security_group_id = aws_security_group.alb.id
  description       = "HTTPS publico del ERP con certificado ACM."
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}

resource "aws_vpc_security_group_egress_rule" "alb_to_web" {
  security_group_id            = aws_security_group.alb.id
  description                  = "ALB al puerto HTTP de las EC2 web."
  referenced_security_group_id = aws_security_group.web.id
  ip_protocol                  = "tcp"
  from_port                    = 8080
  to_port                      = 8080
}

resource "aws_vpc_security_group_ingress_rule" "web_from_alb" {
  security_group_id            = aws_security_group.web.id
  description                  = "Solo el ALB puede alcanzar el servicio web."
  referenced_security_group_id = aws_security_group.alb.id
  ip_protocol                  = "tcp"
  from_port                    = 8080
  to_port                      = 8080
}

resource "aws_vpc_security_group_ingress_rule" "web_from_azure_vpn" {
  security_group_id = aws_security_group.web.id
  description       = "Prueba de seguimiento desde la VM VPN Azure."
  cidr_ipv4         = "${var.azure_vpn_private_ip}/32"
  ip_protocol       = "tcp"
  from_port         = 8080
  to_port           = 8080
}

resource "aws_vpc_security_group_ingress_rule" "web_from_azure_vnet" {
  security_group_id = aws_security_group.web.id
  description       = "Azure VNet access through WireGuard tunnel."
  cidr_ipv4         = var.azure_vpc_cidr
  ip_protocol       = "tcp"
  from_port         = 8080
  to_port           = 8080
}

resource "aws_vpc_security_group_ingress_rule" "web_from_azure_tunnel" {
  security_group_id = aws_security_group.web.id
  description       = "Azure WireGuard tunnel source for peer tests."
  cidr_ipv4         = "172.30.50.2/32"
  ip_protocol       = "tcp"
  from_port         = 8080
  to_port           = 8080
}

resource "aws_vpc_security_group_ingress_rule" "web_ssh_from_vpn" {
  security_group_id            = aws_security_group.web.id
  description                  = "Internal SSH only from AWS peer."
  referenced_security_group_id = aws_security_group.vpn.id
  ip_protocol                  = "tcp"
  from_port                    = 22
  to_port                      = 22
}

resource "aws_vpc_security_group_egress_rule" "web_to_db" {
  security_group_id            = aws_security_group.web.id
  description                  = "PostgreSQL desde las EC2 web."
  referenced_security_group_id = aws_security_group.db.id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
}

resource "aws_vpc_security_group_egress_rule" "web_dns_udp" {
  security_group_id = aws_security_group.web.id
  description       = "DNS resolution inside VPC."
  cidr_ipv4         = var.aws_vpc_cidr
  ip_protocol       = "udp"
  from_port         = 53
  to_port           = 53
}

resource "aws_vpc_security_group_egress_rule" "web_dns_tcp" {
  security_group_id = aws_security_group.web.id
  description       = "DNS TCP dentro de VPC."
  cidr_ipv4         = var.aws_vpc_cidr
  ip_protocol       = "tcp"
  from_port         = 53
  to_port           = 53
}

resource "aws_vpc_security_group_egress_rule" "web_http_bootstrap" {
  for_each          = toset(["80", "443"])
  security_group_id = aws_security_group.web.id
  description       = "Descarga de paquetes durante bootstrap temporal."
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = tonumber(each.value)
  to_port           = tonumber(each.value)
}

resource "aws_vpc_security_group_ingress_rule" "db_from_web" {
  security_group_id            = aws_security_group.db.id
  description                  = "PostgreSQL solo desde las EC2 web."
  referenced_security_group_id = aws_security_group.web.id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
}

resource "aws_vpc_security_group_ingress_rule" "db_ssh_from_vpn" {
  security_group_id            = aws_security_group.db.id
  description                  = "Internal SSH only from AWS peer."
  referenced_security_group_id = aws_security_group.vpn.id
  ip_protocol                  = "tcp"
  from_port                    = 22
  to_port                      = 22
}

resource "aws_vpc_security_group_egress_rule" "db_dns_udp" {
  security_group_id = aws_security_group.db.id
  description       = "DNS resolution inside VPC."
  cidr_ipv4         = var.aws_vpc_cidr
  ip_protocol       = "udp"
  from_port         = 53
  to_port           = 53
}

resource "aws_vpc_security_group_egress_rule" "db_http_bootstrap" {
  for_each          = toset(["80", "443"])
  security_group_id = aws_security_group.db.id
  description       = "Descarga de paquetes durante bootstrap temporal."
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = tonumber(each.value)
  to_port           = tonumber(each.value)
}

resource "aws_vpc_security_group_ingress_rule" "vpn_ssh_admin" {
  for_each = var.admin_public_cidr == "" ? {} : { admin = var.admin_public_cidr }

  security_group_id = aws_security_group.vpn.id
  description       = "SSH from administrative public IP /32."
  cidr_ipv4         = each.value
  ip_protocol       = "tcp"
  from_port         = 22
  to_port           = 22
}

resource "aws_vpc_security_group_ingress_rule" "vpn_wireguard_from_azure" {
  for_each = var.azure_peer_public_cidr == "" ? {} : { azure = var.azure_peer_public_cidr }

  security_group_id = aws_security_group.vpn.id
  description       = "WireGuard desde el peer Azure /32."
  cidr_ipv4         = each.value
  ip_protocol       = "udp"
  from_port         = 51820
  to_port           = 51820
}

resource "aws_vpc_security_group_egress_rule" "vpn_to_vpc" {
  security_group_id = aws_security_group.vpn.id
  description       = "Forwarding hacia redes privadas AWS."
  cidr_ipv4         = var.aws_vpc_cidr
  ip_protocol       = "-1"
}

resource "aws_vpc_security_group_egress_rule" "vpn_wireguard_to_azure" {
  for_each = var.azure_peer_public_cidr == "" ? {} : { azure = var.azure_peer_public_cidr }

  security_group_id = aws_security_group.vpn.id
  description       = "WireGuard hacia el peer Azure /32."
  cidr_ipv4         = each.value
  ip_protocol       = "udp"
  from_port         = 51820
  to_port           = 51820
}

resource "aws_vpc_security_group_egress_rule" "vpn_dns_udp" {
  security_group_id = aws_security_group.vpn.id
  description       = "DNS resolution inside VPC."
  cidr_ipv4         = var.aws_vpc_cidr
  ip_protocol       = "udp"
  from_port         = 53
  to_port           = 53
}

resource "aws_vpc_security_group_egress_rule" "vpn_http_bootstrap" {
  for_each          = toset(["80", "443"])
  security_group_id = aws_security_group.vpn.id
  description       = "Descarga de WireGuard durante bootstrap."
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = tonumber(each.value)
  to_port           = tonumber(each.value)
}

resource "aws_instance" "vpn" {
  ami                         = data.aws_ami.ubuntu_2404.id
  instance_type               = var.vpn_instance_type
  subnet_id                   = aws_subnet.this["public-a"].id
  private_ip                  = "10.10.1.10"
  vpc_security_group_ids      = [aws_security_group.vpn.id]
  associate_public_ip_address = true
  source_dest_check           = false
  key_name                    = local.key_name
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }
  user_data = templatefile("${path.module}/../../../scripts/aws-vpn-cloud-init.sh.tftpl", {
    azure_public_key = var.azure_wireguard_public_key
    azure_public_ip  = split("/", var.azure_peer_public_cidr)[0]
    ssh_public_key   = var.ssh_public_key
  })
  user_data_replace_on_change = true

  root_block_device {
    volume_size           = 16
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  tags = merge(local.common_tags, { Name = "${local.prefix}-vpn", Purpose = "wireguard" })
}

resource "aws_eip" "vpn" {
  count  = var.create_vpn_eip ? 1 : 0
  domain = "vpc"
  tags   = merge(local.common_tags, { Name = "${local.prefix}-vpn-eip", Purpose = "wireguard" })
}

resource "aws_eip_association" "vpn" {
  count         = var.create_vpn_eip ? 1 : 0
  allocation_id = aws_eip.vpn[0].id
  instance_id   = aws_instance.vpn.id
}

resource "aws_instance" "web" {
  for_each = {
    web-a = { subnet = "app-a", ip = "10.10.11.10" }
    web-b = { subnet = "app-b", ip = "10.10.12.10" }
  }

  ami                    = data.aws_ami.ubuntu_2404.id
  instance_type          = var.web_instance_type
  subnet_id              = aws_subnet.this[each.value.subnet].id
  private_ip             = each.value.ip
  vpc_security_group_ids = [aws_security_group.web.id]
  key_name               = local.key_name
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }
  user_data = templatefile("${path.module}/../../../scripts/aws-web-cloud-init.sh.tftpl", {
    erp_image = var.erp_image
  })
  user_data_replace_on_change = true

  root_block_device {
    volume_size           = 16
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  tags = merge(local.common_tags, { Name = "${local.prefix}-${each.key}", Purpose = "web" })

  # Ensure package installation in cloud-init starts only after the optional
  # bootstrap NAT and private default routes exist.
  depends_on = [
    aws_route_table_association.private,
    aws_route.temporary_nat_egress,
    aws_vpc_security_group_egress_rule.web_dns_tcp,
    aws_vpc_security_group_egress_rule.web_dns_udp,
    aws_vpc_security_group_egress_rule.web_http_bootstrap,
  ]
}

resource "aws_ebs_volume" "db_data" {
  availability_zone = aws_subnet.this["data-a"].availability_zone
  size              = 20
  type              = "gp3"
  encrypted         = true
  tags              = merge(local.common_tags, { Name = "${local.prefix}-db-data", Purpose = "database" })
}

resource "aws_instance" "db" {
  ami                    = data.aws_ami.ubuntu_2404.id
  instance_type          = var.db_instance_type
  subnet_id              = aws_subnet.this["data-a"].id
  private_ip             = var.db_private_ip
  vpc_security_group_ids = [aws_security_group.db.id]
  key_name               = local.key_name
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }
  user_data = templatefile("${path.module}/../../../scripts/aws-db-cloud-init.sh.tftpl", {
    db_private_ip = var.db_private_ip
  })
  user_data_replace_on_change = true

  # PostgreSQL's bootstrap is one-time initialization. Later script fixes must
  # not replace the database instance or detach its persistent data volume.
  lifecycle {
    ignore_changes = [user_data]
  }

  root_block_device {
    volume_size           = 16
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  tags = merge(local.common_tags, { Name = "${local.prefix}-db", Purpose = "database" })

  depends_on = [
    aws_route_table_association.private,
    aws_route.temporary_nat_egress,
    aws_vpc_security_group_egress_rule.db_dns_udp,
    aws_vpc_security_group_egress_rule.db_http_bootstrap,
  ]
}

resource "aws_volume_attachment" "db_data" {
  device_name = "/dev/sdf"
  volume_id   = aws_ebs_volume.db_data.id
  instance_id = aws_instance.db.id
}

resource "aws_route" "app_to_azure" {
  for_each               = local.app_subnets
  route_table_id         = aws_route_table.private[each.key].id
  destination_cidr_block = "10.20.0.0/16"
  network_interface_id   = aws_instance.vpn.primary_network_interface_id
}

resource "aws_route" "db_to_azure" {
  for_each               = var.route_db_to_azure ? local.db_subnet_names : {}
  route_table_id         = aws_route_table.private[each.key].id
  destination_cidr_block = "10.20.0.0/16"
  network_interface_id   = aws_instance.vpn.primary_network_interface_id
}

resource "aws_lb" "web" {
  name               = "${local.prefix}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = [aws_subnet.this["public-a"].id, aws_subnet.this["public-b"].id]
  tags               = merge(local.common_tags, { Name = "${local.prefix}-alb", Purpose = "web-entry" })
}

resource "aws_lb_target_group" "web" {
  name        = "${local.prefix}-web"
  port        = 8080
  protocol    = "HTTP"
  target_type = "instance"
  vpc_id      = aws_vpc.main.id

  health_check {
    enabled             = true
    protocol            = "HTTP"
    path                = "/api/health"
    port                = "traffic-port"
    matcher             = "200"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }

  tags = merge(local.common_tags, { Name = "${local.prefix}-web-targets", Purpose = "web" })
}

resource "aws_lb_target_group_attachment" "web" {
  for_each         = aws_instance.web
  target_group_arn = aws_lb_target_group.web.arn
  target_id        = each.value.id
  port             = 8080
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.web.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = var.alb_certificate_arn == "" ? "forward" : "redirect"
    target_group_arn = var.alb_certificate_arn == "" ? aws_lb_target_group.web.arn : null

    dynamic "redirect" {
      for_each = var.alb_certificate_arn == "" ? [] : [1]
      content {
        port        = "443"
        protocol    = "HTTPS"
        status_code = "HTTP_301"
      }
    }
  }
}

resource "aws_lb_listener" "https" {
  count             = var.alb_certificate_arn == "" ? 0 : 1
  load_balancer_arn = aws_lb.web.arn
  port              = 443
  protocol          = "HTTPS"
  certificate_arn   = var.alb_certificate_arn
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.web.arn
  }
}

resource "aws_s3_bucket" "backups" {
  count         = var.enable_aws_s3_backups ? 1 : 0
  bucket        = local.bucket_name
  force_destroy = false
  tags          = merge(local.common_tags, { Name = local.bucket_name, Purpose = "backup" })
}

resource "aws_s3_bucket_public_access_block" "backups" {
  count                   = var.enable_aws_s3_backups ? 1 : 0
  bucket                  = aws_s3_bucket.backups[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "backups" {
  count  = var.enable_aws_s3_backups ? 1 : 0
  bucket = aws_s3_bucket.backups[0].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "backups" {
  count  = var.enable_aws_s3_backups ? 1 : 0
  bucket = aws_s3_bucket.backups[0].id

  rule {
    id     = "expire-lab-backups"
    status = "Enabled"
    filter {}

    expiration {
      days = var.backup_retention_days
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}

resource "aws_s3_bucket_versioning" "backups" {
  count  = var.enable_aws_s3_backups && var.enable_s3_versioning ? 1 : 0
  bucket = aws_s3_bucket.backups[0].id

  versioning_configuration {
    status = "Enabled"
  }
}

locals {
  instance_ids = merge(
    { for name, instance in aws_instance.web : name => instance.id },
    { db = aws_instance.db.id, vpn = aws_instance.vpn.id }
  )
}

resource "aws_cloudwatch_metric_alarm" "instance_cpu" {
  for_each            = local.instance_ids
  alarm_name          = "${local.prefix}-${each.key}-cpu-high"
  alarm_description   = "CPU promedio mayor a 70% por cinco minutos en ${each.key}."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 300
  statistic           = "Average"
  threshold           = 70
  treat_missing_data  = "notBreaching"
  dimensions          = { InstanceId = each.value }
}

resource "aws_cloudwatch_metric_alarm" "alb_unhealthy" {
  alarm_name          = "${local.prefix}-alb-unhealthy-targets"
  alarm_description   = "At least one ALB target is unhealthy."
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "UnHealthyHostCount"
  namespace           = "AWS/ApplicationELB"
  period              = 60
  statistic           = "Maximum"
  threshold           = 1
  treat_missing_data  = "notBreaching"
  dimensions = {
    LoadBalancer = aws_lb.web.arn_suffix
    TargetGroup  = aws_lb_target_group.web.arn_suffix
  }
}

resource "aws_cloudwatch_dashboard" "main" {
  dashboard_name = "${local.prefix}-overview"
  dashboard_body = jsonencode({
    widgets = [
      {
        type = "metric", x = 0, y = 0, width = 12, height = 6,
        properties = {
          title  = "EC2 CPU utilization"
          region = var.aws_region
          view   = "timeSeries"
          stat   = "Average"
          period = 300
          metrics = concat(
            [["AWS/EC2", "CPUUtilization", "InstanceId", aws_instance.web["web-a"].id, { label = "web-a" }]],
            [["AWS/EC2", "CPUUtilization", "InstanceId", aws_instance.web["web-b"].id, { label = "web-b" }]],
            [["AWS/EC2", "CPUUtilization", "InstanceId", aws_instance.db.id, { label = "db" }]],
            [["AWS/EC2", "CPUUtilization", "InstanceId", aws_instance.vpn.id, { label = "vpn" }]]
          )
        }
      },
      {
        type = "metric", x = 0, y = 6, width = 12, height = 6,
        properties = {
          title  = "ALB target health"
          region = var.aws_region
          view   = "timeSeries"
          stat   = "Average"
          period = 60
          metrics = [
            ["AWS/ApplicationELB", "HealthyHostCount", "LoadBalancer", aws_lb.web.arn_suffix, "TargetGroup", aws_lb_target_group.web.arn_suffix],
            ["AWS/ApplicationELB", "UnHealthyHostCount", "LoadBalancer", aws_lb.web.arn_suffix, "TargetGroup", aws_lb_target_group.web.arn_suffix]
          ]
        }
      },
      {
        type = "metric", x = 0, y = 12, width = 12, height = 6,
        properties = {
          title  = "ALB requests"
          region = var.aws_region
          view   = "timeSeries"
          stat   = "Sum"
          period = 60
          metrics = [
            ["AWS/ApplicationELB", "RequestCount", "LoadBalancer", aws_lb.web.arn_suffix]
          ]
        }
      }
    ]
  })
}
