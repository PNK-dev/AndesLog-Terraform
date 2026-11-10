mock_provider "aws" {
  override_during = plan
}

variables {
  aws_account_id = "123456789012"
  enable_restore = false
}

override_data {
  target          = data.aws_subnet.restore["subnet-aaaaaaaa"]
  override_during = plan
  values = {
    vpc_id                  = "vpc-aaaaaaaa"
    availability_zone_id    = "usw2-az1"
    map_public_ip_on_launch = false
  }
}
override_data {
  target          = data.aws_subnet.restore["subnet-bbbbbbbb"]
  override_during = plan
  values = {
    vpc_id                  = "vpc-aaaaaaaa"
    availability_zone_id    = "usw2-az2"
    map_public_ip_on_launch = false
  }
}

run "disabled_creates_nothing" {
  command = plan
  assert {
    condition     = length(aws_db_instance.restore) == 0 && length(aws_security_group.restore) == 0 && output.restore_endpoint == ""
    error_message = "La recuperación no debe crear recursos por defecto."
  }
}

run "restore_is_private_isolated_and_protected" {
  command = plan
  variables {
    enable_restore = true
    backup_arn     = "arn:aws:rds:us-west-2:123456789012:auto-backup:ab-EXAMPLE"
    vpc_id         = "vpc-aaaaaaaa"
    subnet_ids     = ["subnet-aaaaaaaa", "subnet-bbbbbbbb"]
    recovery_id    = "test-001"
  }
  assert {
    condition = (
      length(aws_vpc_security_group_ingress_rule.probe) == 0 &&
      !aws_db_instance.restore[0].publicly_accessible && aws_db_instance.restore[0].multi_az &&
      aws_db_instance.restore[0].deletion_protection && !aws_db_instance.restore[0].skip_final_snapshot &&
      one(aws_db_instance.restore[0].restore_to_point_in_time).source_db_instance_automated_backups_arn == var.backup_arn &&
      one(aws_db_instance.restore[0].restore_to_point_in_time).use_latest_restorable_time
    )
    error_message = "La restauración debe ser privada, protegida y no permitir acceso sin verificador."
  }
}

run "restore_with_wrong_account_is_rejected" {
  command = plan
  variables {
    enable_restore = true
    backup_arn     = "arn:aws:rds:us-west-2:999999999999:auto-backup:ab-EXAMPLE"
    vpc_id         = "vpc-aaaaaaaa"
    subnet_ids     = ["subnet-aaaaaaaa", "subnet-bbbbbbbb"]
    recovery_id    = "test-002"
  }
  expect_failures = [aws_security_group.restore[0]]
}

run "restore_with_wrong_region_is_rejected" {
  command = plan
  variables {
    enable_restore = true
    backup_arn     = "arn:aws:rds:us-east-1:123456789012:auto-backup:ab-EXAMPLE"
    vpc_id         = "vpc-aaaaaaaa"
    subnet_ids     = ["subnet-aaaaaaaa", "subnet-bbbbbbbb"]
    recovery_id    = "test-003"
  }
  expect_failures = [aws_security_group.restore[0]]
}

run "restore_rejects_subnets_in_same_zone" {
  command = plan
  variables {
    enable_restore = true
    backup_arn     = "arn:aws:rds:us-west-2:123456789012:auto-backup:ab-EXAMPLE"
    vpc_id         = "vpc-aaaaaaaa"
    subnet_ids     = ["subnet-aaaaaaaa", "subnet-bbbbbbbb"]
    recovery_id    = "test-004"
  }
  override_data {
    target = data.aws_subnet.restore["subnet-bbbbbbbb"]
    values = {
      vpc_id                  = "vpc-aaaaaaaa"
      availability_zone_id    = "usw2-az1"
      map_public_ip_on_launch = false
    }
  }
  expect_failures = [aws_security_group.restore[0]]
}

run "restore_rejects_an_automatic_public_subnet" {
  command = plan
  variables {
    enable_restore = true
    backup_arn     = "arn:aws:rds:us-west-2:123456789012:auto-backup:ab-EXAMPLE"
    vpc_id         = "vpc-aaaaaaaa"
    subnet_ids     = ["subnet-aaaaaaaa", "subnet-bbbbbbbb"]
    recovery_id    = "test-005"
  }
  override_data {
    target = data.aws_subnet.restore["subnet-bbbbbbbb"]
    values = {
      vpc_id                  = "vpc-aaaaaaaa"
      availability_zone_id    = "usw2-az2"
      map_public_ip_on_launch = true
    }
  }
  expect_failures = [aws_security_group.restore[0]]
}

run "restore_allows_only_selected_verifier_and_exact_utc_time" {
  command = plan
  variables {
    enable_restore          = true
    backup_arn              = "arn:aws:rds:us-west-2:123456789012:auto-backup:ab-EXAMPLE"
    vpc_id                  = "vpc-aaaaaaaa"
    subnet_ids              = ["subnet-aaaaaaaa", "subnet-bbbbbbbb"]
    recovery_id             = "test-006"
    probe_security_group_id = "sg-aaaaaaaa"
    restore_time_utc        = "2026-11-10T12:00:00Z"
  }
  override_data {
    target = data.aws_security_group.probe[0]
    values = { vpc_id = "vpc-aaaaaaaa" }
  }
  assert {
    condition = (
      length(aws_vpc_security_group_ingress_rule.probe) == 1 &&
      aws_vpc_security_group_ingress_rule.probe[0].referenced_security_group_id == "sg-aaaaaaaa" &&
      aws_vpc_security_group_ingress_rule.probe[0].from_port == 5432 &&
      aws_vpc_security_group_ingress_rule.probe[0].to_port == 5432 &&
      one(aws_db_instance.restore[0].restore_to_point_in_time).restore_time == "2026-11-10T12:00:00Z" &&
      one(aws_db_instance.restore[0].restore_to_point_in_time).use_latest_restorable_time == null
    )
    error_message = "Solo el verificador indicado debe acceder a PostgreSQL y la restauración debe usar la fecha indicada."
  }
}

run "restore_rejects_verifier_from_another_vpc" {
  command = plan
  variables {
    enable_restore          = true
    backup_arn              = "arn:aws:rds:us-west-2:123456789012:auto-backup:ab-EXAMPLE"
    vpc_id                  = "vpc-aaaaaaaa"
    subnet_ids              = ["subnet-aaaaaaaa", "subnet-bbbbbbbb"]
    recovery_id             = "test-007"
    probe_security_group_id = "sg-aaaaaaaa"
  }
  override_data {
    target = data.aws_security_group.probe[0]
    values = { vpc_id = "vpc-bbbbbbbb" }
  }
  expect_failures = [aws_security_group.restore[0]]
}

run "restore_time_must_be_utc" {
  command = plan
  variables {
    restore_time_utc = "2026-11-10T12:00:00-05:00"
  }
  expect_failures = [var.restore_time_utc]
}

run "restore_identifier_rejects_consecutive_hyphens" {
  command = plan
  variables {
    recovery_id = "test--01"
  }
  expect_failures = [var.recovery_id]
}
