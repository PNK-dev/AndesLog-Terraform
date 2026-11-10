# Presupuesto de referencia para AndesLog en producción

## Resumen

Esta estimación se construye desde las necesidades de operación del ERP logístico B2B: atender tráfico aun si cae un nodo o una zona, conservar PostgreSQL durante un fallo zonal, mantener privados los datos y sostener la integración ERP→Azure. No se usa el crédito académico de USD 50 como límite de diseño ni para elegir capacidad.

Con precios retail de referencia y 730 horas de operación mensual, el **escenario base Multi-AZ** cuesta aproximadamente **USD 1,094/mes** con Azure `VpnGw2AZ`, o **USD 853/mes** con el `VpnGw1AZ` que usa hoy Terraform. Incluye un ejemplo de ejecución del nuevo timer cada minuto y la concesión gratuita cuando corresponda. El cálculo contempla dos nodos web, ALB, RDS Multi-AZ, dos NAT, conectividad S2S objetivo, VPN de usuarios, DNS privado, una copia de Azure Files en Mexico Central, tres Private Endpoints y la integración serverless. Es un presupuesto parcial respecto de la meta final: no incluye todavía recuperación regional de la aplicación, base de datos ni Function/Blob, ni la protección web WAF. No presentar esta cifra como costo final de una solución sin puntos únicos de falla regionales.

El escenario base usa tamaños candidatos de producción (`t3.large`, `db.t4g.medium` y `VpnGw2AZ`); los valores de laboratorio versionados son menores (`t3.micro`, `db.t3.micro` y `VpnGw1AZ`) para ajustarse a cuotas y ventanas de práctica. El mayor tamaño de producción debe confirmarse con pruebas representativas antes de comprar capacidad.

El presupuesto no garantiza que el ERP tenga capacidad suficiente. La prueba de carga debe ajustar CPU, memoria, conexiones a PostgreSQL y capacidad de red. Una instancia `t3.large` es una hipótesis inicial para un piloto de bajo volumen; al ser burstable, hay que vigilar créditos de CPU y migrar a una clase no burstable si la carga es sostenida.

## Supuestos del cálculo

- 730 horas al mes, recursos encendidos todo el mes, pago bajo demanda, dólares estadounidenses, sin impuestos ni descuentos académicos.
- AWS `us-east-1`; Azure `chilecentral`, `mexicocentral` para la copia de Files, y `westus2` para Function/Blob de eventos.
- Dos nodos ERP Linux `t3.large`, cada uno con volumen raíz gp3 de 16 GiB; un ALB con 1 LCU promedio. Es una hipótesis inicial de baja carga, no una capacidad aprobada por prueba de negocio.
- PostgreSQL RDS `db.t4g.medium`, Multi-AZ con un standby, 20 GiB gp3 por instancia y siete días de backup automático. El valor de cómputo usa la tarifa Multi-AZ, que contabiliza el primario y el standby; el almacenamiento también se calcula para las dos copias.
- Dos NAT Gateway y 100 GB procesados al mes; dos conexiones AWS Site-to-Site VPN hacia el gateway activo-activo de Azure (cuatro túneles en total).
- Para la referencia de producción se usa `VpnGw2AZ` de generación 2, zona redundante y activo-activo, con benchmark de 1.25 Gbps. El Terraform actual usa `VpnGw1AZ`, también zonal/activo-activo, con benchmark de 650 Mbps; el precio se presenta como variante del código actual. La selección final debe seguir el throughput medido y la disponibilidad objetivo.
- La integración ERP→Azure usa Azure Functions Flex Consumption, `512 MiB`, host storage ZRS y balanceo zonal. Se presupuestan dos instancias always-ready para sobrevivir a la falla de una zona. BackupAudit sería una Function adicional.
- Un DNS Private Resolver inbound endpoint, tres Private Endpoints (Files primario, Files DR y Blob de eventos), 100 GB de Files primario Hot ZRS, 100 GB en la copia Files Hot ZRS y 100 GB cada uno en Blob de backups y de eventos.
- Las conexiones S2S y P2S se mantienen dentro del tramo incluido del gateway Azure: hasta 10 S2S y las primeras 128 P2S. No se suma el cargo por conexión de esos tramos.

La meta acordada para producción es **RTO de hasta 30 minutos y RPO de hasta 5 minutos** para ERP, base de datos y archivos. Todavía no se han demostrado esos objetivos. El código local programa Files cada minuto, sin garantizar que una ejecución termine antes de la siguiente, y la aplicación/base no cuentan con recuperación regional implementada. Una prueba histórica usaba intervalos de 15 minutos. Este subtotal Multi-AZ es insuficiente para costear la solución que cumple la meta. Faltan por definir concurrencia máxima, transacciones por segundo, crecimiento de archivos y SLO de disponibilidad; la prueba de 300 GET a readiness no dimensiona producción.

Los 100 GB por share son una hipótesis de consumo para producción; la cuota Terraform del laboratorio es de 10 GiB. La cuota de ambos shares debe superar el volumen previsto y tener margen para archivos temporales, elementos exclusivos del destino y crecimiento. Las cuotas no se cobran como espacio consumido en este modelo; deben confirmarse la modalidad y el volumen real antes de comprar.

## Estimación mensual

### AWS

| Componente | Base de cálculo | Justificación operativa | USD/mes aprox. |
| --- | --- | --- | ---: |
| ERP en ASG | 2 × `t3.large` × USD 0.0835/h × 730 h | Dos nodos distribuidos en AZ distintas para mantener capacidad cuando una instancia/zona falla. | 121.91 |
| Discos de nodos ERP | 2 × 16 GiB gp3 × USD 0.08/GiB-mes | Volumen raíz independiente, cifrado, para cada nodo del ASG. | 2.56 |
| PostgreSQL RDS Multi-AZ | Tarifa Multi-AZ `db.t4g.medium` USD 0.129/h × 730 h | Primario más standby administrado en otra AZ y conmutación automática; no es el costo de un RDS Single-AZ. | 94.17 |
| Almacenamiento RDS gp3 | 20 GiB × 2 AZ × USD 0.115/GiB-mes | Mantiene dos copias de los datos; no cubre una réplica en otra región. | 4.60 |
| Application Load Balancer | Base USD 0.0225/h + promedio de 1 LCU a USD 0.008/h | Entrada pública redundante y health checks que apartan destinos no saludables. | 22.27 |
| NAT Gateway | 2 × USD 0.045/h × 730 h + 100 GB × USD 0.045/GB | Salida de subredes privadas por AZ, sin depender de una única ruta de egreso. Excluye transferencia estándar a Internet. | 70.20 |
| Site-to-Site VPN de AWS | 2 conexiones × USD 0.05/h × 730 h | Conecta el VPC con los dos gateways activos de Azure y aporta cuatro túneles; la cuenta Academy actual lo bloquea por SCP. | 73.00 |
| IPv4 públicas | Supuesto: 2 NAT + 2 ALB + 4 extremos VPN; 8 × USD 0.005/h × 730 h | Direcciones dedicadas de endpoints públicos según el diseño; validar el conteo real de facturación. | 29.20 |
| ECR, Secrets Manager, dashboard y alarmas | Reserva inicial; logs/consultas dependen de volumen | Distribución privada de imagen, secreto de runtime y telemetría básica. Es una reserva presupuestaria, no tarifa fija. | 10.00 |
| **Subtotal AWS** |  |  | **428 aprox.** |

AWS cobra NAT tanto por hora como por datos procesados; el precio del ALB también cambia con las LCU y el tráfico. El importe de las IP públicas se basa en ocho direcciones dedicadas según la topología descrita; compruébalo en AWS Pricing Calculator con la región y los recursos efectivos.

### Azure

| Componente | Base de cálculo | Justificación operativa | USD/mes aprox. |
| --- | --- | --- | ---: |
| VPN Gateway zonal Gen2 | `VpnGw2AZ` × USD 0.54/h × 730 h | P2S corporativa activa-activa y terminación del S2S con el throughput de referencia elegido para producción. | 394.20 |
| IP públicas Standard | 3 × USD 0.01/h × 730 h | Direcciones zonales requeridas por las configuraciones del gateway P2S activo-activo. | 21.90 |
| DNS Private Resolver inbound | 1 endpoint, referencia de USD 180/mes | Resolución privada de Files desde clientes conectados; servicio administrado con redundancia zonal. | 180.00 |
| Azure Files Hot ZRS, Chile Central | 100 GB usados × USD 0.104998/GB-mes | Share corporativo primario con réplica síncrona dentro de la región; los cargos por transacción van aparte. | 10.50 |
| Azure Files DR Hot ZRS, Mexico Central | 100 GB usados × USD 0.08/GB-mes | Copia regional con capacidad para los mismos datos que el origen; se necesita cuota adicional para temporales y crecimiento. Transacciones y transferencia se agregan por uso. | 8.00 |
| Blob Hot ZRS: backup + eventos | 200 GB usados × USD 0.023/GB-mes | 100 GB por cada finalidad: respaldos y eventos de integración, redundantes entre zonas. Operaciones y egreso no incluidos. | 4.60 |
| Private Endpoints (3) | 3 × USD 0.01/h × 730 h, tarifa minorista de referencia | Aísla los shares primario/secundario y el Blob de eventos de la red pública; datos procesados y transferencia se cobran aparte. | 21.90 |
| Azure Functions Flex zonal ERP ingest | 2 × 0.5 GB × 730 h × 3,600 s × USD 0.000004/GB-s; no incluye ejecuciones | Dos instancias always-ready para tolerar la falla de una zona y evitar esperar un cold start en el flujo de eventos. | 10.51 |
| Timer de sincronización Azure Files | 43,800 ejecuciones/mes; ejemplo de 30 s × 0.5 GB = 657,000 GB-s. Con 100,000 GB-s gratuitos disponibles, 557,000 × USD 0.000026. | Reutiliza la Function Flex existente; supone que cada ejecución acaba en 30 s. Los cargos de operaciones y tráfico se añaden aparte. | **14.48 aprox.; variable** |
| **Subtotal Azure** |  |  | **666 aprox.** |

La API Retail de Azure consultada el 2026-11-06 devuelve USD 0.54/h para `VpnGw2AZ` en Chile Central, USD 0.21/h para `VpnGw1AZ`, USD 0.104998/GB-mes para Azure Files Standard ZRS en Chile Central, USD 0.08/GB-mes en Mexico Central y USD 0.023/GB-mes para Blob Hot ZRS en West US 2. El DNS Private Resolver inbound se modela con la tarifa publicada de USD 180 por endpoint/mes. Azure VPN Gateway cobra por SKU y transferencia; su tarifa de cómputo activa-activa es igual a activa-pasiva. Las cantidades de Files y Blob son consumo almacenado; operaciones, transferencias y salida no están incluidas. La primera copia registrada transfirió 8 archivos; la capacidad presupuestada de 100 GB por copia es una hipótesis, no una medición del uso actual.

La fila de Functions aproxima el baseline de dos instancias always-ready; el timer se calcula separadamente con 43,800 invocaciones por mes de 730 horas y un supuesto no validado de 30 segundos cada una. La API Retail devolvió USD 0.000026 por GB-s bajo demanda en West US 2 el 2026-11-10, después de la concesión. El ejemplo supone que la suscripción es elegible y tiene disponible toda la concesión de 100,000 GB-s y 250,000 ejecuciones; sin esa concesión, los 657,000 GB-s costarían USD 17.08 y 43,800 ejecuciones USD 0.0175 adicionales. Los demás usos de la suscripción pueden agotarla antes. Se agregan cargos por operaciones, tráfico, logs, regla de alerta evaluada cada minuto y host storage según volumen real. La Function BackupAudit opcional añade otro plan Flex. Valida los precios contractuales en la calculadora Azure.

La versión local calcula un hash leyendo todos los archivos de la copia secundaria en cada ciclo incluso cuando no cambiaron. Con 100 GB y 43,800 ciclos mensuales, el máximo teórico es 4,380,000 GB de lecturas antes de reintentos, cambios o fallas; no es una medición ni incluye tarifas. La transferencia por fragmentos evita guardar el archivo completo en disco local, pero no elimina estas lecturas ni sus cargos. Si una ejecución dura más de un minuto, no se ejecutan en paralelo, por lo que el número real de ciclos baja y el RPO puede empeorar. Existe un límite cooperativo local de 600 segundos: una copia que lo exceda se considerará fallida, pero una llamada de red ya iniciada puede tardar más y generar cargos. La alerta deja de considerar reciente un recorrido iniciado hace más de cinco minutos; si el límite se alcanza de forma repetida, algunos archivos podrían no llegar a copiarse. Las trazas y excepciones se excluyen del muestreo para proteger las alertas y pueden aumentar la ingesta facturable. El supuesto de 30 segundos debe revalidarse con volúmenes representativos. Cotizar operaciones de Azure Files, Private Endpoint y tráfico según dirección/región. La implementación aún no se desplegó ni se sometió a prueba de escala.

### Total y variantes

| Escenario | USD/mes aprox. | Qué significa |
| --- | ---: | --- |
| Multi-AZ con Azure `VpnGw2AZ` Gen2 e ingestión ERP zonal | **1,094** | Incluye S2S objetivo, Function ERP ingest, tres Private Endpoints, Files DR de 100 GB y Blob. |
| Mismo diseño con `VpnGw1AZ` actual | **853** | Conserva redundancia zonal y Files DR; menor throughput de referencia que `VpnGw2AZ`. |
| Function BackupAudit opcional | **+11** | Baseline aproximado de un plan Flex adicional; host storage y ejecuciones aparte. |
| Con tercer nodo ERP en forma continua | **+61** | Cada `t3.large` adicional suma aproximadamente USD 60.96/mes más disco. |
| Sin conexiones Site-to-Site AWS | **−73** | No existiría el flujo privado AWS↔Azure, por lo que no cumpliría el diseño intercloud. |

Los importes son el subtotal de los componentes modelados, no un monto contractual. La cuenta comercial, región, cambio de precio, cantidad de operaciones, tráfico y retenciones cambian el costo real. Los cargos de uso deben añadirse a partir de métricas de una prueba representativa.

## Escenario objetivo multirregional: estimación preliminar

Para justificar continuidad ante la pérdida de una región, se modela además una segunda región AWS con dos nodos ERP, ALB, egreso por dos zonas y una réplica PostgreSQL de lectura Multi-AZ; una segunda región Azure con gateway P2S/S2S y resolver ya encendidos; y una segunda Function zonal. Se presupuestan en total ocho conexiones S2S de AWS: dos por cada combinación de dos regiones AWS y dos gateways regionales Azure. Una entrada Azure Front Door Premium con orígenes privados en dos regiones sería la alternativa de acceso a la integración durante una falla regional. Esta topología es una **propuesta de dimensionamiento**: aún no está completamente implementada ni probada y requiere validar el enrutamiento, cuotas, consistencia de datos y failover para las metas acordadas.

La preparación Terraform de DR incluye una réplica regional del secreto de ejecución del ERP, cuyo almacenamiento y llamadas a Secrets Manager deben cotizarse en la región secundaria. La reserva general de secretos del subtotal no demuestra que ese cargo ni la transferencia de replicación estén cubiertos; confirmar con la calculadora y el patrón real de consultas antes de aprobar el presupuesto final.

La opción experimental de replicación regional de backups automáticos de RDS es independiente de la réplica de lectura. Sus cargos por almacenamiento de snapshots y logs, transferencia entre regiones, KMS y restauraciones de prueba todavía no están incluidos. Las copias retenidas pueden seguir facturándose aun si se detiene la replicación; deben dimensionarse y gestionarse durante la baja. No hay mediciones reales para incorporarlas como precio definitivo.

La restauración aislada experimental agregaría una instancia RDS Multi-AZ en la región secundaria durante el ejercicio, almacenamiento, backups y potencial snapshot final. Es un costo de recuperación y prueba adicional que tampoco está incluido en el subtotal. Debe estimarse con la duración, tamaño y retención realmente necesarios; dejar el snapshot final o los backups replicados implica cargos posteriores a la baja de la instancia.

La monitorización regional experimental añade dos alarmas CloudWatch de resolución estándar y una suscripción de eventos RDS a SNS cuando se configura correo. Su costo y el de las notificaciones adicionales no están cuantificados en el subtotal; deben cotizarse según región, número de alarmas, volumen, concesiones y destino de las notificaciones. No se contabilizan como evidencia de que el RPO se cumpla.

La opción experimental para replicar el archivo Blob de eventos a Mexico Central está desactivada por defecto. Su cuenta ZRS, Private Endpoint, almacenamiento y versiones, change feed, operaciones, transferencia interregional y métricas o alertas asociadas **no están incluidos** en este subtotal. No hay todavía datos de volumen ni una prueba de replicación real que permitan estimarlos con precisión; hay que cotizarlos según la carga y retención medidas. Tampoco se incluye la automatización de recuperación del flujo de eventos.

La preparación desactivada de la Function secundaria añade un Private Endpoint en East US 2 hacia la cuenta de Mexico Central, una zona DNS privada separada, host storage ZRS, Application Insights/Log Analytics y posibles transferencias entre regiones. La fila de la segunda Function contempla únicamente el baseline aproximado de instancias always-ready; los componentes adicionales, invocaciones, registros y operaciones no están incluidos. Deben cotizarse al seleccionar las regiones y medir la carga real.

La sonda de replicación PostgreSQL está probada solo en local y no tiene todavía un ejecutor. Terraform prepara de forma opcional una conexión privada entre las VPC regionales para supervisión, pero no se ha desplegado ni probado. Para presupuestar supervisión continua se deben añadir el costo del ejecutor, la transferencia entre regiones por el peering, las escrituras y lecturas de los marcadores, la retención y las métricas/alertas. El costo dependerá de la frecuencia y no está incluido en el subtotal actual. Consulta [precios de VPC Peering](https://aws.amazon.com/vpc/pricing/).

Sobre el subtotal anterior de USD 1,094/mes, se agregan los siguientes importes indicativos. Son hipótesis de precios bajo demanda con 730 horas mensuales; para la segunda región AWS se reutilizan las tarifas de referencia de la región primaria y deben cotizarse en la región de recuperación elegida.

| Incremento previsto | Cálculo de referencia | USD/mes aprox. |
| --- | --- | ---: |
| Dos nodos ERP y discos en AWS secundario | 2 × `t3.large` + 2 × 16 GiB gp3 | 124.47 |
| ALB y dos NAT en AWS secundario | 1 ALB con 1 LCU + 2 NAT y 100 GB procesados | 92.47 |
| Réplica RDS PostgreSQL Multi-AZ en otra región | `db.t4g.medium` Multi-AZ más 20 GiB en dos zonas | 98.77 |
| Seis conexiones VPN AWS adicionales | 6 × USD 0.05/h × 730 h; el subtotal base ya incluye dos | 219.00 |
| IPv4 adicionales AWS | Supuesto: 2 NAT + 2 ALB + 12 extremos de túnel; 16 × USD 0.005/h × 730 h | 58.40 |
| WAF AWS y DNS público | Dos ACL con dos grupos administrados y una regla de tasa cada una, 1 millón de solicitudes totales y una zona DNS | 17.10 |
| Gateway `VpnGw2AZ`, IP y resolver en Mexico Central | USD 0.54/h × 730 h + tres IP Standard a USD 0.01/h + resolver estimado en USD 180/mes | 596.10 |
| Segunda Function zonal | Dos instancias always-ready de 512 MiB; baseline, sin ejecuciones ni host storage | 10.51 |
| Azure Front Door Premium | Tarifa base mensual; solicitudes y transferencia aparte | 330.00 |
| **Incremento aproximado** | | **1,547** |
| **Subtotal multirregional aproximado** | USD 1,094 + USD 1,547 | **2,641/mes** |

Este subtotal es una base para cotización, no una garantía de capacidad o de RTO/RPO. La réplica RDS es asíncrona y requiere promoción y recuperación probadas; el código local de Azure Files tampoco ha demostrado el objetivo de cinco minutos ni una restauración consistente. La estimación **no incluye** almacenamiento de imágenes ECR en la segunda región, transferencia para publicar esas imágenes, transferencia interregional o entre nubes, operaciones y almacenamiento extra de backups, host storage y otras ejecuciones de Functions, almacenamiento Blob secundario, logs y retención, automatización de failover, licencias, soporte ni personal. Tampoco incluye los costos de las pruebas y restauraciones. Esos rubros deben medirse y añadirse antes de aprobar el presupuesto final.

Para controlar la conmutación regional sin depender de editar DNS durante una incidencia, una alternativa es **Application Recovery Controller (ARC) routing control**. Su cluster cuesta USD 2.50/h según [precios oficiales de AWS](https://aws.amazon.com/application-recovery-controller/pricing/): unas 730 horas sumarían **USD 1,825/mes**, llevando el subtotal indicativo de USD 2,641 a aproximadamente **USD 4,466/mes**, antes de los gastos todavía omitidos. Otra alternativa a evaluar es **ARC Region switch**, con USD 70/mes por plan según la misma fuente; no debe sumarse ni darse por equivalente sin diseñar sus dependencias. Ninguna de estas opciones está implementada en AndesLog ni, por sí sola, bloquea escrituras en la base antigua o demuestra RPO/RTO. Un DNS basado solo en salud puede regresar al primario cuando este reaparece, antes de reconciliar los datos; el diseño final debe impedir ese retorno prematuro.

La réplica RDS de este escenario es una hipótesis aún no desplegada. La base del despliegue anterior usaba contraseña maestra administrada por RDS, modalidad incompatible con crear réplicas de lectura de PostgreSQL; el nuevo código ofrece una ruta externa experimental para una base nueva, que requiere una Lambda y pruebas de rotación y recuperación. Migrar una base existente exige además un procedimiento específico y verificado. La estimación aún no contempla el costo adicional de la Lambda, la conectividad y la operación del secreto. Ver [limitaciones de RDS y Secrets Manager](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/rds-secrets-manager.html).

La API Retail de Azure devolvió USD 0.54/h para `VpnGw2AZ` en Mexico Central el 2026-11-09. Microsoft publica una base de USD 330/mes para Front Door Premium; AWS cobra por conexión VPN, IP pública, ACL, reglas y solicitudes. Verifica configuración y precios de las regiones definitivas en las calculadoras oficiales: [AWS Site-to-Site VPN](https://aws.amazon.com/vpn/pricing/), [AWS WAF](https://aws.amazon.com/waf/pricing/), [AWS IPv4](https://aws.amazon.com/vpc/pricing/), [Azure Front Door](https://azure.microsoft.com/en-us/pricing/details/frontdoor/) y [Azure Retail Prices API](https://learn.microsoft.com/en-us/rest/api/cost-management/retail-prices/azure-retail-prices).

## Fuera del subtotal

La siguiente lista se refiere al **subtotal Multi-AZ base**, no al subtotal multirregional preliminar anterior, que sí incluye algunas capacidades regionales como hipótesis de costo. Ninguno de los subtotales incluye los gastos variables y operativos indicados en la sección multirregional.

- Recuperación regional completa del ERP: otro ALB, mínimo dos nodos de aplicación, NAT/egreso, direcciones públicas y distribución global/DNS. El costo depende de modo activo-activo o warm standby y no está en este subtotal.
- Recuperación regional de PostgreSQL: réplica cross-region o diseño de base distribuida, almacenamiento, transferencia, backups y ejercicios de promoción. Hay que elegir mecanismo tras fijar el RPO (incluida la pérdida aceptable de escrituras) y el RTO; no está en este subtotal.
- Recuperación regional de Function y Blob de eventos: segunda Function/plan, almacenamiento, rutas y política de failover. El outbox evita perder los eventos en AWS durante una interrupción, pero el servicio regional secundario y la recuperación del consumidor aún no están presupuestados.
- Gateway P2S y DNS Private Resolver de Mexico Central para acceso de usuarios durante failover de Azure Files. Pueden prepararse con `-EnableFilesDrGateway` o crearse bajo demanda; ambos generan cargos mientras estén activos. No están incluidos en el subtotal base; el escenario multirregional sí reserva una estimación para mantenerlos encendidos.
- AWS WAF, reglas administradas y solicitudes, más dominio/DNS público. El listener de laboratorio es HTTP; TLS del ALB requiere certificado ACM y dominio validado, y WAF no está desplegado ni incluido en el subtotal.
- Autenticación individual sin Shared Key para Azure Files, protección DDoS avanzada, SIEM y retención extensa de logs.
- Transferencia de salida a Internet, tráfico entre nubes, tráfico de Azure Files/Blob, operaciones de almacenamiento, restauraciones, snapshots que superen el almacenamiento gratuito de backups RDS, ampliación del disco y autoscaling por encima de dos nodos.
- Ejecuciones de Function, Event Grid opcional, operaciones de Blob, storage host de Functions y retenciones adicionales.
- Soporte comercial, licencias del sistema operativo o software y tiempo de operación del equipo.

## Separación del entorno académico

Los USD 50 corresponden a la capacidad real de la cuenta académica para ensayos temporales. No representan el precio, el dimensionamiento ni la justificación del sistema en producción. Para las pruebas estudiantiles se limita el tiempo encendido y se destruyen los recursos después; el diseño productivo conserva las redundancias que exige la continuidad aunque excedan ese crédito.

## Validación de precios

Precios minoristas consultados el **2026-11-06**. Reproduce y ajusta el cálculo en las calculadoras oficiales antes de aprobar presupuesto:

1. En AWS Pricing Calculator selecciona `us-east-1`, dos EC2 `t3.large`, RDS PostgreSQL Multi-AZ `db.t4g.medium`, ALB, dos NAT Gateway, dos Site-to-Site VPN connections, volúmenes EBS/RDS, ocho IPv4 como supuesto y servicios CloudWatch/ECR/Secrets Manager.
2. En Azure Pricing Calculator selecciona `Chile Central`, `Mexico Central` y `West US 2`; agrega `VpnGw2AZ`, tres IP Standard principales, un DNS Private Resolver inbound, tres Private Endpoints, 100 GB de Azure Files primario Hot ZRS, 100 GB de copia en Mexico Central y 100 GB de cada Blob Hot ZRS. El gateway/resolver de DR se debe cotizar aparte si permanecerá encendido. Introduce las conexiones simultáneas y volumen de datos real.
3. Revisa Azure Cost Analysis y AWS Cost Explorer después de una prueba; las tarifas retail no reflejan necesariamente las condiciones de cuentas académicas.

## Fuentes oficiales

- [AWS EC2 On-Demand](https://aws.amazon.com/ec2/pricing/on-demand/) y [familia T3](https://aws.amazon.com/ec2/instance-types/t3/)
- [AWS Application Load Balancer](https://aws.amazon.com/elasticloadbalancing/pricing/)
- [AWS NAT Gateway e IPv4](https://aws.amazon.com/vpc/pricing/) · [modelo de cobro NAT](https://docs.aws.amazon.com/vpc/latest/userguide/nat-gateway-pricing.html)
- [AWS Site-to-Site VPN](https://aws.amazon.com/vpn/pricing/)
- [AWS RDS PostgreSQL](https://aws.amazon.com/rds/postgresql/pricing/) · [AWS Price List Bulk API](https://docs.aws.amazon.com/awsaccountbilling/latest/aboutv2/using-the-aws-price-list-bulk-api-fetching-price-list-files-manually.html) · [Multi-AZ billing](https://aws.amazon.com/rds/faqs/)
- [AWS RDS PostgreSQL Multi-AZ con standby](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/Concepts.MultiAZSingleStandby.html) · [T3 y créditos de CPU](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/burstable-performance-instances-unlimited-mode-concepts.html)
- [Azure VPN Gateway pricing](https://azure.microsoft.com/en-us/pricing/details/vpn-gateway/) · [SKU recomendados para nuevos gateways](https://learn.microsoft.com/en-us/azure/vpn-gateway/about-gateway-skus)
- [Azure VPN Gateway: costos por hora y transferencia](https://learn.microsoft.com/en-us/azure/vpn-gateway/vpn-gateway-about-vpngateways)
- [Azure Retail Prices API](https://learn.microsoft.com/en-us/rest/api/cost-management/retail-prices/azure-retail-prices) · [calculadora Azure](https://azure.microsoft.com/en-us/pricing/calculator/)
- [Azure DNS Private Resolver pricing](https://azure.microsoft.com/en-in/pricing/details/dns/) · [redundancia zonal automática](https://learn.microsoft.com/en-us/azure/reliability/reliability-dns-private-resolver)
- [Azure Private Link pricing](https://azure.microsoft.com/en-us/pricing/details/private-link/)
- [Azure Functions Flex Consumption pricing](https://azure.microsoft.com/en-us/pricing/details/functions/)
- [Azure Functions Flex Consumption billing](https://learn.microsoft.com/en-us/azure/azure-functions/flex-consumption-plan) · [concesiones y precios](https://azure.microsoft.com/en-us/pricing/details/functions/)
- [Azure Functions Timer trigger and singleton scheduling](https://learn.microsoft.com/en-us/azure/azure-functions/functions-bindings-timer)
- [AzCopy para Azure Files y límites de fidelidad de sync](https://learn.microsoft.com/en-us/azure/storage/common/storage-use-azcopy-files)
- [Azure Files OAuth REST y roles privilegiados](https://learn.microsoft.com/en-us/azure/storage/files/authorize-oauth-rest)
- [Azure Files pricing](https://azure.microsoft.com/en-us/pricing/details/storage/files/) · [Azure Storage pricing](https://azure.microsoft.com/en-us/pricing/details/storage/blobs/)
- [Azure Files billing models](https://learn.microsoft.com/en-us/azure/storage/files/understanding-billing) · [Azure Files ZRS reliability](https://learn.microsoft.com/en-us/azure/reliability/reliability-storage-files)
