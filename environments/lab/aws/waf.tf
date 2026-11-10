variable "waf_phase" {
  description = "Fase WAF: off, logging, count o enforce; se activa explícitamente."
  type        = string
  default     = "off"
  validation {
    condition     = contains(["off", "logging", "count", "enforce"], var.waf_phase)
    error_message = "waf_phase debe ser off, logging, count o enforce."
  }
}

variable "waf_rate_limit" {
  description = "Solicitudes por IP en cinco minutos; debe definirse con tráfico medido antes de activar reglas."
  type        = number
  default     = 0
  validation {
    condition     = var.waf_rate_limit == 0 || (var.waf_rate_limit >= 10 && var.waf_rate_limit <= 2000000000 && floor(var.waf_rate_limit) == var.waf_rate_limit)
    error_message = "El límite debe ser 0 sin reglas, o un entero entre 10 y 2000000000."
  }
  validation {
    condition     = !contains(["count", "enforce"], var.waf_phase) || var.waf_rate_limit >= 10
    error_message = "Para count o enforce se necesita un límite WAF basado en tráfico medido."
  }
}

variable "waf_logs_verified" {
  description = "Confirma que los logs WAF protegidos llegan antes de agregar reglas."
  type        = bool
  default     = false
}

variable "waf_rules_reviewed" {
  description = "Confirma que se revisaron coincidencias y falsos positivos antes de bloquear."
  type        = bool
  default     = false
}

module "primary_waf" {
  count          = var.waf_phase == "off" ? 0 : 1
  source         = "../../../modules/aws_waf"
  name           = "${local.prefix}-web"
  region         = var.aws_region
  account_id     = data.aws_caller_identity.current.account_id
  alb_arn        = aws_lb.web.arn
  tags           = merge(local.common_tags, { Purpose = "regional-web-protection" })
  phase          = var.waf_phase
  rate_limit     = max(var.waf_rate_limit, 10)
  logs_verified  = var.waf_logs_verified
  rules_reviewed = var.waf_rules_reviewed
}

module "secondary_waf" {
  count          = var.waf_phase != "off" && local.dr_erp_enabled ? 1 : 0
  source         = "../../../modules/aws_waf"
  providers      = { aws = aws.dr }
  name           = "${local.prefix}-dr-web"
  region         = var.aws_dr_region
  account_id     = data.aws_caller_identity.current.account_id
  alb_arn        = aws_lb.dr_erp[0].arn
  tags           = merge(local.common_tags, { Purpose = "regional-web-protection" })
  phase          = var.waf_phase
  rate_limit     = max(var.waf_rate_limit, 10)
  logs_verified  = var.waf_logs_verified
  rules_reviewed = var.waf_rules_reviewed
}

output "web_waf_phase" {
  description = "Fase WAF administrada por Terraform; no demuestra que logs ni reglas se hayan validado."
  value       = var.waf_phase
}

output "web_waf_rate_limit" {
  description = "Límite WAF por IP durante cinco minutos; 0 significa no configurado."
  value       = var.waf_rate_limit
}
