variable "aws_region" {
  description = "Región AWS donde existe el backup replicado y se realizará la restauración."
  type        = string
  default     = "us-west-2"
}

variable "aws_account_id" {
  description = "Cuenta AWS prevista; el proveedor rechaza credenciales de otra cuenta."
  type        = string
  validation {
    condition     = can(regex("^[0-9]{12}$", var.aws_account_id))
    error_message = "aws_account_id debe contener exactamente 12 dígitos."
  }
}

variable "enable_restore" {
  description = "Debe indicarse explícitamente; true crea una restauración facturable y false puede destruir una existente."
  type        = bool
  nullable    = false
}

variable "backup_arn" {
  description = "ARN completo del backup automatizado replicado en la región de recuperación."
  type        = string
  default     = ""
  validation {
    condition     = var.backup_arn == "" || can(regex("^arn:aws:rds:[a-z0-9-]+:[0-9]{12}:auto-backup:ab-[A-Za-z0-9]+$", var.backup_arn))
    error_message = "backup_arn debe ser un ARN válido de backup automatizado RDS."
  }
}

variable "vpc_id" {
  description = "VPC existente en la región de recuperación; se debe comprobar su aislamiento y rutas."
  type        = string
  default     = ""
}

variable "subnet_ids" {
  description = "Subredes privadas existentes de la VPC, en al menos dos zonas distintas."
  type        = set(string)
  default     = []
}

variable "probe_security_group_id" {
  description = "Opcional: SG del verificador autorizado, en la misma VPC. Vacío no permite conexiones entrantes."
  type        = string
  default     = ""
}

variable "recovery_id" {
  description = "Identificador único y estable del ejercicio de restauración."
  type        = string
  default     = ""
  validation {
    condition     = var.recovery_id == "" || (can(regex("^[a-z][a-z0-9-]{1,24}[a-z0-9]$", var.recovery_id)) && !strcontains(var.recovery_id, "--"))
    error_message = "recovery_id debe tener 3-26 caracteres, comenzar por letra, acabar por letra o número y no incluir guiones consecutivos."
  }
}

variable "restore_time_utc" {
  description = "Fecha UTC RFC3339 dentro de la ventana del backup; vacío solicita el último punto restaurable."
  type        = string
  default     = ""
  validation {
    condition     = var.restore_time_utc == "" || (can(regex("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$", var.restore_time_utc)) && can(formatdate("YYYY-MM-DD'T'hh:mm:ss'Z'", var.restore_time_utc)))
    error_message = "restore_time_utc debe ser una fecha UTC válida con formato YYYY-MM-DDTHH:MM:SSZ."
  }
}

variable "instance_class" {
  description = "Clase de la base restaurada; confirmar cuota y capacidad en la región de recuperación."
  type        = string
  default     = "db.t3.micro"
}

variable "deletion_protection" {
  description = "Protege la base restaurada de borrados accidentales; desactivar explícitamente antes de la baja."
  type        = bool
  default     = true
}

variable "skip_final_snapshot" {
  description = "Omite el snapshot final solo si se acepta perder la base restaurada."
  type        = bool
  default     = false
}
