# Off by default. RDS retains already replicated backups after replication is
# stopped; Terraform destroy alone must not be assumed to eliminate charges.
resource "aws_db_instance_automated_backups_replication" "regional" {
  provider               = aws.dr
  count                  = var.enable_rds_backup_replication ? 1 : 0
  source_db_instance_arn = aws_db_instance.main.arn
  kms_key_id             = data.aws_kms_alias.dr_rds[0].target_key_arn
  retention_period       = var.rds_replica_backup_retention_days

  lifecycle {
    precondition {
      condition     = var.aws_dr_region != var.aws_region
      error_message = "Los backups regionales requieren una región de destino distinta."
    }
  }
}

output "rds_backup_replication_enabled" {
  description = "Indica si se solicitó la replicación regional experimental de backups RDS."
  value       = var.enable_rds_backup_replication
}

output "rds_replicated_backup_arn" {
  description = "ARN del backup automatizado regional; puede seguir existiendo y generando costos al detener la replicación."
  value       = try(aws_db_instance_automated_backups_replication.regional[0].id, "")
}
