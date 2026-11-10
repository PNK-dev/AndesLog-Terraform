# AndesLog: guía rápida para la asesoría

Esta guía corresponde a la cuenta AWS Academy y la suscripción Azure de AndesLog configuradas en `scripts/lab.ps1`. Los repositorios Terraform y ERP deben estar actualizados a versiones compatibles y clonados como carpetas hermanas. **No inicies dos despliegues a la vez sobre los mismos workspaces HCP.**

## Antes de empezar

En Windows instala Terraform 1.11 o posterior, AWS CLI v2, Azure CLI, Docker Desktop y OpenSSH. Inicia Docker Desktop. Necesitas acceso a la organización HCP Terraform `AndesLog`, a la cuenta AWS Academy `406197219647` y a la suscripción Azure for Students configurada. Los workspaces HCP deben usar ejecución **Local** y estado remoto. El laboratorio crea recursos facturables; comprueba el crédito disponible y no lo dejes activo sin supervisión.

Desde PowerShell, en el directorio del repositorio Terraform:

```powershell
terraform version
aws --version
az version
docker info
ssh -V

$env:TF_CLOUD_ORGANIZATION = 'AndesLog'
terraform login

# Configura el perfil con las tres credenciales temporales de AWS Academy.
# Sustitúyelas cuando caduquen; no las compartas ni las guardes en Git.
$env:AWS_PROFILE = 'andeslog-academy'
aws sts get-caller-identity

az login
az account set --subscription '75b45f81-0930-4278-8fd9-896cec6eebe1'
az account show --query '{id:id,estado:state}' -o table

# Sustituye el correo por el que recibirá las alarmas.
$env:TF_VAR_notification_email = 'tu-correo@example.com'
```

Para crear la clave SSH si aún no existe, ejecuta `ssh-keygen -t ed25519 -f "$env:USERPROFILE\.ssh\id_ed25519"`. Guarda la clave privada en el equipo y no la subas a Git. La sesión de AWS Academy debe estar activa, con `aws_access_key_id`, `aws_secret_access_key` y `aws_session_token` actualizados en el perfil local. Consulta [configuración de credenciales AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-files.html).

## Levantar y comprobar

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\lab.ps1 -Action Deploy -EnableRemoteAccess -SkipIntercloudVpn -DisableInstanceRefresh
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\lab.ps1 -Action Status
```

Para preparar también el gateway VPN de recuperación en México durante el despliegue, añade `-EnableFilesDrGateway` al comando `Deploy`. Este componente genera cargos mientras exista y el script guarda un segundo perfil en `.lab-runtime\vpn\andeslog-azure-files-dr-vpn-client.zip`. En un clon nuevo que gestione un gateway regional ya existente, incluye el mismo parámetro para conservarlo. La opción configura capacidad de acceso adicional, pero **no activa un failover automático ni demuestra que la copia de archivos sea recuperable**; necesita validarse en la suscripción y con clientes Windows antes de usarla en producción.

### WAF opcional para el ERP

El WAF está **desactivado por defecto y aún no ha sido desplegado ni validado en AWS Academy**. El código prepara protección regional para el ALB principal y, si se habilita la capacidad experimental regional, también para su ALB. Requiere permisos WAF y CloudWatch y produce cargos. Avanza solo después de comprobar cada fase; las confirmaciones siguientes son declaraciones del operador, no comprobaciones automáticas:

1. Agrega `-WafPhase logging` al comando `Deploy` anterior. Genera tráfico y confirma en AWS Console → CloudWatch → Log groups → `aws-waf-logs-andeslog-lab-web` que llegan registros. Los campos de autorización, cookies, cuerpo y parámetros de consulta están protegidos en logs y muestras; las rutas e IP pueden seguir siendo sensibles.
2. Determina un límite apropiado de solicitudes por IP cada cinco minutos a partir de tráfico real y añade `-WafPhase count -WafRateLimit <limite> -WafLogsVerified`. Revisa en AWS WAF las coincidencias y los falsos positivos: las reglas solo cuentan, no bloquean.
3. Después de esa revisión, usa `-WafPhase enforce -WafRateLimit <limite> -WafLogsVerified -WafRulesReviewed`. Esta fase puede bloquear usuarios legítimos y debe supervisarse.

En el mismo equipo, el script guarda estos ajustes locales para las ejecuciones posteriores. En un clon nuevo, indica la fase y el mismo límite, junto con las confirmaciones que correspondan; el script se detiene si detecta que faltan. La protección de fase no aplica si se ejecuta Terraform directamente sin el script. WAF no añade HTTPS: el laboratorio continúa usando HTTP hasta disponer de dominio y certificado.

Espera a que termine la última fase y utiliza la URL del ERP que muestra el script. La contraseña inicial está en el archivo local `environments\lab\aws\andeslog.runtime.secret`; no lo compartas ni lo subas al repositorio. El primer despliegue puede tardar bastante por RDS y Azure VPN Gateway. Si una fase falla, se detiene y los recursos creados pueden seguir generando cargos: revisa el mensaje antes de reintentar o ejecuta la baja.

Si la base sigue activa y operas desde otro clon sin ese archivo, `Deploy` intenta recuperar el secreto de ejecución existente de AWS Secrets Manager con la sesión autorizada, lo guarda localmente con permisos NTFS restringidos al usuario y comprueba su contenido. Si ya existe un archivo local diferente, se detiene sin sobrescribirlo. La recuperación requiere permisos `secretsmanager:GetSecretValue` sobre el secreto y no recupera información después de que se haya eliminado. Se ha probado localmente con secretos ficticios; aún falta probarla en una segunda máquina con recursos reales.

Si el primer despliegue se interrumpe antes de inicializar el secreto del ERP, comprueba primero que la base sea nueva y no contenga datos que deban conservarse. Desde el mismo equipo y con su configuración local intacta puedes reanudar ese bootstrap agregando `-ResumeUninitializedBootstrap` al comando `Deploy` anterior. El script exige que el secreto aún no tenga versiones, que el ASG esté vacío y use la imagen inicial, y que la VM bootstrap siga habilitada. Estas comprobaciones no demuestran por sí solas que la base esté vacía; no uses esa opción para recuperar una base con datos existentes.

Para una comprobación pequeña de disponibilidad y latencia:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\load-test.ps1
```

La prueba usa hasta 300 solicitudes de salud, no simula usuarios reales ni certifica la capacidad para producción. Para comprobar también el acceso y un flujo de negocio desde el equipo que desplegó, ejecuta:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\test-erp-demo.ps1 -Execute
```

Esta prueba crea un almacén, un producto y una entrada de inventario sintéticos en la base activa. Reenvía la misma operación para comprobar que no se duplique y muestra el identificador; comprueba el evento en Azure por separado. Necesita el archivo local de credenciales generado durante el despliegue. El 10 de noviembre de 2026 pasó en Docker local y en el ERP desplegado; además, Azure Application Insights confirmó el evento de inventario en Blob. La prueba de carga del mismo día completó 300 solicitudes de salud sin errores, con p95 de aproximadamente 264 ms. Son resultados de un ensayo acotado y deben repetirse si se necesitan capturas actuales.

Para una prueba de recuperación de un nodo web en una ventana de práctica:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\failover-test.ps1 -Scenario WebNode -Execute
```

El comando termina una instancia y espera que el ASG la reemplace; requiere dos nodos sanos en zonas distintas. Es una prueba con interrupción controlada y puede tardar varios minutos. Para RDS existe `-Scenario Database -Execute -ConfirmNoActiveTransactions`: provoca una interrupción breve, así que úsala solo cuando no haya escrituras ni usuarios trabajando. Ambas pruebas observan readiness y estado de recursos; no certifican RTO ni integridad de todas las transacciones.

Para la VPN, importa en Azure VPN Client el XML del ZIP generado en `.lab-runtime\vpn` e inicia sesión con una identidad Microsoft Entra autorizada. El acceso SMB a Azure Files requiere credenciales separadas, como se explica en el README. Confirma por correo la suscripción SNS si deseas recibir las alarmas AWS.

## Dar de baja

Con las sesiones cloud vigentes y desde el repositorio Terraform:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\lab.ps1 -Action Destroy -ConfirmDataLoss
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\lab.ps1 -Action Status
```

**La baja elimina la base RDS y sus datos, los eventos Blob, la copia regional de Files y los demás recursos temporales gestionados.** El script procura conservar el Azure Files primario y su grupo de recursos fuera del estado; el almacenamiento conservado sigue teniendo costo. Verifica en Azure Portal que la cuenta `andeslogfs13fdbba3679` y el share `andeslog` sigan presentes, y revisa que no queden otros recursos facturables en ese grupo. Un fallo parcial no significa baja completa: vuelve a ejecutar el comando después de corregir el error y revisa ambos portales.

Como comprobación adicional de recursos habituales, ejecuta:

```powershell
aws ec2 describe-nat-gateways --region us-east-1 --filter 'Name=tag:Project,Values=AndesLog' 'Name=state,Values=pending,available,deleting' --query 'NatGateways[*].[NatGatewayId,State]' -o table
aws rds describe-db-instances --region us-east-1 --query "DBInstances[?starts_with(DBInstanceIdentifier, 'andeslog-lab')].[DBInstanceIdentifier,DBInstanceStatus]" -o table
az resource list --resource-group andeslog-lab-rg --query '[].{nombre:name,tipo:type}' -o table
```

Estas consultas no son un inventario completo de todos los servicios ni de copias de seguridad o recursos sin etiquetas. Revisa también Cost Explorer/Billing en AWS y Cost Management en Azure. La cuenta y el share conservados pueden tener cargos aunque todo lo demás esté eliminado.

## Qué demostrar y qué reconocer como pendiente

- **AWS:** ALB, ASG con dos nodos, dos zonas, RDS Multi-AZ y CloudWatch. La entrada del laboratorio es HTTP, no apta para credenciales de producción.
- **Azure:** VPN P2S, Private Endpoint de Files, share corporativo, Function de eventos y Blob. El ERP envía eventos de negocio a Azure mediante HTTPS/HMAC y outbox.
- **Conectividad entre nubes:** `-SkipIntercloudVpn` omite el túnel privado porque AWS Academy denegó `CreateCustomerGateway`. No presentar la integración HTTPS como una VPN entre nubes.
- **Resiliencia:** se probó el reemplazo de un nodo web. RDS registró eventos de failover y el ERP volvió a responder, pero no se confirmó el cambio de zona durante la observación. La recuperación regional completa, el aislamiento de escritores y los objetivos RTO ≤30 min/RPO ≤5 min siguen sin demostrarse.
- **Presupuesto:** el diseño de producción requiere capacidad redundante y cargos por uso; consulta [Presupuesto de producción](PRESUPUESTO_PRODUCCION.md), sin presentar el límite académico de USD 50 como costo de producción.

Los detalles y el estado de las pruebas están en [RESILIENCIA.md](RESILIENCIA.md). Si el entorno se ha dado de baja, los resultados de demostraciones anteriores son históricos y deben repetirse para generar nuevas evidencias.

## Orden sugerido para la rúbrica

| Criterio | Qué enseñar o explicar |
| --- | --- |
| Evolución V1 → V2 | Explica el cambio de caso a AndesLog y muestra el diagrama: ERP distribuido en dos zonas, RDS Multi-AZ e integración real con Azure. Distingue lo medido de lo que aún se propone. |
| Amenazas y vulnerabilidades | Expón los riesgos de HTTP, credenciales compartidas de Files, pérdida regional y replicación asíncrona; indica sus controles actuales y lo que falta tratar. |
| Controles de seguridad | Muestra Security Groups y RDS privado en AWS; en Azure, acceso público deshabilitado de Files/Blob, Private Endpoints y la identidad de la Function. Las alertas por correo requieren confirmación de SNS. |
| Escalabilidad y tolerancia a fallos | Muestra el ASG con dos instancias y el RDS Multi-AZ. Explica que la VPN privada AWS↔Azure y el failover regional automático siguen pendientes en la cuenta académica. |
| Evidencias y documentación | Ejecuta readiness, la prueba de negocio y la carga acotada; muestra el evento recibido en la Function o el Blob si tienes conectividad y permisos. Presenta las pruebas históricas de failover como históricas, no como un ensayo nuevo. |

Haz las capturas durante la ventana en que el laboratorio esté activo: después de la baja ya no estarán disponibles el ERP, los dashboards ni los endpoints temporales.
