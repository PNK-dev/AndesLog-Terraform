output "aws_region" {
  description = "Región AWS usada."
  value       = var.aws_region
}

output "vpc_id" {
  description = "ID de la VPC."
  value       = aws_vpc.main.id
}

output "alb_dns_name" {
  description = "DNS público del Application Load Balancer."
  value       = aws_lb.web.dns_name
}

output "web_target_group_arn" {
  description = "Target Group ARN usado para verificar continuidad y recuperación del ERP."
  value       = aws_lb_target_group.web.arn
}

output "web_auto_scaling_group_name" {
  description = "Auto Scaling Group multi-AZ que administra los nodos del ERP."
  value       = aws_autoscaling_group.web.name
}

output "web_ecr_repository_url" {
  description = "URL del repositorio ECR privado para publicar la imagen ERP."
  value       = aws_ecr_repository.erp.repository_url
}

output "web_erp_image_tag" {
  description = "Tag versionado de la imagen ERP configurada en el Launch Template."
  value       = var.erp_image_tag
}

output "web_runtime_secret_arn" {
  description = "ARN del secreto de runtime del ERP; no expone su valor."
  value       = aws_secretsmanager_secret.erp_runtime.arn
}

output "bootstrap_private_ip" {
  description = "IP privada de la VM temporal usada solo durante el aprovisionamiento."
  value       = try(aws_instance.bootstrap[0].private_ip, "")
}

output "bootstrap_public_ip" {
  description = "IP pública temporal de bootstrap, usada solo para SSH restringido a la IP administrativa /32."
  value       = try(aws_instance.bootstrap[0].public_ip, "")
}

output "db_endpoint" {
  description = "Endpoint DNS privado de RDS PostgreSQL Multi-AZ."
  value       = aws_db_instance.main.address
}

output "db_instance_identifier" {
  description = "Identificador de RDS Multi-AZ para verificación y pruebas controladas de failover."
  value       = aws_db_instance.main.identifier
}

output "db_port" {
  description = "Puerto privado de RDS PostgreSQL."
  value       = aws_db_instance.main.port
}

output "db_master_secret_arn" {
  description = "ARN del secreto maestro de RDS o del secreto externo; el valor del secreto no se expone."
  value       = length(aws_db_instance.main.master_user_secret) > 0 ? aws_db_instance.main.master_user_secret[0].secret_arn : var.rds_external_master_secret_arn
}

output "rds_external_rotation_lambda_arn" {
  description = "ARN de la Lambda de rotación externa configurada; vacío cuando RDS administra la contraseña."
  value       = var.rds_external_rotation_lambda_arn
}

output "rds_external_master_secret_arn" {
  description = "ARN del secreto externo configurado; vacío cuando RDS administra la contraseña."
  value       = var.rds_external_master_secret_arn
}

output "vpn_gateway_id" {
  description = "ID del Virtual Private Gateway AWS cuando la conectividad intercloud está habilitada."
  value       = try(aws_vpn_gateway.main[0].id, "")
}

output "vpn_connection_ids" {
  description = "IDs de las dos conexiones Site-to-Site VPN redundantes con Azure."
  value       = join(",", [for key in sort(keys(aws_vpn_connection.intercloud)) : aws_vpn_connection.intercloud[key].id])
}

output "backup_bucket_name" {
  description = "Nombre del bucket AWS de respaldos, o null cuando la cuenta no admite su gestión."
  value       = var.enable_aws_s3_backups ? aws_s3_bucket.backups[0].bucket : null
}

output "cloudwatch_dashboard_name" {
  description = "Dashboard de CloudWatch."
  value       = aws_cloudwatch_dashboard.main.dashboard_name
}
