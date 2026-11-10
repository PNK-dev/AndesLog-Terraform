# This path is opt-in and requires an independently provisioned rotation Lambda
# and a dedicated secret. CloudFormation adds the database connection metadata;
# Terraform only receives its ARN, never the secret value.
resource "aws_cloudformation_stack" "rds_secret_target" {
  count = var.rds_external_master_secret_arn == "" ? 0 : 1
  name  = "${local.prefix}-rds-secret-target"

  template_body = jsonencode({
    AWSTemplateFormatVersion = "2010-09-09"
    Description              = "Attach a dedicated Secrets Manager credential to the ERP RDS instance for rotation."
    Metadata = {
      AWSToolsMetrics = { AWSAgentToolkit = "aws-cloudformation@3" }
    }
    Resources = {
      RdsSecretTarget = {
        Type = "AWS::SecretsManager::SecretTargetAttachment"
        Metadata = {
          "com.aws.cloudformation.Context" = {
            why  = "Rotation requires current database connection information in the secret."
            must = "Use a dedicated existing secret and the primary ERP RDS instance; never put secret values in this template. Deletion removes connection metadata from the secret."
          }
        }
        Properties = {
          SecretId   = var.rds_external_master_secret_arn
          TargetId   = aws_db_instance.main.identifier
          TargetType = "AWS::RDS::DBInstance"
        }
      }
    }
  })
}

resource "aws_secretsmanager_secret_rotation" "rds_master" {
  count               = var.rds_external_master_secret_arn == "" ? 0 : 1
  secret_id           = var.rds_external_master_secret_arn
  rotation_lambda_arn = var.rds_external_rotation_lambda_arn
  rotate_immediately  = false

  rotation_rules {
    automatically_after_days = 7
  }

  depends_on = [aws_cloudformation_stack.rds_secret_target]
}
