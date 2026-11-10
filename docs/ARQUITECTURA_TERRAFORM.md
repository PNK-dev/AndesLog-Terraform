# Arquitectura multicloud de AndesLog

El repositorio define dos roots de Terraform administrados por HCP Terraform. `scripts/lab.ps1` coordina despliegue, migración de PostgreSQL, prueba de integración y limpieza del host temporal. Esta descripción distingue la topología prevista por el código de los recursos que sí están desplegados.

## AWS — ERP y PostgreSQL

- VPC `10.10.0.0/16`, con subredes públicas, privadas de aplicación y privadas de datos en dos Availability Zones.
- Application Load Balancer público con listener HTTP de laboratorio y Target Group al puerto 8080. El health check `/api/health/live` controla el reemplazo de nodos.
- Auto Scaling Group privado con `min=2`, `desired=2`, `max=3`. La imagen del ERP se guarda en ECR; la configuración sensible del runtime se obtiene de Secrets Manager.
- Cada nodo ejecuta el servidor ERP y un worker outbox como servicios separados. Los eventos se escriben en la misma transacción PostgreSQL; los workers usan lease, `FOR UPDATE SKIP LOCKED`, reintento con backoff e idempotencia.
- RDS PostgreSQL Multi-AZ, sin IP pública, almacenamiento cifrado y backups automáticos de siete días.
- NAT Gateway independiente por AZ permite que las instancias privadas descarguen imágenes y se reemplacen. Ambos generan cargos mientras existan.
- La VM EC2 bootstrap se crea para migrar/configurar la base y se destruye al final del despliegue.

### VPN de red entre nubes

El código Terraform puede crear AWS Virtual Private Gateway, dos Customer Gateways y dos VPN Connections con cuatro túneles IPsec/BGP. En la cuenta AWS Academy actual **no están desplegados**: la política organizativa deniega `ec2:CreateCustomerGateway`. `vpn_connection_ids` queda vacío y no existe ruta IP privada AWS↔Azure.

## Azure — servicios corporativos

- La red y el gateway corporativos están en `chilecentral`. Azure VPN Gateway `VpnGw1AZ` está configurado activo-activo; P2S usa Azure VPN Client con identidad Microsoft Entra.
- Azure Files primario mantiene el share `andeslog` en Chile Central, ZRS y acceso público deshabilitado. Su Private Endpoint fue aprobado en el último despliegue; el acceso SMB usa su autenticación de almacenamiento separada de Entra.
- Una cuenta/share `andeslog` independiente en Mexico Central usa ZRS y acceso público deshabilitado; su Private Endpoint fue aprobado en el último despliegue. Peerings globales conectan las VNets corporativa, de integración y de recuperación; la zona DNS privada de Azure Files está vinculada a la VNet de integración.
- `AzureFilesDisasterRecoverySync`, Timer de la Function Flex en West US 2, usa el SDK oficial `azure-storage-file-share` y su propósito OAuth `backup`, autenticado con la identidad administrada de sincronización. Lee el share primario y escribe en el secundario, en una dirección y sin borrar elementos exclusivos del destino. No guarda claves ni SAS.
- El código actual programa el Timer cada minuto y una alerta si no hay éxito durante cinco minutos. La ejecución anterior comprobada en nube usó intervalos de 15 y 45 minutos respectivamente: copió 8 archivos (7,340,789 bytes) y observó ciclos incrementales. La nueva frecuencia y los cambios posteriores aún necesitan prueba real. La marca `FILES_DR_SYNC_SUCCESS` es una señal operativa, no una medición garantizada del RPO ni una instantánea consistente.
- La implementación local prepara la copia de ACL y metadatos y detecta algunos conflictos en archivos del destino, pero estos cambios no se habían probado en Azure en el último despliegue. No se ha validado el montaje del share secundario ni el aislamiento de escritores: la promoción y el acceso de usuarios no son todavía un failover seguro y automático.
- Una cuenta StorageV2 ZRS contiene respaldos Blob. La Function BackupAudit/Event Grid sigue siendo una opción separada (`-EnableBackupAudit`).

## ERP→Azure — Function y archivo de eventos

El diseño ubica la integración en `westus2`, con una VNet dedicada (`10.30.0.0/16`), la subred delegada a Flex Consumption y la subred de Private Endpoints. Estos recursos son temporales y se eliminan con la baja.

- El ERP registra los eventos de pedidos, viajes, inventario e importaciones CSV en una outbox dentro de PostgreSQL.
- Uno de los workers del ASG envía cada evento por HTTPS con firma HMAC a la Azure Function `andesloglab-erp-13fdbba3`.
- Flex Consumption tiene dos instancias HTTP always-ready y redundancia zonal. La Function valida firma, esquema y tamaño y usa identidad administrada para escribir el evento una sola vez, con su UUID, en `erp-events`.
- El storage de eventos usa ZRS, acceso público y Shared Key deshabilitados; su Private Endpoint fue aprobado en el último despliegue. La zona DNS privada hace que la Function alcance Blob de forma privada. El storage host de Functions está separado y también usa ZRS.
- La misma Function ejecuta la tarea Timer de recuperación de Azure Files. La red de integración tiene peering y enlace DNS privado a los endpoints de Chile Central y Mexico Central; ambas cuentas Files mantienen acceso público deshabilitado.

La entrada HTTPS de la Function es pública y se autentica con HMAC; el acceso al Blob es privado. Esta es una integración real de aplicación AWS→Azure, pero no reemplaza la VPN ni proporciona conectividad de red privada entre las VPC/VNet.

## Recorrido del tráfico

1. Los usuarios del ERP llegan por HTTP al ALB y este distribuye solicitudes a nodos saludables en dos AZ. Antes de producción se requiere TLS, dominio y protección perimetral apropiada.
2. El ERP accede a PostgreSQL por TCP/5432 desde las subredes de aplicación; RDS no tiene IP pública y cambia de nodo mediante failover administrado.
3. Los cambios funcionales escriben un evento en la outbox de PostgreSQL. Un worker envía HTTPS/HMAC a Azure Function; esta archiva en Blob a través del Private Endpoint.
4. El Timer configurado en el código intenta sincronizar Chile Central → Mexico Central cada minuto por FileREST y rutas privadas. Una identidad administrada tiene lectura en el origen y escritura en el destino. No se eliminan archivos exclusivos del destino. Ante un incidente, la copia secundaria requiere aislamiento de escritores, reconciliación y pruebas antes de permitir acceso de escritura; el gateway P2S de recuperación es manual. La autenticación SMB es independiente de la VPN.
5. El flujo privado BGP/IPsec AWS↔Azure está previsto en Terraform, pero se encuentra deshabilitado en esta cuenta académica.

## Despliegue y límites

Para las cuentas académicas usadas en el laboratorio, el despliegue reproducible es:

```powershell
$env:TF_CLOUD_ORGANIZATION = "AndesLog"
$env:AWS_PROFILE = "andeslog-academy"
.\scripts\lab.ps1 -Action Deploy -EnableRemoteAccess -SkipIntercloudVpn -DisableInstanceRefresh
```

`-SkipIntercloudVpn` respeta la SCP que bloquea Customer Gateways. `-DisableInstanceRefresh` evita la acción de ASG que también está bloqueada; el script realiza una rotación manual y espera a los destinos saludables. No ejecutes AWS/Azure roots por separado para formar la VPN: las claves compartidas se coordinan internamente y nunca deben copiarse a Git.

El listener del ERP sigue en HTTP; no se deben usar credenciales sensibles por Internet hasta configurar TLS. El ERP y PostgreSQL no tienen recuperación ante caída regional; Files requiere activación manual y prueba de montaje de su copia sincronizada. La restauración de backup y la prueba de zona de la Function tampoco se han demostrado. Al destruir, PostgreSQL, Blob y la copia Azure Files administrada por Terraform se eliminan; Azure Files primario se conserva fuera del estado según la configuración del script.
