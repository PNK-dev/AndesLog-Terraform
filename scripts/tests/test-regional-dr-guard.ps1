#requires -Version 5.1
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\regional-dr-guard.ps1')

function ExpectBlocked([scriptblock]$Operation) {
    try { & $Operation } catch {
        if ($_.Exception.Message -match 'evitar destruirla') { return }
        throw
    }
    throw 'Se esperaba que la protección impidiera continuar.'
}

$arn = 'arn:aws:secretsmanager:us-east-1:123456789012:secret:example'
$lambda = 'arn:aws:lambda:us-east-1:123456789012:function:rotation'
Assert-AndeslogRegionalState 'false' '' @{} '' ''
Assert-AndeslogRegionalState '' '' @{} '' ''
Assert-AndeslogRegionalState 'true' 'some-repo' @{ enable_aws_regional_dr = $true; rds_external_master_secret_arn = $arn; rds_external_rotation_lambda_arn = $lambda } $arn $lambda
ExpectBlocked { Assert-AndeslogRegionalState 'true' 'some-repo' @{} $arn $lambda }
ExpectBlocked { Assert-AndeslogRegionalState 'true' '' @{ enable_aws_regional_dr = 'false'; rds_external_master_secret_arn = $arn; rds_external_rotation_lambda_arn = $lambda } $arn $lambda }
ExpectBlocked { Assert-AndeslogRegionalState '' 'some-repo' @{} $arn $lambda }
ExpectBlocked { Assert-AndeslogRegionalState 'true' 'some-repo' @{ enable_aws_regional_dr = $true; rds_external_master_secret_arn = 'otro'; rds_external_rotation_lambda_arn = $lambda } $arn $lambda }
ExpectBlocked { Assert-AndeslogRegionalState 'true' 'some-repo' @{ enable_aws_regional_dr = $true; rds_external_master_secret_arn = $arn; rds_external_rotation_lambda_arn = $lambda } '' $lambda }
ExpectBlocked { Assert-AndeslogRegionalState 'true' 'some-repo' @{ enable_aws_regional_dr = $true; rds_external_master_secret_arn = $arn; rds_external_rotation_lambda_arn = 'otro' } $arn $lambda }
$cert = 'arn:aws:acm:us-west-2:123456789012:certificate/example'
Assert-AndeslogRegionalRuntimeReplication 'false' '' @{}
Assert-AndeslogRegionalRuntimeReplication 'true' 'replica-arn' @{ enable_dr_runtime_secret_replication = $true }
ExpectBlocked { Assert-AndeslogRegionalRuntimeReplication 'true' 'replica-arn' @{} }
ExpectBlocked { Assert-AndeslogRegionalRuntimeReplication '' 'replica-arn' @{ enable_dr_runtime_secret_replication = 'true' } }
Assert-AndeslogRegionalProbeNetwork 'false' '' @{}
Assert-AndeslogRegionalProbeNetwork 'true' 'sg-123' @{ enable_dr_probe_network = $true }
ExpectBlocked { Assert-AndeslogRegionalProbeNetwork 'true' 'sg-123' @{} }
ExpectBlocked { Assert-AndeslogRegionalProbeNetwork '' 'sg-123' @{ enable_dr_probe_network = 'true' } }
Assert-AndeslogRegionalCompute 'false' '' '' @{}
Assert-AndeslogRegionalCompute 'true' 'standby.example' $cert @{ enable_dr_erp_compute = $true; dr_alb_certificate_arn = $cert }
ExpectBlocked { Assert-AndeslogRegionalCompute 'true' 'standby.example' $cert @{} }
ExpectBlocked { Assert-AndeslogRegionalCompute 'true' '' $cert @{ enable_dr_erp_compute = $true; dr_alb_certificate_arn = 'other' } }
ExpectBlocked { Assert-AndeslogRegionalCompute '' 'standby.example' $cert @{ enable_dr_erp_compute = 'true'; dr_alb_certificate_arn = $cert } }
Assert-AndeslogRegionalExperimentNotAutomated @{}
Assert-AndeslogFilesCheckpoint 'false' @{}
Assert-AndeslogFilesDrGateway '' @{}
Assert-AndeslogFilesDrGateway 'gateway-dr' @{ enable_files_dr_gateway = $true }
ExpectBlocked { Assert-AndeslogFilesDrGateway 'gateway-dr' @{} }
ExpectBlocked { Assert-AndeslogFilesDrGateway 'gateway-dr' @{ enable_files_dr_gateway = 'true' } }
ExpectBlocked { Assert-AndeslogFilesDrGateway 'gateway-dr' @{ enable_files_dr_gateway = $false } }
Assert-AndeslogFilesCheckpoint 'true' @{ enable_files_dr_checkpoint = $true }
ExpectBlocked { Assert-AndeslogFilesCheckpoint 'true' @{} }
ExpectBlocked { Assert-AndeslogFilesCheckpoint 'true' @{ enable_files_dr_checkpoint = 'true' } }
Assert-AndeslogEventArchiveReplication 'false' @{}
Assert-AndeslogEventArchiveReplication 'true' @{ enable_erp_event_archive_replication = $true }
ExpectBlocked { Assert-AndeslogEventArchiveReplication 'true' @{} }
ExpectBlocked { Assert-AndeslogEventArchiveReplication 'true' @{ enable_erp_event_archive_replication = 'true' } }
Assert-AndeslogIngressDrNotAutomated 'false' @{}
ExpectBlocked { Assert-AndeslogIngressDrNotAutomated 'true' @{} }
ExpectBlocked { Assert-AndeslogIngressDrNotAutomated 'false' @{ enable_erp_failover_ingest = $true } }
Assert-AndeslogBackupReplicationNotAutomated 'false' '' @{}
ExpectBlocked { Assert-AndeslogBackupReplicationNotAutomated 'true' '' @{} }
ExpectBlocked { Assert-AndeslogBackupReplicationNotAutomated 'false' 'arn:backup' @{} }
ExpectBlocked { Assert-AndeslogBackupReplicationNotAutomated 'false' '' @{ enable_rds_backup_replication = $true } }
Assert-AndeslogNoManagedRegionalBackup "aws_db_instance.main`naws_vpc.main" 'Destroy'
ExpectBlocked { Assert-AndeslogNoManagedRegionalBackup "aws_db_instance.main`naws_db_instance_automated_backups_replication.regional[0]" 'Destroy' }
ExpectBlocked { Assert-AndeslogRegionalExperimentNotAutomated @{ enable_dr_runtime_secret_replication = $true } }
ExpectBlocked { Assert-AndeslogRegionalExperimentNotAutomated @{ enable_dr_erp_compute = $true } }
ExpectBlocked { Assert-AndeslogRegionalExperimentNotAutomated @{ enable_dr_probe_network = $true } }
Assert-AndeslogExternalCredentials '' '' '' ''
Assert-AndeslogExternalCredentials $arn $lambda $arn $lambda
try { Assert-AndeslogExternalCredentials $arn $lambda '' '' ; throw 'Se esperaba bloqueo para secreto externo sin DR.' } catch {
    if ($_.Exception.Message -notmatch 'evitar cambiar credenciales') { throw }
}
Write-Host 'OK: la configuración DR faltante o contradictoria bloquea el despliegue.'
