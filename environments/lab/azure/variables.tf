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

variable "subscription_id" {
  description = "ID de la suscripción elegida con az login. No es una contraseña."
  type        = string
}

variable "create_blob_role_assignment" {
  description = "Crea Storage Blob Data Contributor en el scope de la cuenta Storage. Déjalo false si la identidad ya tiene acceso; requiere permiso para asignar roles."
  type        = bool
  default     = false
}

variable "enable_backup_audit" {
  description = "Crea la Azure Function que audita backups Blob; requiere Microsoft.Web, Microsoft.EventGrid y permiso para asignar roles."
  type        = bool
  default     = false
}

variable "backup_function_location" {
  description = "Región compatible con Flex Consumption para el host de Azure Functions; puede diferir de la VM y Blob."
  type        = string
  default     = "westus2"
}

variable "enable_remote_access" {
  description = "Crea Azure Files privado y abre OpenVPN en la VM Azure existente. scripts/lab.ps1 configura el servidor fuera de Terraform."
  type        = bool
  default     = false
}

variable "azure_files_quota_gb" {
  description = "Cuota máxima en GiB del recurso compartido Azure Files."
  type        = number
  default     = 10

  validation {
    condition     = var.azure_files_quota_gb >= 1 && var.azure_files_quota_gb <= 5120 && floor(var.azure_files_quota_gb) == var.azure_files_quota_gb
    error_message = "azure_files_quota_gb debe ser un entero entre 1 y 5120."
  }
}

variable "enable_backup_event_subscription" {
  description = "Se activa tras publicar el código de BackupAudit; scripts/lab.ps1 lo gestiona automáticamente."
  type        = bool
  default     = false
}

variable "backup_audit_max_bytes" {
  description = "Tamaño máximo, en bytes, de un backup cuyo SHA-256 calculará la Function."
  type        = number
  default     = 1073741824

  validation {
    condition     = var.backup_audit_max_bytes > 0 && floor(var.backup_audit_max_bytes) == var.backup_audit_max_bytes
    error_message = "backup_audit_max_bytes debe ser un entero positivo."
  }
}

variable "azure_location" {
  description = "Región permitida por la oferta académica."
  type        = string
  default     = "chilecentral"
}

variable "azure_vnet_cidr" {
  description = "CIDR de la VNet. No debe solaparse con AWS."
  type        = string
  default     = "10.20.0.0/16"

  validation {
    condition     = var.azure_vnet_cidr == "10.20.0.0/16"
    error_message = "Este root usa subredes y rutas fijas dentro de 10.20.0.0/16; cambia también el diseño completo antes de usar otro CIDR."
  }
}

variable "vm_size" {
  description = "SKU de la VM VPN; validar cuota y disponibilidad regional."
  type        = string
  default     = "Standard_B2als_v2"
}

variable "admin_username" {
  description = "Usuario Linux administrativo de la VM."
  type        = string
  default     = "azureuser"
}

variable "admin_ssh_public_key" {
  description = "Clave SSH pública; la clave privada queda en tu equipo."
  type        = string
}

variable "admin_public_cidr" {
  description = "IP pública administrativa /32 para SSH. Vacío deshabilita SSH de Internet."
  type        = string
  default     = ""

  validation {
    condition     = var.admin_public_cidr == "" || (can(cidrnetmask(var.admin_public_cidr)) && endswith(var.admin_public_cidr, "/32"))
    error_message = "admin_public_cidr debe estar vacío o ser una dirección IPv4 /32."
  }
}

variable "aws_peer_public_cidr" {
  description = "IP pública del peer VPN AWS en formato /32. Vacío hasta conocer el output AWS."
  type        = string
  default     = ""

  validation {
    condition     = var.aws_peer_public_cidr == "" || (can(cidrnetmask(var.aws_peer_public_cidr)) && endswith(var.aws_peer_public_cidr, "/32"))
    error_message = "aws_peer_public_cidr debe estar vacío o ser una dirección IPv4 /32."
  }
}

