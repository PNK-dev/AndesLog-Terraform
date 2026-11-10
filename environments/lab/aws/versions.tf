terraform {
  required_version = ">= 1.11.0"

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
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}
