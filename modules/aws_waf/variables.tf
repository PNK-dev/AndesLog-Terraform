variable "name" { type = string }
variable "region" { type = string }
variable "account_id" { type = string }
variable "alb_arn" { type = string }
variable "tags" { type = map(string) }
variable "logs_verified" { type = bool }
variable "rules_reviewed" { type = bool }
variable "phase" {
  type = string
  validation {
    condition     = contains(["logging", "count", "enforce"], var.phase)
    error_message = "La fase WAF debe ser logging, count o enforce."
  }
}
variable "rate_limit" {
  type = number
  validation {
    condition     = var.rate_limit >= 10 && var.rate_limit <= 2000000000 && floor(var.rate_limit) == var.rate_limit
    error_message = "El límite WAF debe ser un entero entre 10 y 2000000000 solicitudes por cinco minutos."
  }
}
