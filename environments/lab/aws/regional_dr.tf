# The secondary region is deliberately opt-in until the primary credential
# migration is implemented and verified. No primary database is replaced here.
data "aws_availability_zones" "dr" {
  provider = aws.dr
  count    = var.enable_aws_regional_dr ? 1 : 0
  state    = "available"

  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

data "aws_kms_alias" "dr_rds" {
  provider = aws.dr
  count    = var.enable_aws_regional_dr || var.enable_rds_backup_replication ? 1 : 0
  name     = var.aws_dr_kms_key_alias
}

# Independent regional registry: replication is intentionally not configured
# at account-wide registry scope. Images must be mirrored and verified before
# the recovery application can use them.
resource "aws_ecr_repository" "dr_erp" {
  provider             = aws.dr
  count                = var.enable_aws_regional_dr ? 1 : 0
  name                 = "${local.prefix}-erp"
  image_tag_mutability = "IMMUTABLE"
  force_delete         = var.dr_ecr_force_delete

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }

  lifecycle {
    precondition {
      condition     = var.aws_dr_region != var.aws_region
      error_message = "La región DR debe ser diferente de la región AWS primaria."
    }
  }

  tags = merge(local.common_tags, { Name = "${local.prefix}-erp-dr", Purpose = "regional-container-registry" })
}

resource "aws_vpc" "dr" {
  provider             = aws.dr
  count                = var.enable_aws_regional_dr ? 1 : 0
  cidr_block           = var.aws_dr_vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = merge(local.common_tags, { Name = "${local.prefix}-dr-vpc", Purpose = "regional-database-recovery" })

  lifecycle {
    precondition {
      condition     = var.aws_dr_region != var.aws_region
      error_message = "La región DR debe ser diferente de la región AWS primaria."
    }
  }
}

resource "aws_subnet" "dr_database" {
  provider          = aws.dr
  for_each          = var.enable_aws_regional_dr ? { a = 21, b = 22 } : {}
  vpc_id            = aws_vpc.dr[0].id
  cidr_block        = cidrsubnet(var.aws_dr_vpc_cidr, 8, each.value)
  availability_zone = data.aws_availability_zones.dr[0].names[each.key == "a" ? 0 : 1]
  tags              = merge(local.common_tags, { Name = "${local.prefix}-dr-db-${each.key}", Purpose = "regional-database-recovery" })
}

resource "aws_db_subnet_group" "dr" {
  provider    = aws.dr
  count       = var.enable_aws_regional_dr ? 1 : 0
  name        = "${local.prefix}-dr-db-subnets"
  description = "Private database subnets in two recovery-region availability zones."
  subnet_ids  = [for subnet in aws_subnet.dr_database : subnet.id]
  tags        = merge(local.common_tags, { Purpose = "regional-database-recovery" })
}

# No inbound rules are granted until a recovery application is deployed.
resource "aws_security_group" "dr_database" {
  provider    = aws.dr
  count       = var.enable_aws_regional_dr ? 1 : 0
  name        = "${local.prefix}-dr-db"
  description = "Isolated recovery PostgreSQL instance."
  vpc_id      = aws_vpc.dr[0].id
  tags        = merge(local.common_tags, { Purpose = "regional-database-recovery" })
}

resource "aws_db_instance" "dr_replica" {
  provider                   = aws.dr
  count                      = var.enable_aws_regional_dr ? 1 : 0
  identifier                 = "${local.prefix}-postgres-dr"
  replicate_source_db        = aws_db_instance.main.arn
  instance_class             = var.rds_instance_class
  multi_az                   = true
  publicly_accessible        = false
  db_subnet_group_name       = aws_db_subnet_group.dr[0].name
  vpc_security_group_ids     = [aws_security_group.dr_database[0].id]
  kms_key_id                 = data.aws_kms_alias.dr_rds[0].target_key_arn
  deletion_protection        = var.rds_deletion_protection
  skip_final_snapshot        = var.rds_skip_final_snapshot
  final_snapshot_identifier  = var.rds_skip_final_snapshot ? null : "${var.rds_final_snapshot_identifier}-dr"
  auto_minor_version_upgrade = true
  copy_tags_to_snapshot      = true
  tags                       = merge(local.common_tags, { Purpose = "regional-database-recovery" })

  lifecycle {
    precondition {
      condition     = var.rds_external_master_secret_arn != "" && var.rds_external_rotation_lambda_arn != ""
      error_message = "Para crear la réplica se requieren un secreto externo dedicado y una Lambda de rotación validada."
    }
    precondition {
      condition     = length(aws_db_instance.main.master_user_secret) == 0
      error_message = "RDS PostgreSQL no permite crear réplicas mientras RDS gestione la contraseña maestra."
    }
    precondition {
      condition     = length(data.aws_availability_zones.dr[0].names) >= 2
      error_message = "La región de recuperación requiere al menos dos zonas de disponibilidad."
    }
  }

  depends_on = [aws_secretsmanager_secret_rotation.rds_master]
}

resource "aws_sns_topic" "dr_alarm_email" {
  provider = aws.dr
  count    = var.enable_aws_regional_dr && var.notification_email != "" ? 1 : 0
  name     = "${local.prefix}-dr-alarm-email"
  tags     = merge(local.common_tags, { Purpose = "regional-database-recovery-alerts" })
}

resource "aws_sns_topic_subscription" "dr_alarm_email" {
  provider  = aws.dr
  count     = var.enable_aws_regional_dr && var.notification_email != "" ? 1 : 0
  topic_arn = aws_sns_topic.dr_alarm_email[0].arn
  protocol  = "email"
  endpoint  = var.notification_email
}

resource "aws_cloudwatch_metric_alarm" "dr_replica_lag" {
  provider            = aws.dr
  count               = var.enable_aws_regional_dr ? 1 : 0
  alarm_name          = "${local.prefix}-postgres-dr-replica-lag"
  alarm_description   = "Replica lag exceeded the five-minute recovery objective; idle PostgreSQL can report transient lag."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  datapoints_to_alarm = 2
  metric_name         = "ReplicaLag"
  namespace           = "AWS/RDS"
  period              = 60
  statistic           = "Maximum"
  threshold           = 300
  treat_missing_data  = "breaching"
  dimensions          = { DBInstanceIdentifier = aws_db_instance.dr_replica[0].identifier }
  alarm_actions       = var.notification_email == "" ? [] : [aws_sns_topic.dr_alarm_email[0].arn]
  ok_actions          = var.notification_email == "" ? [] : [aws_sns_topic.dr_alarm_email[0].arn]
  tags                = merge(local.common_tags, { Purpose = "regional-database-recovery" })
}

# ReplicaLag may be negative when the service cannot determine replication
# status; the high-lag alarm alone considers that value healthy.
resource "aws_cloudwatch_metric_alarm" "dr_replica_lag_unknown" {
  provider            = aws.dr
  count               = var.enable_aws_regional_dr ? 1 : 0
  alarm_name          = "${local.prefix}-postgres-dr-replica-lag-unknown"
  alarm_description   = "Replica lag is negative or missing; replication health cannot be established."
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 1
  datapoints_to_alarm = 1
  metric_name         = "ReplicaLag"
  namespace           = "AWS/RDS"
  period              = 60
  statistic           = "Minimum"
  threshold           = 0
  treat_missing_data  = "breaching"
  dimensions          = { DBInstanceIdentifier = aws_db_instance.dr_replica[0].identifier }
  alarm_actions       = var.notification_email == "" ? [] : [aws_sns_topic.dr_alarm_email[0].arn]
  ok_actions          = var.notification_email == "" ? [] : [aws_sns_topic.dr_alarm_email[0].arn]
  tags                = merge(local.common_tags, { Purpose = "regional-database-recovery" })
}

# Early warning is deliberately separate from the five-minute threshold. A
# quiet PostgreSQL replica can report apparent lag, so operators must verify.
resource "aws_cloudwatch_metric_alarm" "dr_replica_lag_warning" {
  provider            = aws.dr
  count               = var.enable_aws_regional_dr ? 1 : 0
  alarm_name          = "${local.prefix}-postgres-dr-replica-lag-warning"
  alarm_description   = "Replica lag reached three minutes; investigate early. Idle PostgreSQL can report apparent lag."
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  datapoints_to_alarm = 1
  metric_name         = "ReplicaLag"
  namespace           = "AWS/RDS"
  period              = 60
  statistic           = "Maximum"
  threshold           = 180
  treat_missing_data  = "breaching"
  dimensions          = { DBInstanceIdentifier = aws_db_instance.dr_replica[0].identifier }
  alarm_actions       = var.notification_email == "" ? [] : [aws_sns_topic.dr_alarm_email[0].arn]
  ok_actions          = var.notification_email == "" ? [] : [aws_sns_topic.dr_alarm_email[0].arn]
  tags                = merge(local.common_tags, { Purpose = "regional-database-recovery" })
}

# Notifications are best-effort and supplement rather than replace a data-plane probe.
resource "aws_db_event_subscription" "dr_replication" {
  provider         = aws.dr
  count            = var.enable_aws_regional_dr && var.notification_email != "" ? 1 : 0
  name             = "${local.prefix}-dr-replication-events"
  sns_topic        = aws_sns_topic.dr_alarm_email[0].arn
  source_type      = "db-instance"
  source_ids       = [aws_db_instance.dr_replica[0].identifier]
  event_categories = ["read replica", "failure"]
  enabled          = true
  tags             = merge(local.common_tags, { Purpose = "regional-database-recovery-alerts" })
}

output "dr_db_replica_identifier" {
  description = "Identificador de la réplica regional; vacío si está deshabilitada."
  value       = var.enable_aws_regional_dr ? aws_db_instance.dr_replica[0].identifier : ""
}

output "dr_db_replica_endpoint" {
  description = "Endpoint privado de solo lectura de la réplica regional, antes de su promoción."
  value       = var.enable_aws_regional_dr ? aws_db_instance.dr_replica[0].address : ""
}

output "dr_erp_repository_url" {
  description = "Registro ECR privado regional; vacío si DR está deshabilitado."
  value       = var.enable_aws_regional_dr ? aws_ecr_repository.dr_erp[0].repository_url : ""
}

output "dr_erp_runtime_secret_arn" {
  description = "ARN de la réplica regional del secreto ERP; contiene el endpoint primario hasta adaptar el runtime regional."
  value       = var.enable_dr_runtime_secret_replication ? replace(aws_secretsmanager_secret.erp_runtime.arn, ":${var.aws_region}:", ":${var.aws_dr_region}:") : ""
}

output "dr_erp_runtime_secret_replication_enabled" {
  description = "Indica si se ha solicitado la replicación regional del secreto de ejecución ERP."
  value       = var.enable_dr_runtime_secret_replication
}

output "aws_regional_dr_enabled" {
  description = "Indica si este estado incluye infraestructura AWS regional de recuperación."
  value       = var.enable_aws_regional_dr
}
