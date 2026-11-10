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

variable "aws_region" {
  description = "Región AWS autorizada por el Learner Lab."
  type        = string
  default     = "us-east-1"
}

variable "enable_aws_regional_dr" {
  description = "Prepara una réplica PostgreSQL cifrada Multi-AZ en otra región. Requiere migrar primero las credenciales maestras fuera de la gestión directa de RDS."
  type        = bool
  default     = false
}

variable "enable_dr_erp_compute" {
  description = "EXPERIMENTAL: crea capacidad ERP en espera en la región secundaria; requiere DR, imagen y secreto replicados y certificado ACM regional."
  type        = bool
  default     = false

  validation {
    condition     = !var.enable_dr_erp_compute || (var.enable_aws_regional_dr && var.enable_dr_runtime_secret_replication)
    error_message = "La capacidad ERP secundaria requiere DR regional y replicación del secreto de ejecución."
  }
}

variable "enable_dr_runtime_secret_replication" {
  description = "Replica el secreto ERP solo después de que el valor primario se haya creado; requiere DR regional."
  type        = bool
  default     = false

  validation {
    condition     = !var.enable_dr_runtime_secret_replication || var.enable_aws_regional_dr
    error_message = "La réplica del secreto ERP requiere DR regional habilitada."
  }
}

variable "enable_dr_probe_network" {
  description = "Prepara red privada dedicada a sondas PostgreSQL entre regiones; no crea ejecutores ni la activa por defecto."
  type        = bool
  default     = false

  validation {
    condition     = !var.enable_dr_probe_network || var.enable_aws_regional_dr
    error_message = "La red de sondas regional requiere DR regional habilitada."
  }
}

variable "dr_alb_certificate_arn" {
  description = "ARN de certificado ACM validado en la región secundaria para la entrada HTTPS de recuperación."
  type        = string
  default     = ""

  validation {
    condition     = var.dr_alb_certificate_arn == "" || can(regex("^arn:[^:]+:acm:[^:]+:[0-9]{12}:certificate/[0-9a-fA-F-]+$", var.dr_alb_certificate_arn))
    error_message = "dr_alb_certificate_arn debe estar vacío o ser un ARN de certificado ACM."
  }
}

variable "aws_dr_region" {
  description = "Región de recuperación de PostgreSQL; debe ser diferente de la región primaria."
  type        = string
  default     = "us-west-2"
}

variable "aws_dr_vpc_cidr" {
  description = "CIDR /16 no solapado con AWS primario ni las redes Azure."
  type        = string
  default     = "10.11.0.0/16"

  validation {
    condition = try(
      cidrnetmask(var.aws_dr_vpc_cidr) == "255.255.0.0" &&
      cidrhost(var.aws_dr_vpc_cidr, 0) == split("/", var.aws_dr_vpc_cidr)[0] &&
      !contains(["10.10.0.0", "10.20.0.0", "10.22.0.0", "10.30.0.0", "172.30.0.0"], cidrhost(var.aws_dr_vpc_cidr, 0)),
      false
    )
    error_message = "aws_dr_vpc_cidr debe ser una red IPv4 /16 canónica que no solape las redes predeterminadas del proyecto."
  }
}

variable "aws_dr_kms_key_alias" {
  description = "Alias KMS existente en la región secundaria para cifrar la réplica RDS."
  type        = string
  default     = "alias/aws/rds"
}

variable "dr_ecr_force_delete" {
  description = "Permite borrar imágenes del registro regional al destruirlo; úsalo solo cuando se acepta perder esas imágenes."
  type        = bool
  default     = false
}

variable "rds_external_master_secret_arn" {
  description = "ARN de un secreto maestro externo dedicado; requiere Lambda de rotación y contraseña efímera."
  type        = string
  default     = ""

  validation {
    condition     = var.rds_external_master_secret_arn == "" || can(regex("^arn:[^:]+:secretsmanager:[^:]+:[0-9]{12}:secret:.+$", var.rds_external_master_secret_arn))
    error_message = "rds_external_master_secret_arn debe estar vacío o ser un ARN de Secrets Manager válido."
  }
}

variable "rds_master_password" {
  description = "Contraseña maestra efímera; se obtiene del secreto externo en memoria y no se guarda en plan ni estado."
  type        = string
  sensitive   = true
  ephemeral   = true
  default     = null

  validation {
    condition     = var.rds_external_master_secret_arn == "" || var.rds_master_password != null
    error_message = "La contraseña efímera es obligatoria con un secreto maestro externo."
  }

  validation {
    condition = var.rds_master_password == null || try(
      can(regex("^[!-~]{8,128}$", var.rds_master_password)) &&
      !can(regex("[/\"@']", var.rds_master_password)),
      false
    )
    error_message = "La contraseña maestra debe cumplir las restricciones de caracteres y longitud de RDS PostgreSQL."
  }
}

variable "rds_external_rotation_lambda_arn" {
  description = "ARN de una Lambda de rotación ya provisionada y validada para el secreto maestro externo."
  type        = string
  default     = ""

  validation {
    condition     = var.rds_external_rotation_lambda_arn == "" || can(regex("^arn:[^:]+:lambda:[^:]+:[0-9]{12}:function:[a-zA-Z0-9_-]+(:[a-zA-Z0-9_-]+)?$", var.rds_external_rotation_lambda_arn))
    error_message = "rds_external_rotation_lambda_arn debe estar vacío o ser un ARN Lambda válido."
  }
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

variable "erp_image_tag" {
  description = "Etiqueta inmutable para la imagen publicada por lab.ps1 en el ECR privado."
  type        = string
  default     = "img-bootstrap"

  validation {
    condition     = can(regex("^img-[A-Za-z0-9_.-]{1,120}$", var.erp_image_tag))
    error_message = "erp_image_tag debe comenzar con img- y usar solo caracteres alfanuméricos, guion, punto o guion bajo."
  }
}

variable "enable_erp_integration" {
  description = "Instala el worker outbox en cada nodo ERP para entregar eventos firmados a Azure. lab.ps1 activa esta opción al desplegar la integración."
  type        = bool
  default     = false
}

variable "alb_certificate_arn" {
  description = "ARN de un certificado ACM validado para un dominio propio. Si se configura, el ALB habilita HTTPS y redirige HTTP a HTTPS."
  type        = string
  default     = ""

  validation {
    condition     = var.alb_certificate_arn == "" || can(regex("^arn:[^:]+:acm:[^:]+:[0-9]{12}:certificate/[0-9a-fA-F-]+$", var.alb_certificate_arn))
    error_message = "alb_certificate_arn debe estar vacío o ser un ARN de certificado ACM."
  }
}

variable "azure_vpc_cidr" {
  description = "CIDR de la VNet Azure autorizado a llegar al servicio web por VPN Site-to-Site."
  type        = string
  default     = "10.20.0.0/16"

  validation {
    condition     = var.azure_vpc_cidr == "10.20.0.0/16"
    error_message = "Este root espera la VNet Azure 10.20.0.0/16; cambia también el diseño completo antes de usar otro CIDR."
  }
}

variable "enable_intercloud_vpn" {
  description = "Crea AWS Virtual Private Gateway y dos VPN Site-to-Site con BGP hacia el gateway Azure activo-activo."
  type        = bool
  default     = false
}

variable "azure_gateway_public_ips" {
  description = "Dos IP públicas de Azure VPN Gateway activo-activo, en orden gateway-a, gateway-b."
  type        = list(string)
  default     = []

  validation {
    condition = !var.enable_intercloud_vpn || (
      length(var.azure_gateway_public_ips) == 2 &&
      alltrue([for ip in var.azure_gateway_public_ips : can(cidrhost("${ip}/32", 0))])
    )
    error_message = "Con enable_intercloud_vpn=true se requieren exactamente dos IP públicas IPv4 del gateway Azure."
  }
}

variable "azure_p2s_client_cidr" {
  description = "Pool P2S Azure autorizado en el SG ERP; las rutas de retorno se aprenden por BGP."
  type        = string
  default     = "172.30.60.0/24"
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
  description = "Tipo de cada nodo del Auto Scaling Group y de la VM bootstrap temporal. Confirma la cuota total antes del apply."
  type        = string
  default     = "t3.micro"
}

variable "web_min_size" {
  description = "Capacidad mínima del ASG. lab.ps1 la aumenta a 2 después de preparar el secreto y la imagen."
  type        = number
  default     = 0
}

variable "web_desired_capacity" {
  description = "Capacidad inicial del ASG; lab.ps1 crea el grupo vacío y lo escala a 2 al terminar la inicialización."
  type        = number
  default     = 0
}

variable "web_max_size" {
  description = "Capacidad máxima para escalado horizontal del ERP."
  type        = number
  default     = 3
}

variable "enable_instance_refresh" {
  description = "Activa las actualizaciones graduales del ASG. Desactívalo solo en cuentas académicas cuya SCP deniegue autoscaling:StartInstanceRefresh."
  type        = bool
  default     = true
}

variable "bootstrap_instance_enabled" {
  description = "Crea la EC2 temporal, sin tráfico público, que inicializa RDS durante lab.ps1. El script la elimina al completar."
  type        = bool
  default     = false
}

variable "web_instance_profile_name" {
  description = "Opcional: perfil de instancia existente, por ejemplo LabInstanceProfile/LabRole en AWS Academy. Debe permitir ECR pull y secretsmanager:GetSecretValue para el secreto ERP. Vacío crea un rol mínimo administrado por Terraform."
  type        = string
  default     = ""

  validation {
    condition     = var.web_instance_profile_name == "" || can(regex("^[A-Za-z0-9+=,.@_-]{1,128}$", var.web_instance_profile_name))
    error_message = "web_instance_profile_name debe ser el nombre de un perfil IAM válido o quedar vacío."
  }
}

variable "rds_instance_class" {
  description = "Clase de instancia RDS PostgreSQL. Confirma soporte Multi-AZ en la región antes del apply."
  type        = string
  default     = "db.t3.micro"

  validation {
    condition     = can(regex("^db\\.[a-z0-9]+\\.[a-z0-9]+$", var.rds_instance_class))
    error_message = "rds_instance_class debe ser una clase RDS como db.t3.micro."
  }
}

variable "rds_engine_version" {
  description = "Versión menor de PostgreSQL ofrecida por RDS en la región."
  type        = string
  default     = "16.9"
}

variable "rds_deletion_protection" {
  description = "Bloquea la eliminación de RDS. Solo scripts/lab.ps1 -Action Destroy -ConfirmDataLoss lo desactiva temporalmente antes de borrar la base del laboratorio."
  type        = bool
  default     = true
}

variable "rds_skip_final_snapshot" {
  description = "Omite snapshot final al destruir RDS. Solo activar en laboratorio si se acepta perder la base."
  type        = bool
  default     = true
}

variable "rds_final_snapshot_identifier" {
  description = "Identificador de snapshot final cuando rds_skip_final_snapshot=false; debe ser único por eliminación."
  type        = string
  default     = "andeslog-lab-postgres-final"
}

variable "enable_temporary_nat" {
  description = "Crea NAT Gateways en ambas zonas para que nodos privados puedan descargar imágenes y reemplazarse ante fallos. Es necesario para autorrecuperación y genera costo por hora/tráfico mientras está activo."
  type        = bool
  default     = false
}

variable "backup_retention_days" {
  description = "Días de retención S3 y valor heredado de RDS si no se define rds_backup_retention_days."
  type        = number
  default     = 7

  validation {
    condition     = var.backup_retention_days >= 1 && var.backup_retention_days <= 365 && floor(var.backup_retention_days) == var.backup_retention_days
    error_message = "backup_retention_days debe ser un entero entre 1 y 365."
  }
}

variable "rds_backup_retention_days" {
  description = "Retención local de RDS en días. Si es null conserva el valor heredado de backup_retention_days; RDS admite como máximo 35."
  type        = number
  default     = null
  nullable    = true
  validation {
    condition     = var.rds_backup_retention_days == null || try(var.rds_backup_retention_days >= 1 && var.rds_backup_retention_days <= 35 && floor(var.rds_backup_retention_days) == var.rds_backup_retention_days, false)
    error_message = "rds_backup_retention_days debe ser null o un entero de 1 a 35."
  }
}

variable "enable_rds_backup_replication" {
  description = "Experimental: solicita replicación de backups RDS a la región secundaria; puede dejar backups facturables tras detenerse."
  type        = bool
  default     = false
}

variable "rds_replica_backup_retention_days" {
  description = "Retención de backups automáticos replicados en la región de recuperación."
  type        = number
  default     = 7
  validation {
    condition     = var.rds_replica_backup_retention_days >= 1 && var.rds_replica_backup_retention_days <= 35 && floor(var.rds_replica_backup_retention_days) == var.rds_replica_backup_retention_days
    error_message = "rds_replica_backup_retention_days debe ser un entero de 1 a 35."
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
