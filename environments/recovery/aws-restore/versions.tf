terraform {
  required_version = ">= 1.11.0"

  cloud {
    workspaces {
      name = "andeslog-recovery-aws"
    }
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}
