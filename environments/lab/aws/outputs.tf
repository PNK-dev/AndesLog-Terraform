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

output "web_private_ips" {
  description = "Direcciones privadas de las EC2 web."
  value       = { for name, instance in aws_instance.web : name => instance.private_ip }
}

output "db_private_ip" {
  description = "Dirección privada de PostgreSQL."
  value       = aws_instance.db.private_ip
}

output "vpn_public_ip" {
  description = "IP pública que debe usarse como endpoint del peer WireGuard AWS."
  value       = var.create_vpn_eip ? aws_eip.vpn[0].public_ip : aws_instance.vpn.public_ip
}

output "vpn_instance_id" {
  description = "ID de la VM VPN AWS, útil para consultar su salida de cloud-init."
  value       = aws_instance.vpn.id
}

output "vpn_private_ip" {
  description = "Dirección privada del peer WireGuard AWS."
  value       = aws_instance.vpn.private_ip
}

output "backup_bucket_name" {
  description = "Nombre del bucket AWS de respaldos, o null cuando la cuenta no admite su gestión."
  value       = var.enable_aws_s3_backups ? aws_s3_bucket.backups[0].bucket : null
}

output "cloudwatch_dashboard_name" {
  description = "Dashboard de CloudWatch."
  value       = aws_cloudwatch_dashboard.main.dashboard_name
}
