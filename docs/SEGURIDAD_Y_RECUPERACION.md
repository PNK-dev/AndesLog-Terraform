# Permisos y recuperación de AndesLog

## Alcance y verificación

La infraestructura se encuentra dada de baja. Este documento distingue la configuración de Terraform y las pruebas locales de los controles que todavía necesitan una prueba real. No contiene claves ni contraseñas.

Para obtener un inventario de solo lectura con las sesiones AWS y Azure activas:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\audit-permissions.ps1
```

El comando comprueba las cuentas esperadas, consulta el rol del perfil EC2 de laboratorio, enumera sus políticas y el límite IAM si existe, e informa las asignaciones directas consultadas de la identidad Azure a nivel de suscripción y del grupo `andeslog-lab-rg`. No imprime los documentos de políticas, las claves ni el estado. No es una prueba de permisos efectivos: faltan las políticas completas, grupos, permisos de recurso, posibles denegaciones, límites de organización y otras asignaciones. Si falta un permiso de consulta, el inventario se detiene y se considera incompleto.

En una lectura del 10/11/2026, `LabInstanceProfile` contenía el rol `LabRole`, con siete políticas administradas, incluidas políticas de EKS, SSM y ECR, sin límite de permisos IAM visible en la consulta; la identidad Azure actual tenía `Owner` a nivel de suscripción. El rol del laboratorio es externo y puede tener restricciones adicionales. Son **observaciones**, no pruebas de privilegios efectivos ni de cumplimiento. No retirar ni modificar esas políticas o la asignación Owner sin confirmar primero quién administra las cuentas, el acceso alternativo y el impacto en el laboratorio. El rol Terraform propio de web se usa únicamente cuando no se indica un perfil externo; su política delimita la lectura del secreto y repositorio ERP, excepto la autorización ECR que exige recurso `*`. Ver [evaluación de políticas IAM](https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_policies_evaluation-logic.html).

## Permisos PostgreSQL del ERP

Para bases nuevas o compatibles, el bootstrap prepara `andeslog_app` sin que sea propietario de la base ni del esquema. Las migraciones Alembic se ejecutan con la identidad propietaria RDS mediante un archivo temporal, protegido en el host bootstrap y eliminado después. Después se autorizan operaciones de lectura y escritura sobre las tablas de negocio existentes y uso/lectura de secuencias. `alembic_version` solo tiene lectura. El rol no debe tener permisos efectivos de creación en base o esquema, temporales, `TRUNCATE` o `TRIGGER`; también se revoca `CREATE` del esquema público y `CREATE`/`TEMPORARY` de la base al grupo `PUBLIC`. Esto afecta a todos los usuarios de esa base, no solo al ERP.

El rol de operación sigue pudiendo leer y modificar los datos de las tablas de negocio, incluidos usuarios; no es aislamiento por módulo ni sustituye la autorización del ERP. El propietario maestro mantiene permisos elevados para mantenimiento. No se activan permisos por defecto para tablas futuras: después de cada migración se repite el paso de concesiones. Los permisos de la identidad RDS administradora y de las funciones PostgreSQL requieren una revisión específica en AWS. Ver [privilegios PostgreSQL](https://www.postgresql.org/docs/16/ddl-priv.html) y [GRANT](https://www.postgresql.org/docs/16/sql-grant.html).

El directorio temporal del operador se crea con una ACL privada antes de escribir secretos. El archivo local `andeslog.runtime.secret` también se crea o protege para el usuario Windows actual; los procesos ejecutados con esa misma cuenta aún pueden leerlo. En el bootstrap remoto se crea primero un directorio único con permiso `0700`, y dentro se transfieren los secretos y se crea el entorno de migración temporal con permiso `0600`. Se intenta eliminar el directorio y los archivos incluso si falla la migración. Si la conexión SSH se interrumpe no se puede garantizar la limpieza remota: revisa la VM bootstrap antes de reutilizarla o eliminarla. El secreto maestro no se publica en el secreto de runtime del ERP. La migración sobre una base que ya tenga usuarios y tráfico debe realizarse en una ventana apropiada y requiere compatibilidad entre las versiones de esquema y aplicación; este script no garantiza despliegues sin interrupción.

La preparación **rechaza una base existente cuyo propietario sea diferente de la identidad administradora**, una base o esquema donde el usuario ERP sea propietario, y un rol ERP con capacidades elevadas o membresías. No cambia la propiedad automáticamente. Una instalación anterior donde `andeslog_app` era propietario requiere un procedimiento de migración y copia de seguridad revisados; no se debe forzar esta nueva ruta sobre datos existentes.

La prueba `scripts/tests/test-rds-permissions-local.ps1` crea PostgreSQL 16 y un ERP aislados en Docker, aplica las migraciones reales como un propietario de laboratorio, inicializa el usuario administrador y comprueba login, readiness y consultas. Demuestra que el rol de aplicación puede escribir datos de prueba y que se rechazan `CREATE`, `CREATE TEMP`, `DROP`, `TRUNCATE` y modificación de `alembic_version`. También rechaza una base con propietario legado y genera y restaura un dump aislado. Usa credenciales y datos ficticios y elimina los contenedores de prueba. **No prueba permisos `rds_superuser`, TLS, `scp`, el bootstrap remoto ni un despliegue en AWS.**

## Respaldo y recuperación de PostgreSQL

Mientras RDS exista, Terraform configura backups automáticos con siete días por defecto, valor ajustable con `rds_backup_retention_days` de 1 a 35. Multi-AZ mejora disponibilidad de instancia/zona; no reemplaza la restauración ante borrado o corrupción. AWS permite restaurar un punto dentro de la ventana disponible a una instancia nueva. Ver [backups y restauración RDS](https://docs.aws.amazon.com/AmazonRDS/latest/gettingstartedguide/managing-backup-restore.html).

Para una prueba real posterior, con la infraestructura activa y una ventana autorizada:

1. En RDS → Databases, identifica la instancia exacta, la ventana de backups, el último punto restaurable, el cifrado y la región. Si no hay backup disponible, detén la prueba.
2. Define una instancia de restauración con nombre distinto, coste acotado, subredes privadas y un grupo de seguridad que solo permita un verificador autorizado. Revisa sus rutas, permisos, KMS y protección de borrado.
3. En RDS → Automated backups, selecciona la instancia y **Restore to point in time**; elige el instante disponible y crea la base aislada. No conectes el ERP productivo a ella.
4. Comprueba que la restauración esté disponible, el endpoint y el certificado correctos, y que el usuario verificador tenga solo las lecturas necesarias. Valida revisión de migraciones, login aislado y registros de prueba o usa `scripts/verify_erp_restore.py` con una referencia protegida del mismo punto temporal.
5. Registra hora inicial/final, punto recuperado, datos comparados y discrepancias. Una comparación parcial no demuestra ausencia total de corrupción; el RTO/RPO solo se calcula a partir de la prueba y su alcance.
6. Cuando no se necesite conservar la restauración ni sus datos, revisa el identificador y el costo; retira su protección y elimínala mediante un procedimiento aprobado. Identifica cualquier snapshot o backup retenido que siga facturándose.

La prueba local creó un `pg_dump` del rol limitado y lo restauró a otra base temporal; confirmó una fila sintética. No prueba snapshots/PITR de RDS ni la recuperación de datos reales. Al ejecutar `Destroy -ConfirmDataLoss`, la configuración de laboratorio omite el snapshot final y elimina RDS; no debe asumirse que seguirán existiendo backups después de la baja. El root experimental `environments/recovery/aws-restore` y la copia regional no están probados en AWS y tienen sus propios costos y requisitos.

El script manual `scripts/upload-backup.ps1` sube un archivo no vacío como Block Blob con condición de no existencia. Si se indica S3, usa `PutObject` condicional y rechaza archivos mayores de 5 GiB antes de iniciar la carga. Así no sobrescribe un objeto actual con el mismo nombre; esto no impide su eliminación ni sustituye versionado, inmutabilidad, retención o control de acceso. Si Azure acepta la carga y S3 falla, informa el resultado parcial y conserva la copia en Azure; revisa ambos destinos antes de reintentar. El script no garantiza que el archivo local no cambie durante la carga ni verifica una restauración. Las condiciones se probaron con comandos simulados, no con cuentas cloud. Ver [condiciones en S3](https://docs.aws.amazon.com/AmazonS3/latest/userguide/conditional-writes.html) y [upload de blobs](https://learn.microsoft.com/en-us/cli/azure/storage/blob?view=azure-cli-latest#az-storage-blob-upload).

## Azure Files conservado

La cuenta y share principales se mantienen para preservar datos. El acceso público está deshabilitado y SMB sigue usando Shared Key. Una clave de cuenta da acceso amplio; la identidad para la VPN y las credenciales para SMB son cosas distintas. No desactivar Shared Key ni cambiar la identidad del share conservado sin preparar y verificar un acceso alternativo y la recuperación. Ver [seguridad de Azure Files](https://learn.microsoft.com/en-us/azure/storage/files/secure-files).

La réplica Chile → México es una copia sincronizada, no un backup consistente con historial ni una restauración probada. Para cerrar el requisito: definir retención y protección contra borrado, crear datos y permisos sintéticos, restaurarlos en un destino aislado, comprobar contenido y ACL con un cliente autorizado, registrar tiempos y luego dar de baja el entorno de prueba. No declarar el objetivo RPO/RTO alcanzado antes de esa prueba.
