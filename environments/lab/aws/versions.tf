terraform {
  required_version = ">= 1.7.0"

  cloud {
    workspaces {
      name = "andeslog-lab-aws"
    }
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}
