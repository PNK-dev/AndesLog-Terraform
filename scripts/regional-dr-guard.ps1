#requires -Version 5.1

function Assert-AndeslogFilesDrGateway([string]$GatewayName, [hashtable]$Overlay) {
    if ($GatewayName -and (-not $Overlay.ContainsKey('enable_files_dr_gateway') -or
        $Overlay['enable_files_dr_gateway'] -isnot [bool] -or $Overlay['enable_files_dr_gateway'] -ne $true)) {
        throw 'El estado Azure contiene la infraestructura VPN de recuperación de Files. Usa -EnableFilesDrGateway para conservarla; se detiene Deploy para evitar destruirla.'
    }
}

function Assert-AndeslogFilesCheckpoint([string]$Enabled, [hashtable]$Overlay) {
    if ($Enabled -eq 'true' -and (-not $Overlay.ContainsKey('enable_files_dr_checkpoint') -or
        $Overlay['enable_files_dr_checkpoint'] -isnot [bool] -or
        $Overlay['enable_files_dr_checkpoint'] -ne $true)) {
        throw 'El estado remoto tiene checkpoint de Azure Files habilitado, pero este clon no lo conserva en su overlay. Se detiene para evitar destruirla; consulta docs/RESILIENCIA.md.'
    }
}

function Assert-AndeslogEventArchiveReplication([string]$Enabled, [hashtable]$Overlay) {
    if ($Enabled -eq 'true' -and (-not $Overlay.ContainsKey('enable_erp_event_archive_replication') -or
        $Overlay['enable_erp_event_archive_replication'] -isnot [bool] -or
        $Overlay['enable_erp_event_archive_replication'] -ne $true)) {
        throw 'El estado remoto contiene una réplica regional de eventos y este clon no conserva su configuración. Se detiene para evitar destruirla; consulta docs/RESILIENCIA.md.'
    }
}

function Assert-AndeslogIngressDrNotAutomated([string]$Enabled, [hashtable]$Overlay) {
    if ($Enabled -eq 'true' -or ($Overlay.ContainsKey('enable_erp_failover_ingest') -and $Overlay['enable_erp_failover_ingest'] -eq $true)) {
        throw 'La Function regional experimental todavía no se publica ni configura desde Deploy. Se detiene para evitar destruirla o usar un servicio sin validar.'
    }
}

function Assert-AndeslogBackupReplicationNotAutomated([string]$Enabled, [string]$BackupArn, [hashtable]$Overlay) {
    if ($Enabled -eq 'true' -or $BackupArn -or
        ($Overlay.ContainsKey('enable_rds_backup_replication') -and $Overlay['enable_rds_backup_replication'] -eq $true)) {
        throw 'La replicación regional de backups RDS aún no está integrada al despliegue y su baja puede dejar copias facturables. Se detiene para evitar destruirla o declarar una baja completa incorrecta.'
    }
}

function Assert-AndeslogNoManagedRegionalBackup([string]$StateList, [string]$Operation) {
    if (@($StateList -split "`r?`n") -contains 'aws_db_instance_automated_backups_replication.regional[0]') {
        throw "El estado contiene replicación experimental de backups RDS. Se detiene $Operation para evitar destruirla o declarar una baja completa con copias que pueden seguir facturándose. Consulta docs/RESILIENCIA.md."
    }
}

function Assert-AndeslogRegionalState([string]$Enabled, [string]$RepositoryUrl, [hashtable]$Overlay, [string]$MasterSecretArn, [string]$RotationLambdaArn) {
    if ($Enabled -eq 'true' -or $RepositoryUrl) {
        $hasDrFlag = $Overlay.ContainsKey('enable_aws_regional_dr') -and
            $Overlay['enable_aws_regional_dr'] -is [bool] -and
            $Overlay['enable_aws_regional_dr'] -eq $true
        $hasMatchingSecret = $Overlay.ContainsKey('rds_external_master_secret_arn') -and
            $MasterSecretArn -and
            $Overlay['rds_external_master_secret_arn'] -ceq $MasterSecretArn
        $hasMatchingRotation = $Overlay.ContainsKey('rds_external_rotation_lambda_arn') -and
            $RotationLambdaArn -and
            $Overlay['rds_external_rotation_lambda_arn'] -ceq $RotationLambdaArn
        if (-not $hasDrFlag -or -not $hasMatchingSecret -or -not $hasMatchingRotation) {
            throw 'El estado AWS contiene recuperación regional, pero este clon no conserva la configuración y los ARN del secreto y la rotación. Se detiene para evitar destruirla o cambiar credenciales.'
        }
    }
}

function Assert-AndeslogExternalCredentials([string]$StateSecret, [string]$StateRotation, [string]$ConfiguredSecret, [string]$ConfiguredRotation) {
    if ($StateSecret -and (($ConfiguredSecret -cne $StateSecret) -or -not $StateRotation -or ($ConfiguredRotation -cne $StateRotation))) {
        throw 'El estado AWS tiene credenciales externas y este clon no conserva los mismos ARN del secreto y la rotación. Se detiene para evitar cambiar credenciales.'
    }
}

function Assert-AndeslogRegionalCompute([string]$Enabled, [string]$AlbDns, [string]$CertificateArn, [hashtable]$Overlay) {
    if ($Enabled -eq 'true' -or $AlbDns) {
        $hasComputeFlag = $Overlay.ContainsKey('enable_dr_erp_compute') -and
            $Overlay['enable_dr_erp_compute'] -is [bool] -and $Overlay['enable_dr_erp_compute'] -eq $true
        $hasCertificate = $CertificateArn -and $Overlay.ContainsKey('dr_alb_certificate_arn') -and
            $Overlay['dr_alb_certificate_arn'] -ceq $CertificateArn
        if (-not $hasComputeFlag -or -not $hasCertificate) {
            throw 'El estado AWS contiene capacidad ERP regional, pero este clon no conserva su bandera y certificado. Se detiene para evitar destruirla o cambiar la entrada HTTPS.'
        }
    }
}

function Assert-AndeslogRegionalRuntimeReplication([string]$Enabled, [string]$ReplicaArn, [hashtable]$Overlay) {
    if ($Enabled -eq 'true' -or $ReplicaArn) {
        if (-not $Overlay.ContainsKey('enable_dr_runtime_secret_replication') -or
            $Overlay['enable_dr_runtime_secret_replication'] -isnot [bool] -or
            $Overlay['enable_dr_runtime_secret_replication'] -ne $true) {
            throw 'El estado AWS contiene un secreto ERP replicado, pero este clon no conserva esa configuración. Se detiene para evitar destruirla.'
        }
    }
}

function Assert-AndeslogRegionalProbeNetwork([string]$Enabled, [string]$SecurityGroupId, [hashtable]$Overlay) {
    if ($Enabled -eq 'true' -or $SecurityGroupId) {
        if (-not $Overlay.ContainsKey('enable_dr_probe_network') -or
            $Overlay['enable_dr_probe_network'] -isnot [bool] -or
            $Overlay['enable_dr_probe_network'] -ne $true) {
            throw 'El estado AWS contiene una red de sondas regionales, pero este clon no conserva su configuración. Se detiene para evitar destruirla.'
        }
    }
}

function Assert-AndeslogRegionalExperimentNotAutomated([hashtable]$Overlay) {
    if (($Overlay.ContainsKey('enable_dr_runtime_secret_replication') -and $Overlay['enable_dr_runtime_secret_replication'] -eq $true) -or
        ($Overlay.ContainsKey('enable_dr_erp_compute') -and $Overlay['enable_dr_erp_compute'] -eq $true) -or
        ($Overlay.ContainsKey('enable_dr_probe_network') -and $Overlay['enable_dr_probe_network'] -eq $true)) {
        throw 'El despliegue automatizado de componentes regionales experimentales sigue en pruebas. Se detiene para evitar destruirla o iniciar instancias antes de sincronizar imagen y secreto.'
    }
}
