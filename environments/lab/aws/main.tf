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
    public-a = { cidr = "10.10.1.0/24", az_index = 0, public = true, purpose = "alb" }
    public-b = { cidr = "10.10.2.0/24", az_index = 1, public = true, purpose = "alb" }
    app-a    = { cidr = "10.10.11.0/24", az_index = 0, public = false, purpose = "web" }
    app-b    = { cidr = "10.10.12.0/24", az_index = 1, public = false, purpose = "web" }
    data-a   = { cidr = "10.10.21.0/24", az_index = 0, public = false, purpose = "database" }
    data-b   = { cidr = "10.10.22.0/24", az_index = 1, public = false, purpose = "database" }
  }

  public_subnets  = { for name, cfg in local.subnet_definitions : name => cfg if cfg.public }
  private_subnets = { for name, cfg in local.subnet_definitions : name => cfg if !cfg.public }
  app_subnets = {
    for name, cfg in local.subnet_definitions : name => merge(cfg, {
      nat_subnet = "public-${substr(name, 4, 1)}"
    }) if startswith(name, "app-")
  }
  db_subnet_names = { for name, cfg in local.subnet_definitions : name => cfg if startswith(name, "data-") }
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

data "aws_rds_orderable_db_instance" "main" {
  engine                       = "postgres"
  engine_version               = var.rds_engine_version
  instance_class               = var.rds_instance_class
  storage_type                 = "gp3"
  supports_multi_az            = true
  supports_storage_encryption  = true
  supports_storage_autoscaling = true
  vpc                          = true
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
  for_each = var.enable_temporary_nat ? local.public_subnets : {}
  domain   = "vpc"
  tags     = merge(local.common_tags, { Name = "${local.prefix}-${each.key}-nat-eip", Purpose = "private-egress" })
}

resource "aws_nat_gateway" "temporary" {
  for_each      = var.enable_temporary_nat ? local.public_subnets : {}
  allocation_id = aws_eip.temporary_nat[each.key].id
  subnet_id     = aws_subnet.this[each.key].id
  depends_on    = [aws_internet_gateway.main]
  tags          = merge(local.common_tags, { Name = "${local.prefix}-${each.key}-nat", Purpose = "private-egress" })
}

resource "aws_route" "temporary_nat_egress" {
  # Only application subnets need outbound access for image pulls and self-replacement.
  # Database subnets remain isolated and have no Internet default route.
  for_each               = var.enable_temporary_nat ? local.app_subnets : {}
  route_table_id         = aws_route_table.private[each.key].id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.temporary[each.value.nat_subnet].id
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
  description = "Web privada: entrada desde ALB y red corporativa por Site-to-Site VPN."
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
  description = "RDS PostgreSQL is private and accepts connections only from the ERP security group."
  vpc_id      = aws_vpc.main.id
  ingress     = []
  egress      = []
  lifecycle {
    ignore_changes = [ingress, egress]
  }
  tags = merge(local.common_tags, { Name = "${local.prefix}-sg-db", Purpose = "database" })
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

resource "aws_vpc_security_group_ingress_rule" "web_from_azure_vnet" {
  for_each          = var.enable_intercloud_vpn ? { azure = var.azure_vpc_cidr } : {}
  security_group_id = aws_security_group.web.id
  description       = "Acceso corporativo desde Azure mediante Site-to-Site VPN."
  cidr_ipv4         = each.value
  ip_protocol       = "tcp"
  from_port         = 8080
  to_port           = 8080
}

resource "aws_vpc_security_group_ingress_rule" "web_from_azure_p2s" {
  for_each          = var.enable_intercloud_vpn ? { clients = var.azure_p2s_client_cidr } : {}
  security_group_id = aws_security_group.web.id
  description       = "Acceso a ERP desde el pool P2S de usuarios Azure mediante IPsec."
  cidr_ipv4         = each.value
  ip_protocol       = "tcp"
  from_port         = 8080
  to_port           = 8080
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

resource "aws_security_group" "bootstrap" {
  name        = "${local.prefix}-sg-bootstrap"
  description = "Acceso SSH temporal al bootstrap solo desde la IP administrativa autorizada."
  vpc_id      = aws_vpc.main.id
  ingress     = []
  egress      = []
  lifecycle { ignore_changes = [ingress, egress] }
  tags = merge(local.common_tags, { Name = "${local.prefix}-sg-bootstrap", Purpose = "temporary-bootstrap" })
}

resource "aws_vpc_security_group_ingress_rule" "bootstrap_ssh_admin" {
  for_each          = !var.bootstrap_instance_enabled || var.admin_public_cidr == "" ? {} : { admin = var.admin_public_cidr }
  security_group_id = aws_security_group.bootstrap.id
  description       = "SSH temporal desde la IP administrativa /32."
  cidr_ipv4         = each.value
  ip_protocol       = "tcp"
  from_port         = 22
  to_port           = 22
}

resource "aws_ecr_repository" "erp" {
  name                 = "${local.prefix}-erp"
  image_tag_mutability = "IMMUTABLE"
  force_delete         = true # Lab-only cleanup; production repositories should retain images.

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }

  tags = merge(local.common_tags, { Name = "${local.prefix}-erp", Purpose = "container-registry" })
}

resource "aws_ecr_lifecycle_policy" "erp" {
  repository = aws_ecr_repository.erp.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep only the three newest lab releases."
      selection = {
        tagStatus     = "tagged"
        tagPrefixList = ["img-"]
        countType     = "imageCountMoreThan"
        countNumber   = 3
      }
      action = { type = "expire" }
    }]
  })
}

resource "aws_secretsmanager_secret" "erp_runtime" {
  name                    = "${local.prefix}/erp/runtime"
  description             = "Runtime environment for AndesLog ERP nodes; value is populated by scripts/lab.ps1."
  recovery_window_in_days = 0 # Lab-only: allow explicit Destroy to remove the secret immediately.
  tags                    = merge(local.common_tags, { Purpose = "erp-runtime-secret" })

  # The replica carries the same values, including the PRIMARY database URL.
  # A regional application must explicitly select its own database endpoint.
  dynamic "replica" {
    for_each = var.enable_dr_runtime_secret_replication ? [var.aws_dr_region] : []
    content {
      region = replica.value
    }
  }

  lifecycle {
    precondition {
      condition     = !var.enable_dr_runtime_secret_replication || var.aws_dr_region != var.aws_region
      error_message = "El secreto de recuperación debe estar en otra región AWS."
    }
  }
}

data "aws_iam_instance_profile" "web_existing" {
  count = var.web_instance_profile_name == "" ? 0 : 1
  name  = var.web_instance_profile_name
}

resource "aws_iam_role" "web" {
  count = var.web_instance_profile_name == "" ? 1 : 0
  name  = "${local.prefix}-web-instance"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
  tags = merge(local.common_tags, { Purpose = "web-instance-role" })
}

resource "aws_iam_role_policy" "web_runtime" {
  count = var.web_instance_profile_name == "" ? 1 : 0
  name  = "${local.prefix}-web-runtime-read"
  role  = aws_iam_role.web[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:BatchGetImage",
          "ecr:GetDownloadUrlForLayer"
        ]
        Resource = concat(
          [aws_ecr_repository.erp.arn],
          var.enable_aws_regional_dr ? [aws_ecr_repository.dr_erp[0].arn] : []
        )
      },
      {
        Effect = "Allow"
        Action = ["secretsmanager:GetSecretValue"]
        Resource = concat(
          [aws_secretsmanager_secret.erp_runtime.arn],
          var.enable_dr_runtime_secret_replication ? [replace(aws_secretsmanager_secret.erp_runtime.arn, ":${var.aws_region}:", ":${var.aws_dr_region}:")] : []
        )
      }
    ]
  })
}

resource "aws_iam_instance_profile" "web" {
  count = var.web_instance_profile_name == "" ? 1 : 0
  name  = "${local.prefix}-web-instance"
  role  = aws_iam_role.web[0].name
  tags  = merge(local.common_tags, { Purpose = "web-instance-profile" })
}

resource "aws_launch_template" "web" {
  name_prefix   = "${local.prefix}-web-"
  image_id      = data.aws_ami.ubuntu_2404.id
  instance_type = var.web_instance_type
  key_name      = local.key_name

  vpc_security_group_ids = [aws_security_group.web.id]

  iam_instance_profile {
    name = var.web_instance_profile_name != "" ? data.aws_iam_instance_profile.web_existing[0].name : aws_iam_instance_profile.web[0].name
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  block_device_mappings {
    device_name = "/dev/sda1"
    ebs {
      volume_size           = 16
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }

  user_data = base64encode(templatefile("${path.module}/../../../scripts/aws-web-cloud-init.sh.tftpl", {
    aws_region                 = var.aws_region
    ecr_registry               = split("/", aws_ecr_repository.erp.repository_url)[0]
    erp_image                  = "${aws_ecr_repository.erp.repository_url}:${var.erp_image_tag}"
    erp_runtime_secret_arn     = aws_secretsmanager_secret.erp_runtime.arn
    enable_erp_integration     = var.enable_erp_integration
    rds_ca_bundle_url          = "https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem"
    dump_script_b64            = base64encode(file("${path.module}/../../../scripts/dump-rds.sh"))
    prepare_runtime_script_b64 = base64encode(file("${path.module}/../../../scripts/prepare-erp-runtime.py"))
    database_host_override     = ""
  }))

  tag_specifications {
    resource_type = "instance"
    tags = merge(local.common_tags, {
      Name    = "${local.prefix}-web-asg"
      Purpose = "web"
    })
  }

  tag_specifications {
    resource_type = "volume"
    tags          = merge(local.common_tags, { Purpose = "web-root-volume" })
  }

  depends_on = [
    aws_route.temporary_nat_egress,
    aws_vpc_security_group_egress_rule.web_dns_tcp,
    aws_vpc_security_group_egress_rule.web_dns_udp,
    aws_vpc_security_group_egress_rule.web_http_bootstrap,
  ]
}

resource "aws_autoscaling_group" "web" {
  name                      = "${local.prefix}-web-asg"
  min_size                  = var.web_min_size
  desired_capacity          = var.web_desired_capacity
  max_size                  = var.web_max_size
  vpc_zone_identifier       = [for name in keys(local.app_subnets) : aws_subnet.this[name].id]
  target_group_arns         = [aws_lb_target_group.web.arn]
  health_check_type         = "ELB"
  health_check_grace_period = 900
  wait_for_capacity_timeout = "20m"
  force_delete              = false
  enabled_metrics = [
    "GroupDesiredCapacity",
    "GroupInServiceInstances",
    "GroupMinSize",
    "GroupMaxSize",
    "GroupTotalInstances"
  ]

  launch_template {
    id      = aws_launch_template.web.id
    version = aws_launch_template.web.latest_version
  }

  dynamic "instance_refresh" {
    for_each = var.enable_instance_refresh ? [1] : []
    content {
      strategy = "Rolling"
      preferences {
        min_healthy_percentage = 100
        max_healthy_percentage = 150
        instance_warmup        = 300
        auto_rollback          = true
      }
    }
  }

  tag {
    key                 = "Name"
    value               = "${local.prefix}-web-asg"
    propagate_at_launch = true
  }
  tag {
    key                 = "Project"
    value               = "AndesLog"
    propagate_at_launch = true
  }
  tag {
    key                 = "Environment"
    value               = var.environment
    propagate_at_launch = true
  }
  tag {
    key                 = "ManagedBy"
    value               = "Terraform"
    propagate_at_launch = true
  }
  tag {
    key                 = "Owner"
    value               = var.owner
    propagate_at_launch = true
  }
  tag {
    key                 = "CostCenter"
    value               = "academic"
    propagate_at_launch = true
  }
}

resource "aws_autoscaling_policy" "web_cpu" {
  name                      = "${local.prefix}-web-cpu-target"
  autoscaling_group_name    = aws_autoscaling_group.web.name
  policy_type               = "TargetTrackingScaling"
  estimated_instance_warmup = 300
  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }
    target_value = 60
  }
}

resource "aws_instance" "bootstrap" {
  count                       = var.bootstrap_instance_enabled ? 1 : 0
  ami                         = data.aws_ami.ubuntu_2404.id
  instance_type               = var.web_instance_type
  subnet_id                   = aws_subnet.this["public-a"].id
  vpc_security_group_ids      = [aws_security_group.web.id, aws_security_group.bootstrap.id]
  associate_public_ip_address = true
  key_name                    = local.key_name

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  user_data                   = file("${path.module}/../../../scripts/aws-bootstrap-cloud-init.sh.tftpl")
  user_data_replace_on_change = true

  root_block_device {
    volume_size           = 16
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  tags = merge(local.common_tags, { Name = "${local.prefix}-bootstrap", Purpose = "temporary-database-bootstrap" })

  depends_on = [
    aws_route.temporary_nat_egress,
    aws_vpc_security_group_egress_rule.web_dns_tcp,
    aws_vpc_security_group_egress_rule.web_dns_udp,
    aws_vpc_security_group_egress_rule.web_http_bootstrap,
  ]
}

resource "aws_db_subnet_group" "main" {
  name        = "${local.prefix}-db-subnets"
  subnet_ids  = [for name in keys(local.db_subnet_names) : aws_subnet.this[name].id]
  description = "Subredes privadas en dos zonas para PostgreSQL Multi-AZ."
  tags        = merge(local.common_tags, { Name = "${local.prefix}-db-subnets", Purpose = "database" })
}

resource "aws_db_instance" "main" {
  identifier                      = "${local.prefix}-postgres"
  engine                          = "postgres"
  engine_version                  = data.aws_rds_orderable_db_instance.main.engine_version
  instance_class                  = var.rds_instance_class
  db_name                         = "andeslog"
  username                        = "andeslog_master"
  manage_master_user_password     = var.rds_external_master_secret_arn == "" ? true : null
  password_wo                     = var.rds_external_master_secret_arn == "" ? null : var.rds_master_password
  password_wo_version             = var.rds_external_master_secret_arn == "" ? null : 1
  allocated_storage               = 20
  max_allocated_storage           = 100
  storage_type                    = "gp3"
  storage_encrypted               = true
  multi_az                        = true
  publicly_accessible             = false
  db_subnet_group_name            = aws_db_subnet_group.main.name
  vpc_security_group_ids          = [aws_security_group.db.id]
  backup_retention_period         = var.rds_backup_retention_days == null ? var.backup_retention_days : var.rds_backup_retention_days
  auto_minor_version_upgrade      = true
  copy_tags_to_snapshot           = true
  deletion_protection             = var.rds_deletion_protection
  skip_final_snapshot             = var.rds_skip_final_snapshot
  final_snapshot_identifier       = var.rds_skip_final_snapshot ? null : var.rds_final_snapshot_identifier
  enabled_cloudwatch_logs_exports = ["postgresql", "upgrade"]
  apply_immediately               = false

  lifecycle {
    precondition {
      condition     = (var.rds_backup_retention_days == null ? var.backup_retention_days : var.rds_backup_retention_days) <= 35
      error_message = "RDS admite hasta 35 días: define rds_backup_retention_days si la retención S3 es mayor."
    }
    precondition {
      condition = (var.rds_external_master_secret_arn == "" && var.rds_external_rotation_lambda_arn == "") || (
        var.rds_external_master_secret_arn != "" && var.rds_external_rotation_lambda_arn != "" &&
        try(split(":", var.rds_external_master_secret_arn)[3] == var.aws_region && split(":", var.rds_external_master_secret_arn)[4] == data.aws_caller_identity.current.account_id, false) &&
        try(split(":", var.rds_external_rotation_lambda_arn)[3] == var.aws_region && split(":", var.rds_external_rotation_lambda_arn)[4] == data.aws_caller_identity.current.account_id, false)
      )
      error_message = "El secreto externo y su Lambda de rotación deben estar ambos en la región y cuenta AWS primarias, o ambos deben quedar vacíos."
    }
  }

  tags = merge(local.common_tags, { Name = "${local.prefix}-postgres", Purpose = "database" })
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
    enabled  = true
    protocol = "HTTP"
    # Liveness controls instance replacement. Database readiness is monitored
    # separately so a database outage does not make the ASG churn every web node.
    path                = "/api/health/live"
    port                = "traffic-port"
    matcher             = "200"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }

  tags = merge(local.common_tags, { Name = "${local.prefix}-web-targets", Purpose = "web" })
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

  lifecycle {
    precondition {
      condition = try(
        split(":", var.alb_certificate_arn)[3] == var.aws_region &&
        split(":", var.alb_certificate_arn)[4] == data.aws_caller_identity.current.account_id,
        false
      )
      error_message = "El listener HTTPS requiere un certificado ACM de la cuenta y región primarias."
    }
  }

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

resource "aws_sns_topic" "alarm_email" {
  count = var.notification_email == "" ? 0 : 1

  name = "${local.prefix}-alarm-email"
  tags = merge(local.common_tags, { Purpose = "alarm-notifications" })
}

resource "aws_sns_topic_subscription" "alarm_email" {
  count = var.notification_email == "" ? 0 : 1

  topic_arn = aws_sns_topic.alarm_email[0].arn
  protocol  = "email"
  endpoint  = var.notification_email
}

resource "aws_cloudwatch_metric_alarm" "web_asg_cpu" {
  alarm_name          = "${local.prefix}-web-asg-cpu-high"
  alarm_description   = "CPU promedio del Auto Scaling Group web superior a 70% durante cinco minutos."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 300
  statistic           = "Average"
  threshold           = 70
  treat_missing_data  = "notBreaching"
  dimensions          = { AutoScalingGroupName = aws_autoscaling_group.web.name }
  alarm_actions       = var.notification_email == "" ? [] : [aws_sns_topic.alarm_email[0].arn]
  ok_actions          = var.notification_email == "" ? [] : [aws_sns_topic.alarm_email[0].arn]
}

resource "aws_cloudwatch_metric_alarm" "web_asg_in_service" {
  alarm_name          = "${local.prefix}-web-asg-capacity-low"
  alarm_description   = "Menos de dos nodos del ERP están en servicio."
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 2
  metric_name         = "GroupInServiceInstances"
  namespace           = "AWS/AutoScaling"
  period              = 60
  statistic           = "Minimum"
  threshold           = 2
  treat_missing_data  = "breaching"
  dimensions          = { AutoScalingGroupName = aws_autoscaling_group.web.name }
  alarm_actions       = var.notification_email == "" ? [] : [aws_sns_topic.alarm_email[0].arn]
  ok_actions          = var.notification_email == "" ? [] : [aws_sns_topic.alarm_email[0].arn]
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
  alarm_actions = var.notification_email == "" ? [] : [aws_sns_topic.alarm_email[0].arn]
  ok_actions    = var.notification_email == "" ? [] : [aws_sns_topic.alarm_email[0].arn]
}

resource "aws_cloudwatch_metric_alarm" "rds_cpu" {
  alarm_name          = "${local.prefix}-postgres-cpu-high"
  alarm_description   = "CPU promedio de PostgreSQL superior a 70% durante cinco minutos."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "CPUUtilization"
  namespace           = "AWS/RDS"
  period              = 300
  statistic           = "Average"
  threshold           = 70
  treat_missing_data  = "notBreaching"
  dimensions          = { DBInstanceIdentifier = aws_db_instance.main.identifier }
  alarm_actions       = var.notification_email == "" ? [] : [aws_sns_topic.alarm_email[0].arn]
  ok_actions          = var.notification_email == "" ? [] : [aws_sns_topic.alarm_email[0].arn]
}

resource "aws_cloudwatch_metric_alarm" "rds_free_storage" {
  alarm_name          = "${local.prefix}-postgres-free-storage-low"
  alarm_description   = "El almacenamiento libre de PostgreSQL es inferior a 5 GiB."
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 1
  metric_name         = "FreeStorageSpace"
  namespace           = "AWS/RDS"
  period              = 300
  statistic           = "Minimum"
  threshold           = 5368709120
  treat_missing_data  = "notBreaching"
  dimensions          = { DBInstanceIdentifier = aws_db_instance.main.identifier }
  alarm_actions       = var.notification_email == "" ? [] : [aws_sns_topic.alarm_email[0].arn]
  ok_actions          = var.notification_email == "" ? [] : [aws_sns_topic.alarm_email[0].arn]
}

resource "aws_cloudwatch_metric_alarm" "vpn_tunnel_down" {
  for_each            = local.vpn_tunnel_metrics
  alarm_name          = "${local.prefix}-vpn-${each.key}-down"
  alarm_description   = "Site-to-Site VPN tunnel ${each.key} is down."
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 2
  metric_name         = "TunnelState"
  namespace           = "AWS/VPN"
  period              = 60
  statistic           = "Minimum"
  threshold           = 1
  treat_missing_data  = "breaching"
  dimensions = {
    VpnId           = each.value.vpn_id
    TunnelIpAddress = each.value.tunnel_address
  }
  alarm_actions = var.notification_email == "" ? [] : [aws_sns_topic.alarm_email[0].arn]
  ok_actions    = var.notification_email == "" ? [] : [aws_sns_topic.alarm_email[0].arn]
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
            [["AWS/EC2", "CPUUtilization", "AutoScalingGroupName", aws_autoscaling_group.web.name, { label = "web-asg-average" }]],
            [["AWS/AutoScaling", "GroupInServiceInstances", "AutoScalingGroupName", aws_autoscaling_group.web.name, { label = "web-in-service" }]],
            [["AWS/RDS", "CPUUtilization", "DBInstanceIdentifier", aws_db_instance.main.identifier, { label = "postgres" }]],
            [["AWS/RDS", "DatabaseConnections", "DBInstanceIdentifier", aws_db_instance.main.identifier, { label = "postgres-connections" }]]
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
