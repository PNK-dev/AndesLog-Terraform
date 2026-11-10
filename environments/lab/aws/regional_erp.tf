# EXPERIMENTAL warm standby. The HTTPS listener deliberately returns 503 for
# business traffic. No automatic promotion, DNS failover, or writer fencing is
# implemented here. Enable only after the image and runtime secret exist in DR.
locals {
  dr_erp_enabled = var.enable_aws_regional_dr && var.enable_dr_erp_compute
  dr_erp_zones   = local.dr_erp_enabled ? { a = 0, b = 1 } : {}
}

data "aws_ami" "dr_ubuntu" {
  provider    = aws.dr
  count       = local.dr_erp_enabled ? 1 : 0
  most_recent = true
  owners      = ["099720109477"]

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

resource "aws_subnet" "dr_public" {
  provider                = aws.dr
  for_each                = local.dr_erp_zones
  vpc_id                  = aws_vpc.dr[0].id
  cidr_block              = cidrsubnet(var.aws_dr_vpc_cidr, 8, 1 + each.value)
  availability_zone       = data.aws_availability_zones.dr[0].names[each.value]
  map_public_ip_on_launch = false
  tags                    = merge(local.common_tags, { Name = "${local.prefix}-dr-public-${each.key}", Purpose = "regional-erp-entry" })
}

resource "aws_subnet" "dr_app" {
  provider                = aws.dr
  for_each                = local.dr_erp_zones
  vpc_id                  = aws_vpc.dr[0].id
  cidr_block              = cidrsubnet(var.aws_dr_vpc_cidr, 8, 11 + each.value)
  availability_zone       = data.aws_availability_zones.dr[0].names[each.value]
  map_public_ip_on_launch = false
  tags                    = merge(local.common_tags, { Name = "${local.prefix}-dr-app-${each.key}", Purpose = "regional-erp-standby" })
}

resource "aws_internet_gateway" "dr_erp" {
  provider = aws.dr
  count    = local.dr_erp_enabled ? 1 : 0
  vpc_id   = aws_vpc.dr[0].id
  tags     = merge(local.common_tags, { Name = "${local.prefix}-dr-igw", Purpose = "regional-erp-entry" })
}

resource "aws_route_table" "dr_public" {
  provider = aws.dr
  count    = local.dr_erp_enabled ? 1 : 0
  vpc_id   = aws_vpc.dr[0].id
  tags     = merge(local.common_tags, { Name = "${local.prefix}-dr-public", Purpose = "regional-erp-entry" })
}

resource "aws_route" "dr_public_default" {
  provider               = aws.dr
  count                  = local.dr_erp_enabled ? 1 : 0
  route_table_id         = aws_route_table.dr_public[0].id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.dr_erp[0].id
}

resource "aws_route_table_association" "dr_public" {
  provider       = aws.dr
  for_each       = local.dr_erp_zones
  subnet_id      = aws_subnet.dr_public[each.key].id
  route_table_id = aws_route_table.dr_public[0].id
}

resource "aws_eip" "dr_nat" {
  provider = aws.dr
  for_each = local.dr_erp_zones
  domain   = "vpc"
  tags     = merge(local.common_tags, { Name = "${local.prefix}-dr-nat-${each.key}", Purpose = "regional-private-egress" })
}

resource "aws_nat_gateway" "dr_erp" {
  provider      = aws.dr
  for_each      = local.dr_erp_zones
  allocation_id = aws_eip.dr_nat[each.key].id
  subnet_id     = aws_subnet.dr_public[each.key].id
  depends_on    = [aws_internet_gateway.dr_erp]
  tags          = merge(local.common_tags, { Name = "${local.prefix}-dr-nat-${each.key}", Purpose = "regional-private-egress" })
}

resource "aws_route_table" "dr_app" {
  provider = aws.dr
  for_each = local.dr_erp_zones
  vpc_id   = aws_vpc.dr[0].id
  tags     = merge(local.common_tags, { Name = "${local.prefix}-dr-app-${each.key}", Purpose = "regional-private-egress" })
}

resource "aws_route_table_association" "dr_app" {
  provider       = aws.dr
  for_each       = local.dr_erp_zones
  subnet_id      = aws_subnet.dr_app[each.key].id
  route_table_id = aws_route_table.dr_app[each.key].id
}

resource "aws_route" "dr_app_default" {
  provider               = aws.dr
  for_each               = local.dr_erp_zones
  route_table_id         = aws_route_table.dr_app[each.key].id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.dr_erp[each.key].id
}

resource "aws_security_group" "dr_alb" {
  provider    = aws.dr
  count       = local.dr_erp_enabled ? 1 : 0
  name        = "${local.prefix}-dr-alb"
  description = "HTTPS entry for the regional standby ERP."
  vpc_id      = aws_vpc.dr[0].id
  ingress     = []
  egress      = []
  lifecycle { ignore_changes = [ingress, egress] }
  tags = merge(local.common_tags, { Purpose = "regional-erp-entry" })
}

resource "aws_security_group" "dr_web" {
  provider    = aws.dr
  count       = local.dr_erp_enabled ? 1 : 0
  name        = "${local.prefix}-dr-web"
  description = "Private regional standby ERP nodes."
  vpc_id      = aws_vpc.dr[0].id
  ingress     = []
  egress      = []
  lifecycle { ignore_changes = [ingress, egress] }
  tags = merge(local.common_tags, { Purpose = "regional-erp-standby" })
}

resource "aws_vpc_security_group_ingress_rule" "dr_alb_https" {
  provider          = aws.dr
  count             = local.dr_erp_enabled ? 1 : 0
  security_group_id = aws_security_group.dr_alb[0].id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  description       = "Public HTTPS; business traffic is blocked until a controlled failover."
}

resource "aws_vpc_security_group_egress_rule" "dr_alb_to_web" {
  provider                     = aws.dr
  count                        = local.dr_erp_enabled ? 1 : 0
  security_group_id            = aws_security_group.dr_alb[0].id
  referenced_security_group_id = aws_security_group.dr_web[0].id
  ip_protocol                  = "tcp"
  from_port                    = 8080
  to_port                      = 8080
}

resource "aws_vpc_security_group_ingress_rule" "dr_web_from_alb" {
  provider                     = aws.dr
  count                        = local.dr_erp_enabled ? 1 : 0
  security_group_id            = aws_security_group.dr_web[0].id
  referenced_security_group_id = aws_security_group.dr_alb[0].id
  ip_protocol                  = "tcp"
  from_port                    = 8080
  to_port                      = 8080
}

resource "aws_vpc_security_group_egress_rule" "dr_web_to_db" {
  provider                     = aws.dr
  count                        = local.dr_erp_enabled ? 1 : 0
  security_group_id            = aws_security_group.dr_web[0].id
  referenced_security_group_id = aws_security_group.dr_database[0].id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
}

resource "aws_vpc_security_group_ingress_rule" "dr_database_from_web" {
  provider                     = aws.dr
  count                        = local.dr_erp_enabled ? 1 : 0
  security_group_id            = aws_security_group.dr_database[0].id
  referenced_security_group_id = aws_security_group.dr_web[0].id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
}

resource "aws_vpc_security_group_egress_rule" "dr_web_bootstrap" {
  provider          = aws.dr
  for_each          = local.dr_erp_enabled ? toset(["80", "443"]) : toset([])
  security_group_id = aws_security_group.dr_web[0].id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = tonumber(each.key)
  to_port           = tonumber(each.key)
  description       = "Package, image and service API access through zonal NAT."
}

resource "aws_vpc_security_group_egress_rule" "dr_web_dns" {
  provider          = aws.dr
  for_each          = local.dr_erp_enabled ? toset(["tcp", "udp"]) : toset([])
  security_group_id = aws_security_group.dr_web[0].id
  cidr_ipv4         = var.aws_dr_vpc_cidr
  ip_protocol       = each.key
  from_port         = 53
  to_port           = 53
}

resource "aws_lb" "dr_erp" {
  provider           = aws.dr
  count              = local.dr_erp_enabled ? 1 : 0
  name               = "${local.prefix}-dr-alb"
  load_balancer_type = "application"
  internal           = false
  security_groups    = [aws_security_group.dr_alb[0].id]
  subnets            = [for subnet in aws_subnet.dr_public : subnet.id]
  tags               = merge(local.common_tags, { Purpose = "regional-erp-entry" })

  lifecycle {
    precondition {
      condition = try(
        split(":", var.dr_alb_certificate_arn)[3] == var.aws_dr_region &&
        split(":", var.dr_alb_certificate_arn)[4] == data.aws_caller_identity.current.account_id,
        false
      )
      error_message = "La entrada DR requiere un certificado ACM de la cuenta y región secundarias."
    }
  }
}

resource "aws_lb_target_group" "dr_erp" {
  provider    = aws.dr
  count       = local.dr_erp_enabled ? 1 : 0
  name        = "${local.prefix}-dr-web"
  vpc_id      = aws_vpc.dr[0].id
  port        = 8080
  protocol    = "HTTP"
  target_type = "instance"
  health_check {
    path                = "/api/health/live"
    matcher             = "200"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }
  tags = merge(local.common_tags, { Purpose = "regional-erp-standby" })
}

resource "aws_lb_listener" "dr_https" {
  provider          = aws.dr
  count             = local.dr_erp_enabled ? 1 : 0
  load_balancer_arn = aws_lb.dr_erp[0].arn
  port              = 443
  protocol          = "HTTPS"
  certificate_arn   = var.dr_alb_certificate_arn
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  default_action {
    type = "fixed-response"
    fixed_response {
      content_type = "text/plain"
      message_body = "Regional standby; service is not active."
      status_code  = "503"
    }
  }
}

resource "aws_lb_listener_rule" "dr_health" {
  provider     = aws.dr
  count        = local.dr_erp_enabled ? 1 : 0
  listener_arn = aws_lb_listener.dr_https[0].arn
  priority     = 100
  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.dr_erp[0].arn
  }
  condition {
    # Liveness only: a successful readiness signal does not prove fencing,
    # complete data or successful business writes; standby remains blocked.
    path_pattern { values = ["/api/health/live"] }
  }
}

resource "aws_launch_template" "dr_erp" {
  provider               = aws.dr
  count                  = local.dr_erp_enabled ? 1 : 0
  name_prefix            = "${local.prefix}-dr-web-"
  image_id               = data.aws_ami.dr_ubuntu[0].id
  instance_type          = var.web_instance_type
  vpc_security_group_ids = [aws_security_group.dr_web[0].id]

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
    aws_region                 = var.aws_dr_region
    ecr_registry               = split("/", aws_ecr_repository.dr_erp[0].repository_url)[0]
    erp_image                  = "${aws_ecr_repository.dr_erp[0].repository_url}:${var.erp_image_tag}"
    erp_runtime_secret_arn     = replace(aws_secretsmanager_secret.erp_runtime.arn, ":${var.aws_region}:", ":${var.aws_dr_region}:")
    enable_erp_integration     = false # A standby must not deliver outbox events before controlled promotion.
    rds_ca_bundle_url          = "https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem"
    dump_script_b64            = base64encode(file("${path.module}/../../../scripts/dump-rds.sh"))
    prepare_runtime_script_b64 = base64encode(file("${path.module}/../../../scripts/prepare-erp-runtime.py"))
    database_host_override     = aws_db_instance.dr_replica[0].address
  }))
  tag_specifications {
    resource_type = "instance"
    tags          = merge(local.common_tags, { Name = "${local.prefix}-dr-web", Purpose = "regional-erp-standby" })
  }
  tag_specifications {
    resource_type = "volume"
    tags          = merge(local.common_tags, { Purpose = "regional-erp-standby" })
  }
  depends_on = [aws_route.dr_app_default, aws_vpc_security_group_egress_rule.dr_web_bootstrap, aws_vpc_security_group_egress_rule.dr_web_dns]
}

resource "aws_autoscaling_group" "dr_erp" {
  provider                  = aws.dr
  count                     = local.dr_erp_enabled ? 1 : 0
  name                      = "${local.prefix}-dr-web"
  min_size                  = 2
  desired_capacity          = 2
  max_size                  = max(2, var.web_max_size)
  vpc_zone_identifier       = [for subnet in aws_subnet.dr_app : subnet.id]
  target_group_arns         = [aws_lb_target_group.dr_erp[0].arn]
  health_check_type         = "ELB"
  health_check_grace_period = 900
  wait_for_capacity_timeout = "20m"
  enabled_metrics = [
    "GroupDesiredCapacity",
    "GroupInServiceInstances",
    "GroupMinSize",
    "GroupMaxSize",
    "GroupTotalInstances"
  ]
  launch_template {
    id      = aws_launch_template.dr_erp[0].id
    version = aws_launch_template.dr_erp[0].latest_version
  }
  depends_on = [aws_lb_listener_rule.dr_health]
}

resource "aws_autoscaling_policy" "dr_erp_cpu" {
  provider                  = aws.dr
  count                     = local.dr_erp_enabled ? 1 : 0
  name                      = "${local.prefix}-dr-web-cpu"
  autoscaling_group_name    = aws_autoscaling_group.dr_erp[0].name
  policy_type               = "TargetTrackingScaling"
  estimated_instance_warmup = 900
  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }
    target_value = 60
  }
}

resource "aws_cloudwatch_metric_alarm" "dr_erp_targets" {
  provider            = aws.dr
  count               = local.dr_erp_enabled ? 1 : 0
  alarm_name          = "${local.prefix}-dr-web-healthy-targets"
  alarm_description   = "At least one ALB node reports fewer than two healthy standby targets."
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 2
  datapoints_to_alarm = 2
  metric_name         = "HealthyHostCount"
  namespace           = "AWS/ApplicationELB"
  period              = 60
  statistic           = "Minimum"
  threshold           = 2
  treat_missing_data  = "breaching"
  dimensions = {
    LoadBalancer = aws_lb.dr_erp[0].arn_suffix
    TargetGroup  = aws_lb_target_group.dr_erp[0].arn_suffix
  }
  alarm_actions = var.notification_email == "" ? [] : [aws_sns_topic.dr_alarm_email[0].arn]
  ok_actions    = var.notification_email == "" ? [] : [aws_sns_topic.dr_alarm_email[0].arn]
  tags          = merge(local.common_tags, { Purpose = "regional-erp-standby-alerts" })
}

resource "aws_cloudwatch_metric_alarm" "dr_erp_unhealthy" {
  provider            = aws.dr
  count               = local.dr_erp_enabled ? 1 : 0
  alarm_name          = "${local.prefix}-dr-web-unhealthy-targets"
  alarm_description   = "Every ALB node reports at least one unhealthy standby target."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  datapoints_to_alarm = 2
  metric_name         = "UnHealthyHostCount"
  namespace           = "AWS/ApplicationELB"
  period              = 60
  statistic           = "Minimum"
  threshold           = 0
  treat_missing_data  = "notBreaching"
  dimensions = {
    LoadBalancer = aws_lb.dr_erp[0].arn_suffix
    TargetGroup  = aws_lb_target_group.dr_erp[0].arn_suffix
  }
  alarm_actions = var.notification_email == "" ? [] : [aws_sns_topic.dr_alarm_email[0].arn]
  ok_actions    = var.notification_email == "" ? [] : [aws_sns_topic.dr_alarm_email[0].arn]
  tags          = merge(local.common_tags, { Purpose = "regional-erp-standby-alerts" })
}

output "dr_erp_alb_dns_name" {
  description = "DNS del balanceador DR experimental, con tráfico de negocio bloqueado."
  value       = local.dr_erp_enabled ? aws_lb.dr_erp[0].dns_name : ""
}

output "dr_erp_compute_enabled" {
  description = "Indica si Terraform administra la flota secundaria experimental."
  value       = local.dr_erp_enabled
}

output "dr_erp_certificate_arn" {
  description = "Certificado regional asociado al standby experimental, o vacío si está deshabilitado."
  value       = local.dr_erp_enabled ? var.dr_alb_certificate_arn : ""
}
