provider "aws" {
  region              = var.aws_region
  allowed_account_ids = [var.aws_account_id]
}

data "aws_subnet" "restore" {
  for_each = var.enable_restore ? var.subnet_ids : []
  id       = each.value
}

data "aws_security_group" "probe" {
  count = var.enable_restore && var.probe_security_group_id != "" ? 1 : 0
  id    = var.probe_security_group_id
}

resource "aws_security_group" "restore" {
  count       = var.enable_restore ? 1 : 0
  name        = "andeslog-restore-${var.recovery_id}"
  description = "Isolated ERP PostgreSQL restore; no application access."
  vpc_id      = var.vpc_id

  lifecycle {
    precondition {
      condition = try(
        split(":", var.backup_arn)[3] == var.aws_region &&
        split(":", var.backup_arn)[4] == var.aws_account_id &&
        var.vpc_id != "" && var.recovery_id != "" && length(var.subnet_ids) >= 2,
        false
      )
      error_message = "La restauración requiere backup de esta cuenta y región, VPC, identificador y al menos dos subredes."
    }
    precondition {
      condition = alltrue([
        for subnet in data.aws_subnet.restore : subnet.vpc_id == var.vpc_id && !subnet.map_public_ip_on_launch
      ]) && length(distinct([for subnet in data.aws_subnet.restore : subnet.availability_zone_id])) >= 2
      error_message = "Las subredes deben pertenecer a la VPC, no asignar IP pública automática y estar en dos zonas."
    }
    precondition {
      condition     = var.probe_security_group_id == "" || try(data.aws_security_group.probe[0].vpc_id == var.vpc_id, false)
      error_message = "El SG del verificador debe pertenecer a la VPC de restauración."
    }
  }
}

resource "aws_vpc_security_group_ingress_rule" "probe" {
  count                        = var.enable_restore && var.probe_security_group_id != "" ? 1 : 0
  security_group_id            = aws_security_group.restore[0].id
  referenced_security_group_id = var.probe_security_group_id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
  description                  = "PostgreSQL only from the explicitly authorized verifier."
}

resource "aws_db_subnet_group" "restore" {
  count       = var.enable_restore ? 1 : 0
  name        = "andeslog-restore-${var.recovery_id}"
  description = "Subnets for isolated AndesLog restore."
  subnet_ids  = sort(tolist(var.subnet_ids))
}

resource "aws_db_instance" "restore" {
  count                      = var.enable_restore ? 1 : 0
  identifier                 = "andeslog-restore-${var.recovery_id}"
  instance_class             = var.instance_class
  db_subnet_group_name       = aws_db_subnet_group.restore[0].name
  vpc_security_group_ids     = [aws_security_group.restore[0].id]
  publicly_accessible        = false
  multi_az                   = true
  backup_retention_period    = 7
  deletion_protection        = var.deletion_protection
  skip_final_snapshot        = var.skip_final_snapshot
  final_snapshot_identifier  = var.skip_final_snapshot ? null : "andeslog-restore-${var.recovery_id}-final"
  auto_minor_version_upgrade = false
  copy_tags_to_snapshot      = true
  apply_immediately          = false
  restore_to_point_in_time {
    source_db_instance_automated_backups_arn = var.backup_arn
    use_latest_restorable_time               = var.restore_time_utc == "" ? true : null
    restore_time                             = var.restore_time_utc == "" ? null : var.restore_time_utc
  }
  tags = { Project = "andeslog", Purpose = "isolated-pitr-restore" }
}

output "restore_endpoint" {
  description = "Endpoint privado de la base restaurada; vacío si está desactivada."
  value       = try(aws_db_instance.restore[0].address, "")
}

output "restore_identifier" {
  description = "Identificador de la base restaurada; no indica que la recuperación haya sido validada."
  value       = try(aws_db_instance.restore[0].identifier, "")
}
