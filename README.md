# AndesLog — laboratorio Terraform para AWS y Azure

Este repositorio contiene dos configuraciones Terraform independientes para desplegar el laboratorio AndesLog: una administra AWS y otra Azure. AWS aloja el balanceador, dos EC2 privadas con el contenedor del ERP y una EC2 PostgreSQL con disco EBS separado. Azure aloja WireGuard, el destino de backups Blob y, opcionalmente, una Azure Function que audita cada backup nuevo y acceso remoto Windows a Azure Files. Terraform administra infraestructura; WireGuard y los secretos de aplicación se configuran fuera del código y del estado.

> **Alcance de laboratorio académico.** El ERP es un MVP y el ALB sigue usando HTTP; no envíes credenciales por una red pública sin TLS. PostgreSQL, ambas VM VPN y el túnel WireGuard son puntos únicos de falla. No es una configuración lista para producción.

## Arquitectura

![Infraestructura multicloud desplegada](docs/arquitectura-actual.png)

[Diagrama vectorial SVG](docs/arquitectura-actual.svg) · [Documentación rápida del despliegue actual](docs/ARQUITECTURA_DESPLEGADA.md)

El diagrama refleja el despliegue verificado el 15 de octubre de 2026. Los respaldos se generan y cargan manualmente siguiendo el procedimiento de este README.

## Recursos que administra cada estado

| AWS (`environments/lab/aws`) | Azure (`environments/lab/azure`) |
| --- | --- |
| VPC, subredes públicas y privadas, rutas, Internet Gateway y NAT opcional temporal | Resource Group, VNet, subredes, NSG y rutas hacia las subredes web AWS |
| ALB HTTP, grupo de destino `/api/health`, dos EC2 ERP `t3.micro` | Una VM Ubuntu para WireGuard/recuperación, IP pública Standard y NIC con IP forwarding |
| EC2 PostgreSQL `t3.micro` y volumen EBS gp3 cifrado de 20 GiB | StorageV2 Standard LRS y contenedor Blob privado |
| EC2 WireGuard `t3.micro`; Elastic IP opcional | Regla de alerta Azure Monitor para CPU de la VM |
| Bucket S3 privado opcional, cifrado SSE-S3 y lifecycle cuando la cuenta lo permite | Autenticación de almacenamiento mediante Microsoft Entra ID |
| Alarmas y dashboard de CloudWatch | |

Con `-EnableBackupAudit`, Azure añade un plan Functions Flex Consumption, una Function Python, Event Grid, una identidad administrada, una cuenta Storage para el host y un contenedor privado `backup-audit`. El diagrama anterior representa la arquitectura base y no incluye esta extensión opcional.

En la suscripción académica usada para este laboratorio, Azure rechazó el plan Linux Consumption Y1 en `chilecentral` por falta de soporte regional y en `westus2` por cuota cero. Flex Consumption figura como disponible en `westus2`, por lo que el host de BackupAudit y su cuenta Storage usan esa región (`backup_function_location`); la VM, Azure Files y el destino Blob permanecen en `chilecentral`. Esta separación puede generar transferencias entre regiones al auditar respaldos. El plan Flex limita este laboratorio a tres instancias de 512 MiB y no reserva instancias permanentes.

Con `-EnableRemoteAccess`, la misma VM VPN Azure ejecuta también OpenVPN para usuarios. Se añade una cuenta Azure Files Standard LRS, el share SMB `andeslog`, Private Endpoint y DNS privado. Los clientes solo pueden alcanzar el endpoint de Files por TCP 445; WireGuard continúa enlazando Azure con AWS. El diagrama anterior tampoco incluye esta extensión opcional.

Las alarmas se crean sin SNS ni Action Group: se consultan en CloudWatch/Azure Monitor, pero no envían correo ni notificaciones automáticas.

Las cuatro instancias `t3.micro` de AWS consumen juntas 8 vCPU: cada `t3.micro` tiene 2 vCPU según la tabla oficial de EC2. Revisa la cuota vigente del laboratorio antes de desplegar. Las subredes usan `10.10.0.0/16` en AWS y `10.20.0.0/16` en Azure; no las cambies sin actualizar también las rutas, reglas y scripts WireGuard. [Referencia AWS](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/burstable-t3.html)

## Estructura

```text
app/                         API HTTP heredada (no es el origen del ERP)
environments/lab/aws/        Root module AWS y workspace remoto HCP Terraform
environments/lab/azure/      Root module Azure y workspace remoto HCP Terraform
functions/backup-audit/      Código Python de la Azure Function de auditoría
scripts/                     cloud-init, WireGuard, SQL y carga de backups
README.md
```

## Versiones del proyecto

Terraform y ERP son dos repositorios independientes. Publica cada cambio estable con un tag Git `vMAJOR.MINOR.PATCH` en su repositorio; conserva los tags publicados sin moverlos. Al desplegar, usa un tag de Terraform y un tag del ERP conocidos y registra esa pareja en el mensaje del tag anotado de Terraform. La rama `main` sirve para desarrollo y puede cambiar entre equipos.

`lab.ps1` construye el ERP desde la carpeta hermana y etiqueta la imagen Docker localmente. El valor de `-ErpImage` debe corresponder al tag Git que hayas seleccionado en el ERP; no hace falta publicar la imagen en GHCR para este flujo. El valor predeterminado actual es `ghcr.io/pnk-dev/andeslog-erp:v1.0.0`, así que pásalo explícitamente cuando uses otra versión.

Para preparar una versión, termina y publica los commits de ambos repositorios, crea los tags en cada uno y súbelos. Por ejemplo, desde la carpeta que contiene ambos repositorios:

```powershell
git -C .\AndesLog-ERP tag -a v1.0.1 -m "AndesLog ERP v1.0.1"
git -C .\AndesLog-ERP push origin v1.0.1
git -C .\AndesLog-Terraform tag -a v1.0.1 -m "AndesLog Terraform v1.0.1; ERP v1.0.1"
git -C .\AndesLog-Terraform push origin v1.0.1
```

Los números de versión de los dos repositorios pueden ser distintos; registra siempre la pareja exacta. Estos comandos son un ejemplo para una versión futura: crea un tag solo cuando el commit correspondiente esté listo. Para reproducir una versión publicada en otro equipo, clona ambos repositorios como hermanos y selecciona los tags documentados:

```powershell
git -C .\AndesLog-Terraform fetch --tags
git -C .\AndesLog-ERP fetch --tags
git -C .\AndesLog-Terraform switch --detach <TAG_TERRAFORM>
git -C .\AndesLog-ERP switch --detach <TAG_ERP>
Set-Location .\AndesLog-Terraform
.\scripts\lab.ps1 -Action Deploy -ErpImage "ghcr.io/pnk-dev/andeslog-erp:<TAG_ERP>"
```

Las credenciales temporales, `terraform.tfvars`, la clave SSH y `andeslog.runtime.secret` son datos locales y no forman parte de una versión Git. La infraestructura existente se identifica por los workspaces HCP, así que verifica que la organización, cuenta AWS y suscripción Azure sean las esperadas antes de usar otro equipo.

## Ciclo reproducible con un comando

`scripts/lab.ps1` encadena los dos estados Terraform y la instalación del ERP. Genera `99-runtime.auto.tfvars.json` en cada root para los valores descubiertos durante la ejecución: IP pública administrativa, IP de cada VPN, clave **pública** WireGuard, suscripción, clave SSH pública e indicador del NAT temporal. Terraform lee esos archivos automáticamente después de `terraform.tfvars`. Los overlays están excluidos de Git; las claves privadas y contraseñas nunca entran en Terraform. No edites los archivos `.tf` entre ciclos.

Configura una sola vez los valores fijos que difieran de los ejemplos en los dos `terraform.tfvars` locales: región, SKU, owner, permisos Blob y opciones académicas. El script reemplaza los valores dinámicos aunque los ejemplos contengan marcadores. Conserva la misma organización HCP y ambos workspaces en modo **Local**; así un clon usa el mismo estado remoto. Sitúa el ERP en `ERP-APP` dentro o junto a Terraform, o en una carpeta hermana `AndesLog-ERP`; también puedes pasar `-ErpDirectory`.

Instala Terraform, AWS CLI, Azure CLI, Docker Desktop con Docker iniciado y OpenSSH (`ssh` y `scp`). Inicia sesión antes de ejecutar el script:

```powershell
$env:TF_CLOUD_ORGANIZATION = "AndesLog"
terraform login
$env:AWS_PROFILE = "andeslog-academy"
aws sts get-caller-identity
az login
az account set --subscription "75b45f81-0930-4278-8fd9-896cec6eebe1"
docker info
```

Desde la raíz de `Terraform`, los comandos son:

```powershell
.\scripts\lab.ps1 -Action Status
.\scripts\lab.ps1 -Action Deploy
.\scripts\lab.ps1 -Action PreviewDestroy
.\scripts\lab.ps1 -Action Destroy -ConfirmDataLoss
.\scripts\lab.ps1 -Action Recreate -ConfirmDataLoss
```

`Deploy` sirve para un estado vacío y también para continuar después de un fallo: prepara la imagen local, crea Azure, obtiene su clave pública, crea AWS con NAT temporal, configura WireGuard, instala PostgreSQL/ERP, comprueba `/api/health` y retira el NAT. `Recreate` construye primero la imagen para descubrir fallos locales, luego destruye AWS y Azure y los vuelve a desplegar. `Destroy` elimina todos los recursos gestionados por ambos estados. **PostgreSQL/EBS y el contenido de Blob se pierden**; haz backup antes si necesitas conservar datos. El script no automatiza la restauración de datos ni genera credenciales académicas nuevas.

Si activaste el bucket S3 opcional y contiene objetos, Terraform puede rechazar su destrucción porque `force_destroy=false`; vacía el bucket de forma consciente y vuelve a ejecutar `Destroy`. El comando solo elimina recursos que figuran en estos dos estados HCP; recursos creados a mano fuera de Terraform se revisan aparte.

Si falla una fase, se detiene y deja lo ya creado para diagnosticar o reanudar. Si el NAT temporal permanece activo, puedes retirarlo con:

```powershell
.\scripts\lab.ps1 -Action CleanupNat
```

En Windows el script guarda la configuración SSH temporal bajo `%TEMP%`, que debe tener una ruta sin espacios para que el `ProxyJump` de OpenSSH abra correctamente su configuración al conectar con las EC2 privadas. La carpeta temporal se elimina al terminar; el proyecto puede estar en una ruta con espacios.

El script mantiene `environments/lab/aws/andeslog.runtime.secret` fuera de Git con la contraseña inicial de `admin` y los secretos del ERP; si no existe, los genera. Ese archivo se conserva tras `Destroy`. Para usar otra organización HCP, cuenta AWS o suscripción Azure, pasa `-ExpectedHcpOrganization`, `-ExpectedAwsAccount` o `-ExpectedAzureSubscription`; para otra IP o clave, `-AdminPublicCidr "X.X.X.X/32"` y `-SshPrivateKey "C:\ruta\id_ed25519"`. Cambiar de cuenta cambia los recursos disponibles, pero no reutilices un workspace HCP con estado de otra cuenta sin revisar su destino. La imagen GHCR privada se construye desde el ERP local, se exporta con Docker y se carga por SSH; no se requiere publicar ni copiar un token GHCR a las VM.

Si clonas el repositorio en otro equipo **para continuar una base existente**, transfiere `andeslog.runtime.secret` y la clave SSH privada correspondiente por un canal seguro: el script se detiene cuando detecta una base AWS sin el secreto, y las VM existentes solo aceptan la clave autorizada en su creación. Después de una destrucción completa, puedes generar un secreto y una clave nuevos para el siguiente `Deploy`. Las credenciales de AWS Academy caducan; vuelve a copiarlas a tu perfil AWS y renueva `az login` cuando corresponda.

La sección manual siguiente queda como procedimiento de diagnóstico y recuperación. El camino habitual es el comando de arriba.

## Qué cambia al clonar o renovar una sesión

| Valor | Cuándo cambia | Dónde se configura |
| --- | --- | --- |
| Organización HCP y workspaces | Permanecen iguales si el clon administra **la misma infraestructura**. Usa otra organización o workspaces separados para otro laboratorio. | `TF_CLOUD_ORGANIZATION` (por defecto `AndesLog`); los workspaces `andeslog-lab-aws` y `andeslog-lab-azure` están en `versions.tf`. `terraform login` guarda el token localmente. |
| Cuenta AWS y sus tres credenciales temporales | El ID de cuenta permanece mientras uses la misma cuenta; access key, secret key y session token caducan y se renuevan. | Perfil local `~/.aws/credentials` seleccionado por `AWS_PROFILE`, o variables `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` y `AWS_SESSION_TOKEN`. Nunca en el repositorio. `-ExpectedAwsAccount` comprueba el ID. |
| Suscripción y sesión Azure | El ID permanece mientras uses la misma suscripción; la sesión de `az login` se renueva. | `az login`, `az account set --subscription <ID>` y `-ExpectedAzureSubscription`; el script pasa el ID real al overlay local de Terraform. |
| IP pública administrativa | Puede variar por red, VPN o proveedor de Internet. | El script la detecta al ejecutar; `-AdminPublicCidr` permite fijarla. Las reglas SSH quedan limitadas a esa `/32`. |
| Par de claves SSH | Es local al equipo; para continuar con VM existentes conserva la **misma clave privada**. | Por defecto `~/.ssh/id_ed25519`; usa `-SshPrivateKey` para otra ruta. Solo la clave pública entra en Terraform. |
| IP públicas de VPN y clave pública WireGuard | Cambian cuando se recrean las VM. | `lab.ps1` las descubre y escribe `99-runtime.auto.tfvars.json`, ignorado por Git. |
| Imagen y código del ERP | Cambian al publicar una versión del ERP o elegir otra ubicación de clon. | El script busca `ERP-APP` o `AndesLog-ERP` y acepta `-ErpDirectory`; `-ErpImage` fija el tag Docker. La imagen se construye localmente y se carga por SSH. |
| Contraseñas ERP/PostgreSQL | Se generan en el primer despliegue; deben conservarse mientras la base desplegada exista. | `environments/lab/aws/andeslog.runtime.secret`, ignorado por Git. Tras destruir por completo se puede generar uno nuevo. |
| Región, tamaño de VM, CIDR y opciones académicas | Son parámetros de diseño; cambia solo si la cuenta o la arquitectura lo exigen. | `terraform.tfvars` local en cada root; parte de `terraform.tfvars.example`. Algunos CIDR tienen validación porque las rutas y subredes actuales son fijas. |
| Etiqueta `ttl_date` | Fecha opcional de revisión; **no** programa una destrucción. | `terraform.tfvars` local; los ejemplos la dejan vacía para que un clon futuro no herede una fecha vencida. |

Las variables AWS de entorno prevalecen sobre las de un perfil: si usas `AWS_PROFILE`, elimina de esa terminal las variables temporales antiguas que pudieran seleccionar otra sesión. Comprueba siempre `aws sts get-caller-identity` y `az account show` antes de `Deploy`. [Credenciales AWS](https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-envvars.html) · [Suscripciones Azure CLI](https://learn.microsoft.com/en-us/cli/azure/manage-azure-subscriptions-azure-cli) · [Estado HCP con ejecución local](https://developer.hashicorp.com/terraform/cloud-docs/workspaces/settings).

AWS y Azure tienen estados remotos separados en `andeslog-lab-aws` y `andeslog-lab-azure`. El nombre de la organización HCP se lee desde `TF_CLOUD_ORGANIZATION`; el script espera `AndesLog` por defecto y permite indicar otra con `-ExpectedHcpOrganization`. La aplicación ERP vive en un repositorio separado. Terraform apunta a su imagen de GHCR; el script carga la imagen construida localmente en ambas EC2 web. No copies el estado de un proveedor al otro.

## Clonar este proyecto en otro equipo

Terraform y ERP se publican como repositorios separados. Clónalos como carpetas hermanas para que el script encuentre el Dockerfile del ERP. Necesitas acceso a la misma organización HCP Terraform. Clonar los repositorios no clona sus credenciales ni el estado remoto.

```powershell
git clone <URL_REPOSITORIO_TERRAFORM> AndesLog-Terraform
git clone <URL_REPOSITORIO_ERP> AndesLog-ERP
Set-Location .\AndesLog-Terraform
```

Completa el inicio de sesión local en HCP y los proveedores. `TF_CLOUD_ORGANIZATION` es el nombre de la organización, no un token ni una contraseña:

```powershell
$env:TF_CLOUD_ORGANIZATION = "AndesLog"
terraform login
$env:AWS_PROFILE = "andeslog-academy"
aws sts get-caller-identity
az login
az account set --subscription "<SUBSCRIPTION_ID>"
az account show --query "{subscription:id, name:name}" -o table
```

En cada root, inicializa HCP Terraform. En el primer `init`, si Terraform pregunta si debe migrar el estado local existente, acepta solo después de comprobar que el destino es la organización y workspace esperados. Comprueba el estado remoto antes de aplicar desde otro equipo.

```powershell
Push-Location .\environments\lab\aws
terraform init
Pop-Location
Push-Location .\environments\lab\azure
terraform init
Pop-Location
```

`terraform init` crea los workspaces indicados si no existen y tienes permisos para crearlos. En HCP Terraform, abre ambos workspaces y configura **Settings → General → Execution Mode → Local** antes de cualquier `plan` o `apply`. Así el estado queda en HCP, mientras Terraform y los proveedores AWS/Azure ejecutan localmente con las sesiones temporales del equipo. Cada máquina nueva debe repetir el login de HCP, AWS y Azure; nunca compartas tokens.

Los archivos `terraform.tfvars` se crean desde los ejemplos para cada clon y permanecen locales. `.gitignore` evita que se versionen y `.terraformignore` los excluye de la carga de configuración a HCP. Los archivos `.terraform.lock.hcl` sí se versionan para fijar las versiones de providers.

Para publicar cambios posteriores, revisa los archivos preparados antes del commit y sube la rama correspondiente:

```powershell
git add -A
git status --short
git diff --cached --name-only
git commit -m "Describe el cambio"
git push
```

Confirma que `terraform.tfvars`, archivos `*.tfstate*`, planes, `.terraform/`, llaves y credenciales no aparezcan en `git status` ni en el listado preparado. Revisa los archivos antes de cada commit; `.gitignore` los excluye, pero no elimina archivos que ya estuvieran versionados.

Si en este checkout Git muestra `detected dubious ownership` por el propietario con que se creó `.git`, y reconoces esta carpeta como propia, registra **solo esta ruta** como segura antes de los comandos anteriores:

```powershell
git config --global --add safe.directory (Get-Location).Path
```

Un clon nuevo creado por tu usuario normalmente no necesita esa excepción.

## Requisitos y comprobaciones académicas

- Terraform CLI `>= 1.7`, AWS CLI v2, Azure CLI (`az`), OpenSSH y conexión HTTPS a Terraform Registry y a las APIs de las nubes.
- Cuenta de HCP Terraform con permisos para crear y usar dos workspaces. Ejecuta `terraform login` una vez en cada equipo y define `TF_CLOUD_ORGANIZATION`; HCP guarda el token localmente fuera del repositorio. El plan Free vigente admite hasta 500 recursos administrados sin cargo, sujeto a sus condiciones actuales.
- Una cuenta AWS con acceso temporal que permita EC2, VPC, EBS, ELBv2 y CloudWatch en la región elegida. S3 es opcional; algunas cuentas Academy bloquean la lectura de Object Lock que el proveedor AWS de Terraform necesita.
- Una suscripción Azure activa con permisos para crear Resource Groups, redes, NIC/IP pública, VM, cuenta de almacenamiento, contenedor Blob y alertas de Monitor.
- Una clave SSH: en las variables se configura solamente la **clave pública** (`.pub`). La clave privada debe permanecer en el perfil local `.ssh`.
- Instalación oficial para Windows: [Terraform CLI](https://developer.hashicorp.com/terraform/tutorials/aws-get-started/install-cli), [AWS CLI v2](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) y [Azure CLI](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli-windows?view=azure-cli-lts). Abre una nueva terminal después de instalar y confirma con `terraform version`, `aws --version`, `az version` y `ssh -V`.
- Antes de `apply`, confirma en las consolas académicas: créditos disponibles, vigencia de la sesión, cuotas de vCPU/VM/disco/IP, SKUs permitidas, regiones habilitadas, política de recursos y permisos de creación. Un plan válido no garantiza que la política académica permita ejecutar cada API.
- La suscripción Azure usada en este despliegue permite `chilecentral`, `canadacentral`, `westus2`, `westus` y `mexicocentral`; el laboratorio queda configurado por defecto en `chilecentral`. La disponibilidad real de capacidad para cada SKU puede variar.
- En AWS puede faltar el service-linked role que necesita el ALB. Terraform no crea usuarios/roles/políticas IAM de AWS ni roles personalizados de Azure. `create_blob_role_assignment` sigue desactivado por defecto. La extensión opcional BackupAudit crea además un rol de datos Blob para su identidad administrada.
- En Azure este root configura `resource_provider_registrations = "none"`. Verifica que estén registrados `Microsoft.Compute`, `Microsoft.Network`, `Microsoft.Storage`, `Microsoft.Insights` y `Microsoft.Authorization`; el proveedor no intentará registrarlos por ti. Si activas BackupAudit, `lab.ps1` intenta registrar también `Microsoft.Web`, `Microsoft.EventGrid` y `Microsoft.ManagedIdentity`.
- La creación del contenedor Blob usa Microsoft Entra ID y el valor predeterminado `create_blob_role_assignment = false`, de acuerdo con la especificación: Terraform no asigna roles por defecto. La identidad que ejecuta Terraform necesita el rol **Storage Blob Data Contributor** existente en la cuenta o en un scope superior. Si no existe y la oferta académica permite asignar roles, puedes activar `create_blob_role_assignment = true` en el `terraform.tfvars` de Azure; requiere `Microsoft.Authorization/roleAssignments/write` (por ejemplo, Owner o User Access Administrator en ese scope). Después de una asignación, la propagación puede tardar varios minutos. [Microsoft documenta los roles y permisos de Blob](https://learn.microsoft.com/en-us/azure/storage/blobs/assign-azure-role-data-access?tabs=portal); [HashiCorp documenta `azurerm_role_assignment`](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/role_assignment).
- El contenedor Blob tiene acceso anónimo desactivado. La cuenta acepta tráfico desde redes públicas para permitir uploads autenticados desde tu equipo; no se crea Private Endpoint en esta versión.
- Azure permite por defecto el DNS de plataforma; no se crea una regla `Allow` para `AzurePlatformDNS`, ya que solo se admiten reglas `Deny` explícitas para bloquear ese tráfico. El bloqueo general de salida se limita al tag `Internet`.
- El NAT Gateway AWS es opcional, temporal y tiene costo. Elastic IP y las IP públicas, ALB, VM, almacenamiento, tráfico y monitorización también pueden consumir créditos o estar bloqueados. Verifica la política y el costo estimado antes de aprobar un plan.

Comandos de lectura para comprobar Azure:

```powershell
az account show --query "{subscription:id, name:name, tenant:tenantId}" -o table
az provider show --namespace Microsoft.Compute --query registrationState -o tsv
az provider show --namespace Microsoft.Network --query registrationState -o tsv
az provider show --namespace Microsoft.Storage --query registrationState -o tsv
az provider show --namespace Microsoft.Insights --query registrationState -o tsv
```

La especificación evita crear identidades privilegiadas desde Terraform y usa permisos preconcedidos cuando estén disponibles. La asignación opcional Blob solo debe activarse si el laboratorio permite `Microsoft.Authorization/roleAssignments/write`.

## Credenciales temporales

Además de HCP Terraform, las credenciales de AWS Academy y Azure for Students se obtienen e instalan por separado en cada máquina. HCP solo aloja el estado: selecciona **Local** como modo de ejecución en ambos workspaces para que tus sesiones AWS CLI/Azure CLI locales sean las que se utilicen.

### AWS Academy / AWS CLI

No se necesita una API key adicional para Terraform: AWS usa el perfil temporal de AWS CLI y Azure el inicio de sesión de Azure CLI. No pongas claves, tokens, contraseñas ni secretos en `terraform.tfvars`, archivos `.tf` o en el repositorio. Usa el perfil local de AWS CLI, fuera de la carpeta del proyecto:

`%USERPROFILE%\.aws\credentials`

Agrega o actualiza este perfil con los valores temporales que entrega la consola del laboratorio:

```ini
[andeslog-academy]
aws_access_key_id = PEGAR_ACCESS_KEY_TEMPORAL
aws_secret_access_key = PEGAR_SECRET_KEY_TEMPORAL
aws_session_token = PEGAR_SESSION_TOKEN_TEMPORAL
```

El `aws_session_token` es obligatorio para credenciales temporales. El archivo se guarda en texto plano: protege sus permisos con tu cuenta de Windows y no lo sincronices ni lo compartas. En PowerShell, selecciona el perfil para la sesión actual y confirma que sigue válido:

```powershell
$env:AWS_PROFILE = "andeslog-academy"
aws sts get-caller-identity
```

Al vencer o reiniciarse la sesión académica, reemplaza los tres valores con el nuevo conjunto temporal y vuelve a verificar. La configuración AWS de Terraform usa la cadena de credenciales estándar del provider; no necesita claves dentro de los archivos Terraform.

### Azure for Students / Azure CLI

Inicia sesión con la identidad autorizada y selecciona la suscripción correcta:

```powershell
az login
az account set --subscription "<SUBSCRIPTION_ID>"
az account show --query "{subscription:id, name:name}" -o table
```

AzureRM usa el inicio de sesión local de Azure CLI. No crees `client_secret`, `ARM_CLIENT_SECRET` ni una app registration para este laboratorio. En el `terraform.tfvars` de Azure solo se copia el identificador de suscripción; ese ID no es una contraseña.

La documentación del provider desaconseja escribir credenciales AWS directamente en la configuración. En Azure, el método de inicio local documentado es Azure CLI; el provider requiere indicar la suscripción con la versión 4 o posterior. Referencias: [autenticación AWS del provider](https://registry.terraform.io/providers/hashicorp/aws/6.24.0/docs#authentication-and-configuration), [credenciales temporales AWS](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_credentials_temp_use-resources.html), [Azure CLI con AzureRM](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/guides/azure_cli) y [configuración del provider AzureRM](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/index).

## Preparar variables

Desde la raíz del proyecto, crea una copia local de cada ejemplo:

```powershell
Copy-Item environments/lab/aws/terraform.tfvars.example environments/lab/aws/terraform.tfvars
Copy-Item environments/lab/azure/terraform.tfvars.example environments/lab/azure/terraform.tfvars
```

Edita los dos `terraform.tfvars` locales y sustituye:

- `erp_image` en AWS: tag versionado o digest SHA-256 de una imagen en un registro. El bootstrap intenta `docker pull` sin `docker login`; para arrancar automáticamente, la imagen debe ser pública. Con el paquete GHCR privado actual, carga el archivo Docker en cada EC2 web antes de iniciar `andeslog-web.service`. No uses `latest`.
- `create_blob_role_assignment` en Azure: déjalo en `false` cuando la identidad ya tenga el rol de datos necesario; actívalo solo si necesitas crear el rol y la cuenta académica autoriza esa operación.
- `admin_public_cidr`: tu IP pública actual en formato IPv4 `/32` (no dejes `203.0.113.10/32`, es un rango reservado para documentación). Este valor habilita SSH solo desde esa IP al peer VPN.
- `ssh_public_key` de AWS y `admin_ssh_public_key` de Azure: contenido de tu archivo público, por ejemplo `C:\Users\USUARIO\.ssh\id_ed25519.pub`.
- `project` acepta 3–20 caracteres y `environment` 2–7; ambos deben usar minúsculas, números o guiones, y empezar/terminar con letra o número. El límite de `environment` también mantiene bajo el máximo de longitud de nombres ALB/target group de AWS.
- `ttl_date`, `aws_region`, `azure_location`, `subscription_id`, SKU y nombres según las restricciones confirmadas para tus cuentas.
- `azure_peer_public_cidr` en AWS y `aws_peer_public_cidr` en Azure se completan durante los pasos de despliegue. Usa la IP pública del peer opuesto con `/32`.
- `azure_wireguard_public_key` en AWS debe contener la clave pública WireGuard generada en la VM Azure. La clave privada permanece dentro de `/etc/wireguard` en la VM.
- La cuenta Storage de Azure se nombra de forma determinista usando el prefijo del proyecto y un fragmento derivado de la suscripción. Si ese nombre ya estuviera ocupado globalmente, ajusta `project` antes del primer `apply`.
- `enable_temporary_nat = true` solo para el primer bootstrap de las EC2 privadas. Déjalo en `false` si tu cuenta no permite el NAT o si ya usas una AMI preparada con los paquetes instalados.
- Las EC2 web nuevas necesitan salida HTTPS temporal para instalar Docker y descargar la imagen. Una EC2 PostgreSQL reemplazada necesita descargar PostgreSQL. Mantén NAT temporal hasta que termine el bootstrap y luego elimínalo con un apply revisado.
- Considera `create_vpn_eip = false` salvo que el Learner Lab permita crear y asociar Elastic IP.

No guardes contraseñas PostgreSQL ni llaves privadas de WireGuard en variables Terraform. `terraform.tfvars`, estado local, planes y directorios `.terraform` están excluidos de Git. El estado remoto también puede contener metadatos sensibles; HCP mantiene su propio historial. Conserva el `.terraform.lock.hcl` de cada root. No incluyas estado ni planes en Git/Drive ni los compartas.

## Despliegue paso a paso

Antes del primer `init`, ejecuta `terraform login`, define `$env:TF_CLOUD_ORGANIZATION` y completa la creación/configuración local de ambos workspaces como se describe arriba. Terraform no crea ambos proveedores en una única ejecución. Primero se necesitan las direcciones IP de los peers para fijar las reglas de firewall. En PowerShell, entra al directorio de cada root con `Push-Location` y ejecuta Terraform allí; este método también evita errores con la opción `-chdir`.

### 1. Desplegar Azure primero

En el archivo local `environments/lab/azure/terraform.tfvars`, deja inicialmente `aws_peer_public_cidr = ""`. Confirma que la suscripción, región, SKU y permisos están correctos y ejecuta:

```powershell
Push-Location .\environments\lab\azure
terraform init
terraform fmt -check -recursive
terraform validate
terraform plan -out=azure.tfplan
terraform apply azure.tfplan
Pop-Location
```

Revisa el plan completo antes de confirmar. Obtén la IP pública Azure:

```powershell
Push-Location .\environments\lab\azure
$azureVpnIp = terraform output -raw vpn_public_ip
Pop-Location
```

Copia esa IP seguida de `/32` en `azure_peer_public_cidr` del `terraform.tfvars` AWS. Antes de desplegar AWS, genera la clave privada WireGuard en Azure y copia solo la clave pública:

```powershell
$sshKey = "$env:USERPROFILE\.ssh\id_ed25519"
Push-Location .\environments\lab\azure
$azureVpnIp = terraform output -raw vpn_public_ip
Pop-Location
ssh -i $sshKey "azureuser@$azureVpnIp" "sudo install -d -o root -g root -m 0700 /etc/wireguard; if ! sudo test -s /etc/wireguard/privatekey; then sudo wg genkey | sudo tee /etc/wireguard/privatekey >/dev/null; sudo chmod 0600 /etc/wireguard/privatekey; fi; sudo cat /etc/wireguard/privatekey | wg pubkey"
```

Guarda el resultado público en `azure_wireguard_public_key` de AWS.

### 2. Desplegar AWS

Confirma en `environments/lab/aws/terraform.tfvars` el perfil `AWS_PROFILE`, la región, la IP Azure `/32`, su clave pública WireGuard, la clave pública SSH y `enable_temporary_nat = true` para el primer bootstrap (si la cuenta lo permite). AWS configura WireGuard al iniciar la VM VPN. Ejecuta:

```powershell
Push-Location .\environments\lab\aws
terraform init
terraform fmt -check -recursive
terraform validate
terraform plan -out=aws.tfplan
terraform apply aws.tfplan
Pop-Location
```

Si `enable_temporary_nat = true`, el plan debe incluir el NAT Gateway y la EIP temporales de bootstrap. Una EIP adicional para VPN aparece solo si `create_vpn_eip = true`. Revisa el plan completo antes de continuar. Obtén la IP pública AWS:

```powershell
Push-Location .\environments\lab\aws
$awsVpnIp = terraform output -raw vpn_public_ip
Pop-Location
```

Copia esa IP con `/32` en `aws_peer_public_cidr` del `terraform.tfvars` Azure y actualiza ese root:

```powershell
Push-Location .\environments\lab\azure
terraform plan -out=azure-peer.tfplan
terraform apply azure-peer.tfplan
Pop-Location
```

Obtén la clave pública AWS del registro cloud-init y termina la configuración del peer Azure. El `vpn_instance_id` es un output Terraform:

```powershell
$sshKey = "$env:USERPROFILE\.ssh\id_ed25519"
Push-Location .\environments\lab\aws
$awsVpnId = terraform output -raw vpn_instance_id
$awsConsole = aws ec2 get-console-output --region us-east-1 --instance-id $awsVpnId --latest --query Output --output text
$awsWireGuardPublicKey = [regex]::Match($awsConsole, 'ANDESLOG_WIREGUARD_PUBLIC_KEY=([A-Za-z0-9+/]{43}=)').Groups[1].Value
$awsVpnIp = terraform output -raw vpn_public_ip
Pop-Location
Push-Location .\environments\lab\azure
$azureVpnIp = terraform output -raw vpn_public_ip
Pop-Location
scp -i $sshKey .\scripts\configure-wireguard.sh "azureuser@${azureVpnIp}:/tmp/configure-wireguard.sh"
ssh -i $sshKey "azureuser@$azureVpnIp" "sudo bash /tmp/configure-wireguard.sh azure $awsWireGuardPublicKey $awsVpnIp"
```

Verifica el handshake con `ssh -i $sshKey "azureuser@$azureVpnIp" "sudo wg show wg0"`. La salida debe incluir `latest handshake`. Comprueba ambos servidores desde Azure usando el origen de la VM VPN:

```powershell
ssh -i $sshKey "azureuser@$azureVpnIp" "curl --interface 10.20.1.10 http://10.10.11.10:8080/api/health; curl --interface 10.20.1.10 http://10.10.12.10:8080/api/health"
```

Las reglas AWS permiten HTTP 8080 desde `10.20.0.0/16` por WireGuard y desde el `/32` de la VM VPN Azure para pruebas. Las llaves privadas WireGuard nunca se guardan en Terraform ni se transfieren entre peers.

Si AWS usa una IP pública dinámica y la instancia VPN se reemplaza o cambia de dirección, actualiza el `/32` del otro peer y vuelve a aplicar el root correspondiente.

### 3. Quitar el NAT temporal

El NAT existe únicamente para que `cloud-init` instale paquetes en las EC2 web y PostgreSQL, que están en subredes privadas. Cuando el bootstrap haya concluido y las instancias estén listas, cambia `enable_temporary_nat` a `false` en AWS y aplica el cambio:

```powershell
Push-Location .\environments\lab\aws
terraform plan -out=aws-no-nat.tfplan
terraform apply aws-no-nat.tfplan
Pop-Location
```

Elimina el NAT tan pronto como ya no sea necesario: el cargo se calcula por uso/tiempo aunque el tráfico sea bajo. Si el bootstrap falló, consulta los logs cloud-init por SSH y resuelve el acceso a paquetes antes de retirar el NAT. Los scripts actuales necesitan descargar paquetes para las EC2 privadas; si la cuenta académica bloquea NAT, detén este flujo y adapta el bootstrap a una imagen institucional con los paquetes requeridos o a otra salida a Internet que autorice el curso.

## Configurar el enlace WireGuard

AWS recibe la clave pública de Azure por `azure_wireguard_public_key` y crea su configuración durante cloud-init. Azure se termina de emparejar por SSH después de actualizar su regla `/32` con la IP pública AWS. Conserva las claves privadas solo en `/etc/wireguard` dentro de cada VM. Si la IP pública de un peer cambia, vuelve a actualizar el `/32` en el proveedor opuesto y repite los pasos de emparejamiento. La ruta de PostgreSQL hacia Azure permanece deshabilitada por defecto.

## Inicializar PostgreSQL y configurar el ERP

PostgreSQL no usa una contraseña predeterminada codificada. Sustituye rutas de clave e IP en estos ejemplos. El usuario Ubuntu de las imágenes es `ubuntu`:

```powershell
$sshKey = "$env:USERPROFILE\.ssh\id_ed25519"
Push-Location .\environments\lab\aws
$awsVpnIp = terraform output -raw vpn_public_ip
Pop-Location
ssh -i $sshKey "ubuntu@$awsVpnIp"
```

Para una conexión SSH directa a la EC2 de base de datos a través del peer VPN (el mismo patrón sirve para las dos EC2 web):

```powershell
ssh -i $sshKey -J "ubuntu@$awsVpnIp" ubuntu@10.10.21.10
```

En el host DB crea el rol y la base para el ERP; la contraseña se introduce interactivamente:

Para crear rol y base, ejecuta `sudo -u postgres psql` desde el host DB e ingresa estos comandos interactivos:

```sql
CREATE ROLE andeslog_app LOGIN;
\password andeslog_app
CREATE DATABASE andeslog OWNER andeslog_app;
\q
```

No ejecutes `scripts/init-db.sql`: corresponde a la API antigua. Las tablas del ERP se crean con Flask-Migrate desde la misma imagen del contenedor.

### Configurar el contenedor de AndesLog ERP

Terraform instala Docker, descarga la imagen `erp_image` y deja preparado `andeslog-web.service`. La imagen se construye/publica desde `ERP-APP`; antes del build, el contexto debe excluir `.env`, `tests/`, `.pytest_cache/`, `__pycache__/` y datos locales mediante `.dockerignore`.

En **cada EC2 web**, crea `/etc/andeslog-app/erp.env` como archivo root con permisos `0600`. Para el ALB HTTP de este laboratorio, configura `APP_ENV=development`; la aplicación así no marca la cookie de sesión como `Secure`, que los navegadores no envían por HTTP. Esto expone las credenciales y sesiones al tráfico sin cifrar: úsalo solo en el laboratorio académico. Para un despliegue HTTPS, configura primero TLS en el ALB y usa `APP_ENV=production`. Añade también `SECRET_KEY`, `DATABASE_URL`, `BOOTSTRAP_ADMIN_USERNAME` y `BOOTSTRAP_ADMIN_PASSWORD`. No pongas estos secretos en Terraform, `terraform.tfvars`, user data, la línea de comandos ni en el historial del shell. Usa la clave del rol PostgreSQL y codifica caracteres reservados de la contraseña al construir `DATABASE_URL`.

En una sola EC2 web, ejecuta las migraciones y el alta inicial usando el tag de imagen aprobado. Estas operaciones son de una sola ejecución, no deben ejecutarse a la vez en las dos réplicas:

```bash
sudo docker run --rm --env-file /etc/andeslog-app/erp.env <imagen-erp:tag> flask --app app:create_app db upgrade
sudo docker run --rm --env-file /etc/andeslog-app/erp.env <imagen-erp:tag> flask --app app:create_app seed-admin
```

Luego, en ambas EC2 web, ejecuta `sudo systemctl start andeslog-web`. Verifica `http://<alb_dns_name>/api/health`, login y los flujos de ERP. El health check del ALB valida que Flask responde; no comprueba por sí mismo el acceso a la base de datos.

**Cambio con impacto:** `user_data_replace_on_change = true` reemplaza las EC2 web si cambia su bootstrap. La EC2 PostgreSQL ignora cambios posteriores en `user_data`, por lo que corregir su script no lo reaplica automáticamente. Antes de modificar recursos de datos, respalda la base y revisa el plan junto con el volumen EBS.

El acceso web de muestra usa HTTP en el puerto 80 del ALB para el laboratorio. No envíes información sensible por esa API ni la uses como servicio productivo.

## VPN de usuarios Windows y carpeta corporativa Azure Files

Activa esta extensión al desplegar desde un clon, sin editar el código:

```powershell
.\scripts\lab.ps1 -Action Deploy -EnableRemoteAccess
```

Puedes combinar `-EnableRemoteAccess` y `-EnableBackupAudit`. El script conserva la elección en el overlay local ignorado por Git; `Recreate` la reaplica y `Destroy` elimina la cuenta Files, el share y el endpoint privado. OpenVPN se instala en la VM Azure ya existente, junto a WireGuard. El perfil de cliente se guarda en `.lab-runtime/andeslog-windows.ovpn` (ignorado por Git); incluye la clave TLS compartida y debes distribuirlo por un canal seguro. **Una contraseña sin ese perfil no conecta.** Cada persona debe tener su propio usuario VPN; no compartas la cuenta administrativa SSH.

Crear o actualizar un usuario VPN desde la máquina administradora:

```powershell
.\scripts\remote-user.ps1 -Action Add -Username vpn_ana
```

El script pide una contraseña de al menos 12 caracteres y la envía por SSH sin guardarla en Terraform. Los nombres VPN llevan el prefijo `vpn_`. Para revocar el acceso, ejecuta `.\scripts\remote-user.ps1 -Action Disable -Username vpn_ana`. La revocación reinicia OpenVPN para cerrar sesiones activas, lo que desconecta brevemente a todos los clientes. La clave de Azure Files se gestiona por separado.

En el PC Windows cliente, instala [OpenVPN Connect](https://openvpn.net/client/), importa `andeslog-windows.ovpn` y conecta con su usuario y contraseña VPN. Después verifica que el nombre de Azure Files resuelve a la IP privada de `files_private_ip` y que TCP 445 responde:

```powershell
$account = '<files_storage_account_name>'
Resolve-DnsName "$account.file.core.windows.net"
Test-NetConnection "$account.file.core.windows.net" -Port 445
net use Z: "\\${account}.file.core.windows.net\andeslog" /user:"Azure\$account" * /persistent:yes
```

`net use` solicitará una **segunda credencial**: la clave de la cuenta Storage de Azure Files, obtenida por el administrador en **Storage account → Access keys** del portal de Azure. Es una clave amplia para esa cuenta; mantenemos una cuenta separada dedicada al share y su endpoint público está deshabilitado. No pegues la clave en el comando, en `terraform.tfvars`, en Git ni en el perfil VPN. Al conectar, `Z:` aparece en el Explorador de archivos. El usuario que necesite otra letra puede cambiarla. Este esquema de laboratorio no ofrece permisos individuales dentro del share; para un entorno corporativo final habría que integrar identidad de archivos por usuario.

Desde el root Terraform puedes consultar `terraform output -raw files_storage_account_name` y `terraform output -raw files_private_ip`. Si tu laptop ya tiene infraestructura activa, el mismo `Deploy -EnableRemoteAccess` agrega la extensión sin cambiar el estado HCP de AWS; conserva el secreto ERP y la clave SSH correspondientes. La cuenta Azure for Students debe admitir Private Endpoint, Azure Files y cuotas disponibles en la región. Azure Files y Private Endpoint pueden consumir créditos mientras existan. Esta solución usa una sola VM VPN, que sigue siendo punto único de falla. [Azure Files sobre VPN](https://learn.microsoft.com/en-us/azure/storage/files/storage-files-configure-p2s-vpn-windows) · [Red y puerto SMB](https://learn.microsoft.com/en-us/azure/storage/files/storage-files-networking-overview) · [Autenticación OpenVPN](https://openvpn.net/community-docs/using-alternative-authentication-methods/)

## Respaldos hacia Azure Blob y S3 opcional

Azure Blob es el destino de respaldos disponible en la cuenta académica actual. AWS Academy denegó con un SCP explícito `s3:GetBucketObjectLockConfiguration`, que el proveedor AWS de Terraform solicita al leer `aws_s3_bucket`; una política IAM del usuario no puede superar ese deny. Por eso `enable_aws_s3_backups` está en `false` para este laboratorio y el bucket vacío creado durante el primer intento se eliminó. El bucket S3 sigue disponible como opción para una cuenta que permita esa acción; actívala con `enable_aws_s3_backups = true` y configura `enable_s3_versioning` según necesidad. El contenedor Blob no tiene regla de expiración automática en este root; elimina respaldos antiguos según la política de retención acordada para el curso.

La carga es manual: estos recursos y el script no programan snapshots ni replican la base automáticamente. Por eso el RPO/RTO del laboratorio depende de la frecuencia de `pg_dump`, la subida a ambos destinos y el tiempo de restauración que mida el equipo; no hay una garantía automática de RPO/RTO.

Para producir un dump en el host DB, transferirlo al equipo y retirar la copia temporal del servidor, usa el mismo `-i $sshKey -J "ubuntu@$awsVpnIp"` de la sección anterior:

```powershell
ssh -i $sshKey -J "ubuntu@$awsVpnIp" ubuntu@10.10.21.10 "sudo -u postgres pg_dump -Fc -f /tmp/andeslog.dump andeslog && sudo chown ubuntu:ubuntu /tmp/andeslog.dump && sudo chmod 600 /tmp/andeslog.dump"
scp -i $sshKey -o "ProxyJump=ubuntu@$awsVpnIp" ubuntu@10.10.21.10:/tmp/andeslog.dump "$env:USERPROFILE\Downloads\andeslog.dump"
ssh -i $sshKey -J "ubuntu@$awsVpnIp" ubuntu@10.10.21.10 "sudo rm -f /tmp/andeslog.dump"
```

Resguarda el dump localmente; contiene datos de aplicación.

Después de crear un archivo de respaldo PostgreSQL en tu equipo, confirma que Azure CLI está autenticada y que Azure tiene el rol de datos Blob requerido. Para la cuenta académica actual, usa el script desde PowerShell:

```powershell
.\scripts\upload-backup.ps1 `
  -FilePath "C:\ruta\segura\andeslog.dump" `
  -AzureStorageAccount "<storage_account_name>"
```

Obtén el nombre desde el root Azure con `Push-Location .\environments\lab\azure; terraform output -raw storage_account_name; Pop-Location`. Si `enable_aws_s3_backups` está activado en una cuenta compatible, obtén `backup_bucket_name` del root AWS de la misma forma y pasa `-S3Bucket <nombre>`; el script carga entonces a ambos destinos.

### Azure Function BackupAudit (opcional)

Para incluir la auditoría serverless en un despliegue nuevo o existente, usa el mismo comando del laboratorio con `-EnableBackupAudit`:

```powershell
.\scripts\lab.ps1 -Action Deploy -EnableBackupAudit
```

El script guarda esta elección en un overlay local ignorado por Git; `Deploy` y `Recreate` posteriores la conservan. Primero Terraform crea el host y la identidad, después `lab.ps1` publica `functions/backup-audit` con compilación remota y finalmente Terraform crea la suscripción Event Grid. No edites `enable_backup_event_subscription` a mano. `Destroy` elimina todos estos recursos junto con el resto del laboratorio. Si ya tienes la infraestructura desplegada, `Deploy` continúa sobre los mismos workspaces HCP; verifica primero que las credenciales del ERP y la clave SSH local siguen disponibles.

La suscripción escucha `Microsoft.Storage.BlobCreated` únicamente bajo `backups/` del contenedor `backups`. La función lee el Blob por identidad administrada, comprueba su tamaño y calcula SHA-256 en bloques. Escribe un JSON con `status`, tamaño, hash, ETag y hora UTC en el contenedor privado `backup-audit`. Los estados son `ok`, `empty`, `oversize` o `size_mismatch`; el límite inicial es 1 GiB y se ajusta mediante `backup_audit_max_bytes` en `environments/lab/azure/terraform.tfvars`. Un backup demasiado grande queda registrado sin descargarlo para calcular el hash. La función se puede repetir para el mismo objeto y actualiza el registro correspondiente. Esta auditoría no crea dumps ni restaura PostgreSQL.

```powershell
$account = terraform -chdir=environments/lab/azure output -raw storage_account_name
$function = terraform -chdir=environments/lab/azure output -raw backup_audit_function_name
az functionapp function show --resource-group andeslog-lab-rg --name $function --function-name BackupAudit --query name -o tsv
az storage blob list --account-name $account --container-name backup-audit --auth-mode login --query "[].name" -o tsv
```

Sube un dump con `upload-backup.ps1`, espera la entrega de Event Grid y consulta el JSON con `az storage blob download --account-name $account --container-name backup-audit --name <nombre-json> --file <ruta-local> --auth-mode login`. El usuario de Azure CLI también necesita acceso de lectura a ese contenedor. Para ver invocaciones y errores, consulta **Function App → Monitor** en Azure Portal.

La cuenta Azure for Students debe permitir registrar `Microsoft.Web`, `Microsoft.EventGrid` y `Microsoft.ManagedIdentity`, crear el plan Flex Consumption en la región seleccionada y asignar **Storage Blob Data Contributor** a la identidad de la función (`Microsoft.Authorization/roleAssignments/write`). Si lo deniega, el script se detiene antes de crear AWS. El host Functions usa una cuenta Storage propia con clave de acceso; esa clave aparece como dato sensible en el estado remoto HCP y no debe compartirse. La cuenta que almacena los backups sigue con claves compartidas deshabilitadas. La extensión puede generar cargos por ejecuciones de Functions, eventos Event Grid, operaciones y capacidad de Storage; `Destroy` los detiene al eliminar los recursos. [Flex Consumption](https://learn.microsoft.com/en-us/azure/azure-functions/flex-consumption-plan) · [Event Grid con Functions](https://learn.microsoft.com/en-us/azure/azure-functions/functions-bindings-event-grid-trigger) · [Despliegue ZIP de Functions](https://learn.microsoft.com/en-us/azure/azure-functions/deployment-zip-push) · [Rol de datos Blob](https://learn.microsoft.com/en-us/azure/storage/blobs/assign-azure-role-data-access)

## Revisión y destrucción total del laboratorio

- Revisa siempre `terraform plan` antes de `apply`, especialmente si cambiaste región, IP pública, perfil AWS o SKU.
- Los estados son remotos e independientes en HCP Terraform. Destruye Azure y AWS desde sus propios directorios.
- `terraform destroy` elimina los recursos administrados en el root actual. Guarda fuera de la nube las bases o archivos que quieras conservar: destruir también elimina los discos EBS y el Storage Account de Azure con sus datos.
- Conserva el acceso a los dos workspaces de HCP Terraform y no elimines su estado remoto antes del destroy. Inicia sesiones válidas de AWS Academy y Azure CLI. Primero puedes revisar el alcance con `terraform plan -destroy`; luego ejecuta `terraform destroy` y confirma el prompt en cada root:

  ```powershell
  Push-Location .\environments\lab\azure
  terraform plan -destroy
  terraform destroy
  Pop-Location
  Push-Location .\environments\lab\aws
  terraform plan -destroy
  terraform destroy
  Pop-Location
  ```

- Si activaste el bucket S3 opcional, vacíalo antes porque `force_destroy = false`. Para Azure Blob, exporta primero lo que necesites; eliminar el Storage Account elimina sus objetos. En la configuración actual S3 está desactivado por la restricción de AWS Academy.
- Confirma `Destroy complete!` en cada root y revisa AWS/Azure para detectar recursos creados manualmente fuera de Terraform. `terraform destroy` no los elimina. Luego comprueba el consumo de créditos y recursos facturables.

## Referencias oficiales consultadas

- [HashiCorp: configuración HCP en el bloque `cloud`](https://developer.hashicorp.com/terraform/language/block/terraform)
- [HashiCorp: conectar Terraform CLI a HCP y migrar estado](https://developer.hashicorp.com/terraform/cli/cloud/settings)
- [HashiCorp: modo de ejecución local y estado remoto](https://developer.hashicorp.com/terraform/cli/cloud)
- [HashiCorp: límites y plan Free de HCP Terraform](https://developer.hashicorp.com/terraform/cloud-docs/overview)
- [GitHub: publicar e instalar imágenes de contenedor en GHCR](https://docs.github.com/en/packages/working-with-a-github-packages-registry/working-with-the-container-registry)
- [AWS Provider: autenticación y configuración](https://registry.terraform.io/providers/hashicorp/aws/6.24.0/docs#authentication-and-configuration)
- [AWS: uso de credenciales temporales](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_credentials_temp_use-resources.html)
- [AWS Provider: zonas de disponibilidad](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/availability_zones)
- [AWS Provider: instancias EC2](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/instance)
- [AWS EC2: tabla de vCPU de T3](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/burstable-t3.html)
- [AWS EC2: user data en instancias](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/user-data.html)
- [AWS EC2: exigir IMDSv2 en instancias](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/configuring-IMDS-new-instances.html)
- [AWS ELB: health checks de Application Load Balancer](https://docs.aws.amazon.com/elasticloadbalancing/latest/application/target-group-health-checks.html)
- [AWS CloudWatch: métricas de Application Load Balancer](https://docs.aws.amazon.com/elasticloadbalancing/latest/application/load-balancer-cloudwatch-metrics.html)
- [Terraform CLI: destruir recursos administrados](https://developer.hashicorp.com/terraform/cli/commands/destroy)
- [AzureRM: autenticación con Azure CLI](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/guides/azure_cli)
- [AzureRM Provider: configuración y registro de proveedores](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/index)
- [AzureRM: contenedor Storage Blob](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/storage_container)
- [Microsoft Learn: asignar rol de datos a Blob Storage](https://learn.microsoft.com/en-us/azure/storage/blobs/assign-azure-role-data-access?tabs=portal)
- [AzureRM: cuenta de almacenamiento](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/storage_account)
- [AzureRM: alerta de métrica](https://registry.terraform.io/providers/hashicorp/azurerm/5.7.0/docs/resources/monitor_metric_alert)
- [Microsoft Learn: administrar VM Linux y elegir imagen Ubuntu](https://learn.microsoft.com/en-us/azure/virtual-machines/linux/tutorial-manage-vm)

Los límites, precios, permisos y SKUs disponibles dependen de cada cuenta académica y región; la documentación técnica no confirma los permisos de tu suscripción concreta.
