terraform {
  required_version = ">= 1.11.0"
  required_providers {
    aws = { source = "hashicorp/aws", version = "= 6.68.0" }
  }
}

# Test fixture only: never deploy this resource. Its provider is mocked in tests.
provider "aws" {
  region                      = "us-east-1"
  access_key                  = "testing"
  secret_key                  = "testing"
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true
  endpoints {
    rds = "http://127.0.0.1:9"
  }
}

variable "master_password" {
  type      = string
  sensitive = true
  ephemeral = true
}

resource "aws_db_instance" "candidate" {
  identifier          = "andeslog-fixture-not-for-deployment"
  engine              = "postgres"
  instance_class      = "db.t3.micro"
  username            = "andeslog_master"
  password_wo         = var.master_password
  password_wo_version = 1
  allocated_storage   = 20
  storage_encrypted   = true
  publicly_accessible = false
  skip_final_snapshot = true
}
