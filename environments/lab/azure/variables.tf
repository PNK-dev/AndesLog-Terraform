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

variable "notification_email" {
  description = "Correo para notificaciones de alarmas. Pásalo como TF_VAR_notification_email; no lo guardes en Git."
  type        = string
  default     = ""
  sensitive   = true
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

variable "enable_erp_integration" {
  description = "Crea una Azure Function redundante para recibir eventos del ERP con HMAC y archivarlos de forma idempotente en Blob privado. lab.ps1 la activa automáticamente."
  type        = bool
  default     = false
}

variable "enable_erp_event_archive_replication" {
  description = "Experimental: replica el archivo Blob de eventos ERP a otra región. No habilita failover ni garantiza RPO."
  type        = bool
  default     = false

  validation {
    condition     = !var.enable_erp_event_archive_replication || (var.enable_erp_integration && lower(var.erp_event_archive_dr_location) != lower(var.backup_function_location))
    error_message = "La réplica del archivo requiere la integración ERP y una región distinta de la Function primaria."
  }
}

variable "erp_event_archive_dr_location" {
  description = "Región secundaria experimental para la copia del archivo de eventos."
  type        = string
  default     = "mexicocentral"
}

variable "enable_erp_failover_ingest" {
  description = "Experimental: prepara una Function regional secundaria para ingesta de eventos; requiere publicación y pruebas de recuperación."
  type        = bool
  default     = false

  validation {
    condition     = !var.enable_erp_failover_ingest || (var.enable_erp_event_archive_replication && var.enable_erp_integration && lower(var.erp_failover_ingest_location) != lower(var.backup_function_location))
    error_message = "La Function secundaria requiere integración, copia regional y una región distinta de la Function primaria."
  }
}

variable "erp_failover_ingest_location" {
  description = "Región de la Function secundaria; debe admitir Flex Consumption redundante por zonas en la suscripción."
  type        = string
  default     = "eastus2"
}

variable "backup_function_location" {
  description = "Región compatible con Flex Consumption para el host de Azure Functions; puede diferir de la VM y Blob."
  type        = string
  default     = "westus2"
}

variable "enable_remote_access" {
  description = "Habilita acceso P2S redundante con Azure VPN Gateway, OpenVPN y Microsoft Entra ID para clientes Windows."
  type        = bool
  default     = false
}

variable "enable_files_dr_replica" {
  description = "Crea una copia independiente de Azure Files en azure_files_dr_location con acceso privado y peering global."
  type        = bool
  default     = true
}

variable "enable_files_dr_checkpoint" {
  description = "Experimental: guarda el avance de la copia de Azure Files en Blob privado. Requiere validación real antes de usar en producción."
  type        = bool
  default     = false

  validation {
    condition     = !var.enable_files_dr_checkpoint || (var.enable_remote_access && var.enable_files_dr_replica && var.enable_erp_integration)
    error_message = "enable_files_dr_checkpoint requiere acceso remoto, réplica de Files e integración ERP."
  }
}

variable "enable_files_dr_gateway" {
  description = "Crea un gateway P2S zonal en la región de réplica para failover manual si Chile Central no está disponible. Tiene coste horario mientras exista."
  type        = bool
  default     = false
}

variable "azure_files_dr_location" {
  description = "Región secundaria para la copia manual de Azure Files."
  type        = string
  default     = "mexicocentral"
}

variable "azure_files_dr_vnet_cidr" {
  description = "CIDR de la VNet de recuperación de Azure Files; no debe solaparse con las otras redes."
  type        = string
  default     = "10.22.0.0/16"
}

variable "azure_files_dr_vpn_client_address_pool" {
  description = "Pool P2S independiente para el gateway de recuperación."
  type        = string
  default     = "172.30.61.0/24"
}

variable "enable_intercloud_vpn" {
  description = "Crea un gateway Azure activo-activo con BGP para las cuatro conexiones IPsec con AWS."
  type        = bool
  default     = false
}

variable "enable_aws_vpn_connections" {
  description = "Activa las cuatro conexiones Azure->AWS con BGP después de que AWS haya creado sus túneles."
  type        = bool
  default     = false

  validation {
    condition     = !var.enable_aws_vpn_connections || var.enable_intercloud_vpn
    error_message = "enable_aws_vpn_connections requiere enable_intercloud_vpn=true."
  }
}

variable "azure_vpn_gateway_sku" {
  description = "SKU zonal de Azure VPN Gateway. VpnGw1AZ admite active-active, BGP y P2S para este laboratorio."
  type        = string
  default     = "VpnGw1AZ"
}

variable "azure_gateway_zones" {
  description = "Zonas de disponibilidad usadas por las IP públicas Standard del gateway zonal."
  type        = list(string)
  default     = ["1", "2", "3"]
}

variable "vpn_client_address_pool" {
  description = "Pool de direcciones de clientes Windows P2S, sin solapamiento con las VNet/VPC."
  type        = string
  default     = "172.30.60.0/24"
}

variable "vpn_client_aad_audience" {
  description = "Audience de la aplicación Microsoft Azure VPN Client registrada para autenticación Entra."
  type        = string
  default     = "c632b3df-fb67-4d84-bdcf-b95ad541b5c8"
}

variable "aws_vpc_cidr" {
  description = "CIDR de la VPC AWS anunciado por el S2S VPN."
  type        = string
  default     = "10.10.0.0/16"
}

variable "aws_vpn_tunnel_configs" {
  description = "Cuatro endpoints, peers BGP y PSK de AWS Site-to-Site VPN; lab.ps1 los pasa como variable sensible en memoria."
  type = list(object({
    name             = string
    address          = string
    bgp_peer_address = string
    shared_key       = string
  }))
  default   = []
  sensitive = true

  validation {
    condition = !var.enable_aws_vpn_connections || (
      length(var.aws_vpn_tunnel_configs) == 4 &&
      toset([for tunnel in var.aws_vpn_tunnel_configs : tunnel.name]) == toset([
        "azure-gateway-a-1", "azure-gateway-a-2", "azure-gateway-b-1", "azure-gateway-b-2"
      ]) &&
      alltrue([for tunnel in var.aws_vpn_tunnel_configs :
        can(cidrhost("${tunnel.address}/32", 0)) &&
        can(cidrhost("${tunnel.bgp_peer_address}/32", 0)) &&
        length(tunnel.shared_key) >= 8 && length(tunnel.shared_key) <= 64
      ])
    )
    error_message = "Las cuatro conexiones requieren endpoints IPv4, peers BGP IPv4 y PSK de 8 a 64 caracteres."
  }
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

variable "create_files_storage_account" {
  description = "Crea una nueva cuenta Azure Files ZRS y share. Déjalo false para conectar el share existente sin importarlo ni administrarlo."
  type        = bool
  default     = false
}

variable "existing_files_storage_account_name" {
  description = "Cuenta Azure Files retenida que se importará temporalmente para migrar LRS a ZRS y se conservará fuera del estado en Destroy; vacío usa el nombre determinista del laboratorio."
  type        = string
  default     = ""
}

variable "existing_files_share_name" {
  description = "Nombre del share SMB ya existente, conservado fuera del estado Terraform."
  type        = string
  default     = "andeslog"
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

