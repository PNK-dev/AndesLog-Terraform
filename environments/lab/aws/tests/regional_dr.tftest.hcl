mock_provider "aws" {
  alias           = "primary"
  override_during = plan
}

mock_provider "aws" {
  alias           = "secondary"
  override_during = plan
}

mock_provider "random" {
  override_during = plan
}

override_data {
  target          = data.aws_availability_zones.available
  override_during = plan
  values          = { names = ["us-east-1a", "us-east-1b"], zone_ids = ["use1-az1", "use1-az2"] }
}

override_data {
  target          = data.aws_availability_zones.dr[0]
  override_during = plan
  values          = { names = ["us-west-2a", "us-west-2b"] }
}

override_data {
  target          = data.aws_caller_identity.current
  override_during = plan
  values          = { account_id = "123456789012" }
}

override_data {
  target          = data.aws_kms_alias.dr_rds[0]
  override_during = plan
  values          = { target_key_arn = "arn:aws:kms:us-west-2:123456789012:key/00000000-0000-0000-0000-000000000001" }
}

run "disabled_dr_exposes_no_regional_registry" {
  command = plan
  providers = {
    aws    = aws.primary
    aws.dr = aws.secondary
    random = random
  }
  variables {
    enable_aws_regional_dr = false
    notification_email     = ""
  }
  assert {
    condition     = !output.aws_regional_dr_enabled && output.dr_erp_repository_url == "" && length(aws_ecr_repository.dr_erp) == 0
    error_message = "DR deshabilitado no debe producir un repositorio ni un indicador activo."
  }
  assert {
    condition     = length(aws_cloudformation_stack.rds_secret_target) == 0 && length(aws_secretsmanager_secret_rotation.rds_master) == 0
    error_message = "La ruta de secreto externo no debe crear recursos por defecto."
  }
  assert {
    condition     = length(aws_secretsmanager_secret.erp_runtime.replica) == 0 && output.dr_erp_runtime_secret_arn == ""
    error_message = "No debe existir una réplica regional del secreto ERP cuando DR está deshabilitado."
  }
  assert {
    condition     = length(aws_autoscaling_group.dr_erp) == 0 && length(aws_nat_gateway.dr_erp) == 0 && output.dr_erp_alb_dns_name == ""
    error_message = "La capacidad ERP de recuperación no debe crear recursos por defecto."
  }
  assert {
    condition     = !output.dr_probe_network_enabled && length(aws_subnet.dr_probe) == 0 && length(aws_vpc_peering_connection.dr_probe) == 0
    error_message = "La red regional de sondas debe estar desactivada por defecto."
  }
  assert {
    condition     = length(aws_cloudwatch_metric_alarm.dr_replica_lag_unknown) == 0 && length(aws_cloudwatch_metric_alarm.dr_replica_lag_warning) == 0 && length(aws_db_event_subscription.dr_replication) == 0
    error_message = "No deben crearse alarmas ni suscripciones regionales con DR desactivada."
  }
  assert {
    condition     = !output.rds_backup_replication_enabled && length(aws_db_instance_automated_backups_replication.regional) == 0 && output.rds_replicated_backup_arn == ""
    error_message = "La replicación de backups no debe crear recursos por defecto."
  }
  assert {
    condition     = length(aws_lb_listener.https) == 0 && one(aws_lb_listener.http.default_action).type == "forward"
    error_message = "El laboratorio debe mantener HTTP por defecto."
  }
}

run "regional_backup_is_independent_of_regional_read_replica" {
  command = plan
  providers = {
    aws    = aws.primary
    aws.dr = aws.secondary
    random = random
  }
  variables {
    enable_rds_backup_replication     = true
    enable_aws_regional_dr            = false
    rds_replica_backup_retention_days = 14
    notification_email                = ""
  }
  override_resource {
    target          = aws_db_instance.main
    override_during = plan
    values          = { arn = "arn:aws:rds:us-east-1:123456789012:db:source" }
  }
  assert {
    condition = (
      output.rds_backup_replication_enabled && length(aws_db_instance.dr_replica) == 0 &&
      aws_db_instance_automated_backups_replication.regional[0].source_db_instance_arn == "arn:aws:rds:us-east-1:123456789012:db:source" &&
      aws_db_instance_automated_backups_replication.regional[0].kms_key_id == "arn:aws:kms:us-west-2:123456789012:key/00000000-0000-0000-0000-000000000001" &&
      aws_db_instance_automated_backups_replication.regional[0].retention_period == 14
    )
    error_message = "Los backups deben depender de RDS principal y KMS regional, no de la réplica de lectura."
  }
}

run "regional_backup_rejects_same_region" {
  command = plan
  providers = {
    aws    = aws.primary
    aws.dr = aws.secondary
    random = random
  }
  variables {
    enable_rds_backup_replication = true
    aws_dr_region                 = "us-east-1"
    notification_email            = ""
  }
  expect_failures = [aws_db_instance_automated_backups_replication.regional[0]]
}

run "regional_backup_rejects_invalid_retention" {
  command = plan
  providers = {
    aws    = aws.primary
    aws.dr = aws.secondary
    random = random
  }
  variables {
    rds_replica_backup_retention_days = 36
    notification_email                = ""
  }
  expect_failures = [var.rds_replica_backup_retention_days]
}

run "rds_retention_cannot_exceed_service_limit" {
  command = plan
  providers = {
    aws    = aws.primary
    aws.dr = aws.secondary
    random = random
  }
  variables {
    backup_retention_days = 365
    notification_email    = ""
  }
  expect_failures = [aws_db_instance.main]
}

run "rds_and_s3_retention_can_differ" {
  command = plan
  providers = {
    aws    = aws.primary
    aws.dr = aws.secondary
    random = random
  }
  variables {
    backup_retention_days     = 365
    rds_backup_retention_days = 35
    notification_email        = ""
  }
  assert {
    condition     = aws_db_instance.main.backup_retention_period == 35
    error_message = "RDS debe respetar su límite sin restringir la retención S3."
  }
}

run "primary_https_uses_certificate_and_redirect" {
  command = plan
  providers = {
    aws    = aws.primary
    aws.dr = aws.secondary
    random = random
  }
  variables {
    alb_certificate_arn = "arn:aws:acm:us-east-1:123456789012:certificate/12345678-1234-1234-1234-123456789012"
    notification_email  = ""
  }
  assert {
    condition = (
      length(aws_lb_listener.https) == 1 && aws_lb_listener.https[0].protocol == "HTTPS" &&
      one(aws_lb_listener.http.default_action).type == "redirect" &&
      one(one(aws_lb_listener.http.default_action).redirect).protocol == "HTTPS"
    )
    error_message = "El certificado debe habilitar HTTPS y redirigir HTTP."
  }
}

run "primary_https_rejects_wrong_region" {
  command = plan
  providers = {
    aws    = aws.primary
    aws.dr = aws.secondary
    random = random
  }
  variables {
    alb_certificate_arn = "arn:aws:acm:us-west-2:123456789012:certificate/12345678-1234-1234-1234-123456789012"
    notification_email  = ""
  }
  expect_failures = [aws_lb_listener.https[0]]
}

run "primary_https_rejects_wrong_account" {
  command = plan
  providers = {
    aws    = aws.primary
    aws.dr = aws.secondary
    random = random
  }
  variables {
    alb_certificate_arn = "arn:aws:acm:us-east-1:999999999999:certificate/12345678-1234-1234-1234-123456789012"
    notification_email  = ""
  }
  expect_failures = [aws_lb_listener.https[0]]
}

run "probe_network_requires_regional_dr" {
  command = plan
  providers = {
    aws    = aws.primary
    aws.dr = aws.secondary
    random = random
  }
  variables {
    enable_aws_regional_dr  = false
    enable_dr_probe_network = true
    notification_email      = ""
  }
  expect_failures = [var.enable_dr_probe_network]
}

run "regional_compute_requires_regional_dr" {
  command = plan
  providers = {
    aws    = aws.primary
    aws.dr = aws.secondary
    random = random
  }
  variables {
    enable_aws_regional_dr = false
    enable_dr_erp_compute  = true
    notification_email     = ""
  }
  expect_failures = [var.enable_dr_erp_compute]
}

run "runtime_replication_requires_regional_dr" {
  command = plan
  providers = {
    aws    = aws.primary
    aws.dr = aws.secondary
    random = random
  }
  variables {
    enable_aws_regional_dr               = false
    enable_dr_runtime_secret_replication = true
    notification_email                   = ""
  }
  expect_failures = [var.enable_dr_runtime_secret_replication]
}

run "regional_compute_requires_secret_replication" {
  command = plan
  providers = {
    aws    = aws.primary
    aws.dr = aws.secondary
    random = random
  }
  variables {
    enable_aws_regional_dr               = true
    enable_dr_erp_compute                = true
    enable_dr_runtime_secret_replication = false
    notification_email                   = ""
    rds_external_master_secret_arn       = "arn:aws:secretsmanager:us-east-1:123456789012:secret:external"
    rds_external_rotation_lambda_arn     = "arn:aws:lambda:us-east-1:123456789012:function:rotation"
    rds_master_password                  = "fixture-password-not-a-secret"
    dr_alb_certificate_arn               = "arn:aws:acm:us-west-2:123456789012:certificate/12345678-1234-1234-1234-123456789012"
  }
  override_resource {
    target          = aws_db_instance.main
    override_during = plan
    values = {
      arn                = "arn:aws:rds:us-east-1:123456789012:db:source"
      master_user_secret = []
    }
  }
  expect_failures = [var.enable_dr_erp_compute]
}

run "external_secret_requires_rotation_lambda" {
  command = plan
  providers = {
    aws    = aws.primary
    aws.dr = aws.secondary
    random = random
  }
  variables {
    enable_aws_regional_dr         = false
    notification_email             = ""
    rds_external_master_secret_arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:external"
    rds_master_password            = "fixture-password-not-a-secret"
  }
  expect_failures = [aws_db_instance.main]
}

run "external_secret_requires_ephemeral_password" {
  command = plan
  providers = {
    aws    = aws.primary
    aws.dr = aws.secondary
    random = random
  }
  variables {
    enable_aws_regional_dr           = false
    notification_email               = ""
    rds_external_master_secret_arn   = "arn:aws:secretsmanager:us-east-1:123456789012:secret:external"
    rds_external_rotation_lambda_arn = "arn:aws:lambda:us-east-1:123456789012:function:rotation"
  }
  expect_failures = [var.rds_master_password]
}

run "external_secret_rejects_invalid_rds_password" {
  command = plan
  providers = {
    aws    = aws.primary
    aws.dr = aws.secondary
    random = random
  }
  variables {
    enable_aws_regional_dr           = false
    notification_email               = ""
    rds_external_master_secret_arn   = "arn:aws:secretsmanager:us-east-1:123456789012:secret:external"
    rds_external_rotation_lambda_arn = "arn:aws:lambda:us-east-1:123456789012:function:rotation"
    rds_master_password              = "invalid@password"
  }
  expect_failures = [var.rds_master_password]
}

run "external_secret_configures_rotation_for_new_database" {
  command = plan
  providers = {
    aws    = aws.primary
    aws.dr = aws.secondary
    random = random
  }
  variables {
    enable_aws_regional_dr           = false
    notification_email               = ""
    rds_external_master_secret_arn   = "arn:aws:secretsmanager:us-east-1:123456789012:secret:external"
    rds_external_rotation_lambda_arn = "arn:aws:lambda:us-east-1:123456789012:function:rotation"
    rds_master_password              = "fixture-password-not-a-secret"
  }
  assert {
    condition     = aws_db_instance.main.manage_master_user_password == null && aws_db_instance.main.password_wo_version == 1
    error_message = "La contraseña externa debe utilizar el argumento de solo escritura."
  }
  assert {
    condition     = aws_secretsmanager_secret_rotation.rds_master[0].rotation_rules[0].automatically_after_days == 7 && !aws_secretsmanager_secret_rotation.rds_master[0].rotate_immediately
    error_message = "El secreto externo debe tener una programación de rotación y no rotar inmediatamente."
  }
  assert {
    condition = (
      jsondecode(aws_cloudformation_stack.rds_secret_target[0].template_body).Resources.RdsSecretTarget.Type == "AWS::SecretsManager::SecretTargetAttachment" &&
      jsondecode(aws_cloudformation_stack.rds_secret_target[0].template_body).Resources.RdsSecretTarget.Properties.SecretId == var.rds_external_master_secret_arn &&
      jsondecode(aws_cloudformation_stack.rds_secret_target[0].template_body).Resources.RdsSecretTarget.Properties.TargetId == aws_db_instance.main.identifier &&
      jsondecode(aws_cloudformation_stack.rds_secret_target[0].template_body).Resources.RdsSecretTarget.Properties.TargetType == "AWS::RDS::DBInstance"
    )
    error_message = "El secreto dedicado debe asociarse a la base primaria antes de programar la rotación."
  }
  assert {
    condition     = !strcontains(aws_cloudformation_stack.rds_secret_target[0].template_body, "fixture-password-not-a-secret")
    error_message = "La plantilla de la asociación no debe contener la contraseña maestra."
  }
}

run "external_secret_wrong_region_is_rejected" {
  command = plan
  providers = {
    aws    = aws.primary
    aws.dr = aws.secondary
    random = random
  }
  variables {
    enable_aws_regional_dr           = false
    notification_email               = ""
    rds_external_master_secret_arn   = "arn:aws:secretsmanager:us-west-2:123456789012:secret:external"
    rds_external_rotation_lambda_arn = "arn:aws:lambda:us-east-1:123456789012:function:rotation"
    rds_master_password              = "fixture-password-not-a-secret"
  }
  expect_failures = [aws_db_instance.main]
}

run "rds_managed_password_blocks_replica" {
  command = plan
  providers = {
    aws    = aws.primary
    aws.dr = aws.secondary
    random = random
  }
  variables {
    enable_aws_regional_dr           = true
    notification_email               = ""
    rds_external_master_secret_arn   = "arn:aws:secretsmanager:us-east-1:123456789012:secret:external"
    rds_external_rotation_lambda_arn = "arn:aws:lambda:us-east-1:123456789012:function:rotation"
    rds_master_password              = "fixture-password-not-a-secret"
  }
  override_resource {
    target          = aws_db_instance.main
    override_during = plan
    values = {
      arn = "arn:aws:rds:us-east-1:123456789012:db:source"
      master_user_secret = [{
        secret_arn    = "arn:aws:secretsmanager:us-east-1:123456789012:secret:test"
        secret_status = "active"
        kms_key_id    = "arn:aws:kms:us-east-1:123456789012:key/test"
      }]
    }
  }
  expect_failures = [aws_db_instance.dr_replica]
}

run "missing_external_secret_blocks_replica" {
  command = plan
  providers = {
    aws    = aws.primary
    aws.dr = aws.secondary
    random = random
  }
  variables {
    enable_aws_regional_dr = true
    notification_email     = ""
  }
  override_resource {
    target          = aws_db_instance.main
    override_during = plan
    values = {
      arn                = "arn:aws:rds:us-east-1:123456789012:db:source"
      master_user_secret = []
    }
  }
  expect_failures = [aws_db_instance.dr_replica]
}

run "same_region_is_rejected" {
  command = plan
  providers = {
    aws    = aws.primary
    aws.dr = aws.secondary
    random = random
  }
  variables {
    enable_aws_regional_dr               = true
    enable_dr_runtime_secret_replication = true
    aws_dr_region                        = "us-east-1"
    notification_email                   = ""
  }
  expect_failures = [aws_vpc.dr, aws_ecr_repository.dr_erp, aws_secretsmanager_secret.erp_runtime]
}

run "replica_is_private_and_multiaz_after_credential_migration" {
  command = plan
  providers = {
    aws    = aws.primary
    aws.dr = aws.secondary
    random = random
  }
  variables {
    enable_aws_regional_dr               = true
    enable_dr_runtime_secret_replication = true
    notification_email                   = ""
    rds_external_master_secret_arn       = "arn:aws:secretsmanager:us-east-1:123456789012:secret:external"
    rds_external_rotation_lambda_arn     = "arn:aws:lambda:us-east-1:123456789012:function:rotation"
    rds_master_password                  = "fixture-password-not-a-secret"
    web_instance_profile_name            = ""
  }
  override_resource {
    target          = aws_db_instance.main
    override_during = plan
    values = {
      arn                = "arn:aws:rds:us-east-1:123456789012:db:source"
      master_user_secret = []
    }
  }
  override_resource {
    target          = aws_secretsmanager_secret.erp_runtime
    override_during = plan
    values = {
      arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:andeslog-lab/erp/runtime-ABC123"
    }
  }
  override_resource {
    target          = aws_ecr_repository.erp
    override_during = plan
    values          = { arn = "arn:aws:ecr:us-east-1:123456789012:repository/andeslog-lab-erp" }
  }
  override_resource {
    target          = aws_ecr_repository.dr_erp[0]
    override_during = plan
    values          = { arn = "arn:aws:ecr:us-west-2:123456789012:repository/andeslog-lab-erp" }
  }
  assert {
    condition     = aws_db_instance.dr_replica[0].multi_az && !aws_db_instance.dr_replica[0].publicly_accessible
    error_message = "La réplica debe ser privada y Multi-AZ."
  }
  assert {
    condition     = aws_db_instance.dr_replica[0].replicate_source_db == "arn:aws:rds:us-east-1:123456789012:db:source" && length(aws_subnet.dr_database) == 2
    error_message = "La réplica debe usar la base de origen y dos subredes regionales."
  }
  assert {
    condition     = aws_db_instance.dr_replica[0].kms_key_id == "arn:aws:kms:us-west-2:123456789012:key/00000000-0000-0000-0000-000000000001"
    error_message = "La réplica debe usar una clave KMS de la región secundaria."
  }
  assert {
    condition = (
      aws_cloudwatch_metric_alarm.dr_replica_lag_unknown[0].comparison_operator == "LessThanThreshold" &&
      aws_cloudwatch_metric_alarm.dr_replica_lag_unknown[0].threshold == 0 &&
      aws_cloudwatch_metric_alarm.dr_replica_lag_unknown[0].statistic == "Minimum" &&
      aws_cloudwatch_metric_alarm.dr_replica_lag_unknown[0].treat_missing_data == "breaching" &&
      aws_cloudwatch_metric_alarm.dr_replica_lag_warning[0].threshold == 180 &&
      aws_cloudwatch_metric_alarm.dr_replica_lag_warning[0].comparison_operator == "GreaterThanOrEqualToThreshold" &&
      length(aws_db_event_subscription.dr_replication) == 0
    )
    error_message = "Se deben vigilar valores negativos y retrasos tempranos, sin suscripción de eventos si no hay correo."
  }
  assert {
    condition = (
      aws_ecr_repository.dr_erp[0].name == aws_ecr_repository.erp.name &&
      aws_ecr_repository.dr_erp[0].image_tag_mutability == "IMMUTABLE" &&
      aws_ecr_repository.dr_erp[0].image_scanning_configuration[0].scan_on_push &&
      aws_ecr_repository.dr_erp[0].encryption_configuration[0].encryption_type == "AES256" &&
      !aws_ecr_repository.dr_erp[0].force_delete
    )
    error_message = "El registro DR debe usar el mismo nombre, cifrado, escaneo, etiquetas inmutables y protección contra borrado con imágenes."
  }
  assert {
    condition     = output.aws_regional_dr_enabled
    error_message = "El estado debe publicar que la recuperación regional está habilitada."
  }
  assert {
    condition = (
      length(aws_secretsmanager_secret.erp_runtime.replica) == 1 &&
      one(aws_secretsmanager_secret.erp_runtime.replica).region == "us-west-2" &&
      output.dr_erp_runtime_secret_arn == "arn:aws:secretsmanager:us-west-2:123456789012:secret:andeslog-lab/erp/runtime-ABC123" &&
      contains(jsondecode(aws_iam_role_policy.web_runtime[0].policy).Statement[2].Resource, output.dr_erp_runtime_secret_arn)
    )
    error_message = "El secreto regional debe replicarse en la región DR y el rol administrado debe poder leerlo."
  }
}

run "regional_replication_notifications_target_only_dr_instance" {
  command = plan
  providers = {
    aws    = aws.primary
    aws.dr = aws.secondary
    random = random
  }
  variables {
    enable_aws_regional_dr           = true
    notification_email               = "alerts@example.com"
    rds_external_master_secret_arn   = "arn:aws:secretsmanager:us-east-1:123456789012:secret:external"
    rds_external_rotation_lambda_arn = "arn:aws:lambda:us-east-1:123456789012:function:rotation"
    rds_master_password              = "fixture-password-not-a-secret"
  }
  override_resource {
    target          = aws_db_instance.main
    override_during = plan
    values = {
      arn                = "arn:aws:rds:us-east-1:123456789012:db:source"
      master_user_secret = []
    }
  }
  override_resource {
    target          = aws_sns_topic.dr_alarm_email[0]
    override_during = plan
    values          = { arn = "arn:aws:sns:us-west-2:123456789012:dr-alarms" }
  }
  assert {
    condition = (
      aws_db_event_subscription.dr_replication[0].source_type == "db-instance" &&
      one(aws_db_event_subscription.dr_replication[0].source_ids) == aws_db_instance.dr_replica[0].identifier &&
      toset(aws_db_event_subscription.dr_replication[0].event_categories) == toset(["read replica", "failure"]) &&
      aws_db_event_subscription.dr_replication[0].sns_topic == aws_sns_topic.dr_alarm_email[0].arn &&
      contains(aws_cloudwatch_metric_alarm.dr_replica_lag_warning[0].alarm_actions, aws_sns_topic.dr_alarm_email[0].arn) &&
      contains(aws_cloudwatch_metric_alarm.dr_replica_lag_unknown[0].alarm_actions, aws_sns_topic.dr_alarm_email[0].arn)
    )
    error_message = "Los eventos y alarmas deben dirigirse al SNS regional y vigilar solo la réplica."
  }
}

run "standby_erp_uses_two_zones_and_blocks_business_traffic" {
  command = plan
  providers = {
    aws    = aws.primary
    aws.dr = aws.secondary
    random = random
  }
  variables {
    enable_aws_regional_dr               = true
    enable_dr_erp_compute                = true
    enable_dr_runtime_secret_replication = true
    notification_email                   = ""
    rds_external_master_secret_arn       = "arn:aws:secretsmanager:us-east-1:123456789012:secret:external"
    rds_external_rotation_lambda_arn     = "arn:aws:lambda:us-east-1:123456789012:function:rotation"
    rds_master_password                  = "fixture-password-not-a-secret"
    dr_alb_certificate_arn               = "arn:aws:acm:us-west-2:123456789012:certificate/12345678-1234-1234-1234-123456789012"
    web_instance_profile_name            = ""
  }
  override_resource {
    target          = aws_db_instance.main
    override_during = plan
    values = {
      arn                = "arn:aws:rds:us-east-1:123456789012:db:source"
      master_user_secret = []
    }
  }
  override_resource {
    target          = aws_db_instance.dr_replica[0]
    override_during = plan
    values          = { address = "standby.example.rds.amazonaws.com" }
  }
  override_resource {
    target          = aws_ecr_repository.dr_erp[0]
    override_during = plan
    values          = { repository_url = "123456789012.dkr.ecr.us-west-2.amazonaws.com/andeslog-lab-erp" }
  }
  override_resource {
    target          = aws_secretsmanager_secret.erp_runtime
    override_during = plan
    values          = { arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:erp-ABC123" }
  }
  override_data {
    target          = data.aws_ami.dr_ubuntu[0]
    override_during = plan
    values          = { id = "ami-12345678" }
  }
  assert {
    condition = (
      length(aws_subnet.dr_public) == 2 && length(aws_subnet.dr_app) == 2 &&
      length(aws_nat_gateway.dr_erp) == 2 && length(aws_route.dr_app_default) == 2 &&
      aws_subnet.dr_app["a"].availability_zone != aws_subnet.dr_app["b"].availability_zone &&
      aws_autoscaling_group.dr_erp[0].min_size == 2 && aws_autoscaling_group.dr_erp[0].health_check_type == "ELB" &&
      aws_autoscaling_policy.dr_erp_cpu[0].target_tracking_configuration[0].target_value == 60
    )
    error_message = "La flota secundaria debe usar dos zonas y egreso independiente con supervisión ELB."
  }
  assert {
    condition = (
      aws_lb_listener.dr_https[0].protocol == "HTTPS" &&
      aws_lb_listener.dr_https[0].default_action[0].type == "fixed-response" &&
      aws_lb_listener.dr_https[0].default_action[0].fixed_response[0].status_code == "503" &&
      aws_lb_target_group.dr_erp[0].health_check[0].path == "/api/health/live" &&
      toset(one(one(aws_lb_listener_rule.dr_health[0].condition).path_pattern).values) == toset(["/api/health/live"])
    )
    error_message = "El standby debe usar HTTPS, exponer solo liveness y bloquear readiness y tráfico de negocio."
  }
  assert {
    condition = (
      strcontains(base64decode(aws_launch_template.dr_erp[0].user_data), "--database-host 'standby.example.rds.amazonaws.com'") &&
      strcontains(base64decode(aws_launch_template.dr_erp[0].user_data), "if [ \"false\" = \"true\" ]") &&
      strcontains(base64decode(aws_launch_template.dr_erp[0].user_data), "arn:aws:secretsmanager:us-west-2:123456789012:secret:erp-ABC123") &&
      aws_launch_template.dr_erp[0].metadata_options[0].http_tokens == "required" &&
      aws_launch_template.dr_erp[0].block_device_mappings[0].ebs[0].encrypted
    )
    error_message = "El standby debe usar secreto y base regionales, desactivar el worker, exigir IMDSv2 y cifrar EBS."
  }
  assert {
    condition = (
      aws_cloudwatch_metric_alarm.dr_erp_targets[0].metric_name == "HealthyHostCount" &&
      aws_cloudwatch_metric_alarm.dr_erp_targets[0].threshold == 2 &&
      aws_cloudwatch_metric_alarm.dr_erp_targets[0].treat_missing_data == "breaching" &&
      aws_cloudwatch_metric_alarm.dr_erp_unhealthy[0].metric_name == "UnHealthyHostCount" &&
      aws_cloudwatch_metric_alarm.dr_erp_unhealthy[0].statistic == "Minimum"
    )
    error_message = "La región secundaria debe alertar si faltan destinos o si todos los nodos del ALB observan destinos no saludables."
  }
}

run "standby_rejects_certificate_from_primary_region" {
  command = plan
  providers = {
    aws    = aws.primary
    aws.dr = aws.secondary
    random = random
  }
  variables {
    enable_aws_regional_dr               = true
    enable_dr_erp_compute                = true
    enable_dr_runtime_secret_replication = true
    notification_email                   = ""
    rds_external_master_secret_arn       = "arn:aws:secretsmanager:us-east-1:123456789012:secret:external"
    rds_external_rotation_lambda_arn     = "arn:aws:lambda:us-east-1:123456789012:function:rotation"
    rds_master_password                  = "fixture-password-not-a-secret"
    dr_alb_certificate_arn               = "arn:aws:acm:us-east-1:123456789012:certificate/12345678-1234-1234-1234-123456789012"
  }
  override_resource {
    target          = aws_db_instance.main
    override_during = plan
    values = {
      arn                = "arn:aws:rds:us-east-1:123456789012:db:source"
      master_user_secret = []
    }
  }
  expect_failures = [aws_lb.dr_erp[0]]
}

run "probe_network_is_private_and_limited_to_database_subnets" {
  command = plan
  providers = {
    aws    = aws.primary
    aws.dr = aws.secondary
    random = random
  }
  variables {
    enable_aws_regional_dr           = true
    enable_dr_probe_network          = true
    notification_email               = ""
    rds_external_master_secret_arn   = "arn:aws:secretsmanager:us-east-1:123456789012:secret:external"
    rds_external_rotation_lambda_arn = "arn:aws:lambda:us-east-1:123456789012:function:rotation"
    rds_master_password              = "fixture-password-not-a-secret"
  }
  override_resource {
    target          = aws_db_instance.main
    override_during = plan
    values = {
      arn                = "arn:aws:rds:us-east-1:123456789012:db:source"
      master_user_secret = []
    }
  }
  assert {
    condition = (
      output.dr_probe_network_enabled && length(aws_subnet.dr_probe) == 2 &&
      aws_subnet.dr_probe["a"].cidr_block == "10.10.31.0/24" &&
      aws_subnet.dr_probe["b"].cidr_block == "10.10.32.0/24" &&
      !aws_subnet.dr_probe["a"].map_public_ip_on_launch &&
      aws_subnet.dr_probe["a"].availability_zone != aws_subnet.dr_probe["b"].availability_zone &&
      aws_vpc_peering_connection.dr_probe[0].peer_region == "us-west-2" &&
      !aws_vpc_peering_connection.dr_probe[0].auto_accept &&
      aws_vpc_peering_connection_accepter.dr_probe[0].auto_accept
    )
    error_message = "Las subredes de supervisión y el peering deben usar dos zonas, IP privadas y aceptación regional."
  }
  assert {
    condition = (
      length(aws_route.dr_probe_to_replica) == 2 && length(aws_route.dr_replica_to_probe) == 2 &&
      aws_route.dr_probe_to_replica["a"].destination_cidr_block == "10.11.21.0/24" &&
      aws_route.dr_probe_to_replica["b"].destination_cidr_block == "10.11.22.0/24" &&
      aws_route.dr_replica_to_probe["a"].destination_cidr_block == "10.10.31.0/24" &&
      aws_route.dr_replica_to_probe["b"].destination_cidr_block == "10.10.32.0/24" &&
      length(aws_route_table_association.dr_probe_replica) == 2
    )
    error_message = "Las rutas deben limitarse a las subredes de supervisión y base y ser bidireccionales."
  }
  assert {
    condition = (
      aws_vpc_peering_connection_options.dr_probe_requester[0].requester[0].allow_remote_vpc_dns_resolution &&
      aws_vpc_peering_connection_options.dr_probe_accepter[0].accepter[0].allow_remote_vpc_dns_resolution &&
      length(aws_vpc_security_group_ingress_rule.dr_db_from_probe) == 2 &&
      aws_vpc_security_group_ingress_rule.dr_db_from_probe["a"].cidr_ipv4 == "10.10.31.0/24" &&
      aws_vpc_security_group_ingress_rule.dr_db_from_probe["b"].cidr_ipv4 == "10.10.32.0/24" &&
      aws_vpc_security_group_ingress_rule.dr_db_from_probe["a"].from_port == 5432 &&
      aws_vpc_security_group_ingress_rule.dr_db_from_probe["a"].to_port == 5432 &&
      aws_vpc_security_group_ingress_rule.primary_db_from_dr_probe[0].from_port == 5432 &&
      aws_vpc_security_group_egress_rule.dr_probe_primary_db[0].to_port == 5432 &&
      length(aws_vpc_security_group_egress_rule.dr_probe_replica_db) == 2 &&
      aws_vpc_security_group_egress_rule.dr_probe_replica_db["a"].cidr_ipv4 == "10.11.21.0/24" &&
      aws_vpc_security_group_egress_rule.dr_probe_replica_db["b"].cidr_ipv4 == "10.11.22.0/24" &&
      length(aws_security_group.dr_probe[0].ingress) == 0
    )
    error_message = "El DNS del peering y los permisos PostgreSQL deben limitar el acceso a las subredes de sondas."
  }
}
