variable "project" {
  description = "Prefijo de nombres del proyecto."
  type        = string
  default     = "andeslog"

  validation {
    condition     = can(regex("^[a-z0-9]([a-z0-9-]{1,18}[a-z0-9])$", var.project))
    error_message = "project debe tener entre 3 y 20 caracteres, iniciar y terminar en letra o número, y usar solo minúsculas, números o guiones."
  }
}

variable "environment" {
  description = "Entorno lógico."
  type        = string
  default     = "lab"

  validation {
    condition     = can(regex("^[a-z0-9]([a-z0-9-]{0,5}[a-z0-9])$", var.environment))
    error_message = "environment debe tener entre 2 y 7 caracteres, iniciar y terminar en letra o número, y usar solo minúsculas, números o guiones."
  }
}

variable "owner" {
  description = "Equipo responsable del laboratorio."
  type        = string
  default     = "equipo"
}

variable "ttl_date" {
  description = "Fecha de revisión/destrucción para la etiqueta TTL (AAAA-MM-DD)."
  type        = string
  default     = ""
}

variable "aws_region" {
  description = "Región AWS autorizada por el Learner Lab."
  type        = string
  default     = "us-east-1"
}

variable "aws_vpc_cidr" {
  description = "CIDR de la VPC AWS. No debe solaparse con Azure."
  type        = string
  default     = "10.10.0.0/16"

  validation {
    condition     = var.aws_vpc_cidr == "10.10.0.0/16"
    error_message = "Este root usa subredes y rutas fijas dentro de 10.10.0.0/16; cambia también el diseño completo antes de usar otro CIDR."
  }
}

variable "db_private_ip" {
  description = "Dirección privada fija de PostgreSQL."
  type        = string
  default     = "10.10.21.10"
}

variable "erp_image" {
  description = "Imagen ERP con tag versionado o digest SHA-256. lab.ps1 puede cargarla por SSH si el registro es privado. No uses latest."
  type        = string

  validation {
    condition = (
      (can(regex("^[a-zA-Z0-9][a-zA-Z0-9./:_-]+:[a-zA-Z0-9_][a-zA-Z0-9_.-]*$", var.erp_image)) && !endswith(var.erp_image, ":latest")) ||
      can(regex("^[a-zA-Z0-9][a-zA-Z0-9./:_-]+@sha256:[a-fA-F0-9]{64}$", var.erp_image))
    )
    error_message = "erp_image debe usar un tag versionado distinto de latest o un digest SHA-256 de 64 caracteres hexadecimales."
  }
}

variable "azure_vpn_private_ip" {
  description = "IP privada de la VM Azure WireGuard usada para permitir sondeos."
  type        = string
  default     = "10.20.1.10"
}

variable "azure_vpc_cidr" {
  description = "CIDR de la VNet Azure autorizado a llegar al servicio web por WireGuard."
  type        = string
  default     = "10.20.0.0/16"

  validation {
    condition     = var.azure_vpc_cidr == "10.20.0.0/16"
    error_message = "Este root espera la VNet Azure 10.20.0.0/16; cambia también el diseño completo antes de usar otro CIDR."
  }
}

variable "azure_peer_public_cidr" {
  description = "IP pública de Azure VPN en formato CIDR /32. Vacío hasta conocer el output de Azure."
  type        = string
  default     = ""

  validation {
    condition     = var.azure_peer_public_cidr == "" || (can(cidrnetmask(var.azure_peer_public_cidr)) && endswith(var.azure_peer_public_cidr, "/32"))
    error_message = "azure_peer_public_cidr debe estar vacío o ser una dirección IPv4 /32."
  }
}

variable "azure_wireguard_public_key" {
  description = "Clave pública WireGuard del peer Azure. Nunca introduzcas aquí una clave privada."
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9+/]{43}=$", var.azure_wireguard_public_key))
    error_message = "azure_wireguard_public_key debe ser una clave pública WireGuard válida."
  }
}

variable "admin_public_cidr" {
  description = "IP pública administrativa /32 para SSH al peer AWS. Vacío deshabilita SSH administrativo directo."
  type        = string
  default     = ""

  validation {
    condition     = var.admin_public_cidr == "" || (can(cidrnetmask(var.admin_public_cidr)) && endswith(var.admin_public_cidr, "/32"))
    error_message = "admin_public_cidr debe estar vacío o ser una dirección IPv4 /32."
  }
}

variable "ssh_public_key" {
  description = "Clave SSH pública. Nunca pongas aquí la clave privada."
  type        = string
  default     = ""
}

variable "existing_key_name" {
  description = "Nombre de un key pair EC2 existente, si no se creará uno desde ssh_public_key."
  type        = string
  default     = ""
}

variable "web_instance_type" {
  description = "Tipo de cada EC2 web. Confirma la cuota total antes del apply."
  type        = string
  default     = "t3.micro"
}

variable "db_instance_type" {
  description = "Tipo de EC2 PostgreSQL."
  type        = string
  default     = "t3.micro"
}

variable "vpn_instance_type" {
  description = "Tipo de EC2 WireGuard."
  type        = string
  default     = "t3.micro"
}

variable "enable_temporary_nat" {
  description = "Crea un único NAT Gateway temporal para instalar paquetes en EC2 privadas durante cloud-init. Tiene costo por hora y tráfico."
  type        = bool
  default     = false
}

variable "create_vpn_eip" {
  description = "Asigna una Elastic IP al peer VPN AWS. Si el Learner Lab la deniega, mantener false y usar la IP dinámica de la instancia."
  type        = bool
  default     = false
}

variable "route_db_to_azure" {
  description = "Agrega ruta de la subnet PostgreSQL a Azure. Desactivada por defecto."
  type        = bool
  default     = false
}

variable "backup_retention_days" {
  description = "Días de retención de objetos de backup en S3."
  type        = number
  default     = 7

  validation {
    condition     = var.backup_retention_days >= 1 && var.backup_retention_days <= 365
    error_message = "backup_retention_days debe estar entre 1 y 365."
  }
}

variable "enable_aws_s3_backups" {
  description = "Crea el bucket S3; algunas cuentas academicas bloquean las lecturas de Object Lock requeridas por el proveedor Terraform."
  type        = bool
  default     = false
}

variable "enable_s3_versioning" {
  description = "Habilita versioning en el bucket de backups; puede incrementar almacenamiento."
  type        = bool
  default     = false
}
