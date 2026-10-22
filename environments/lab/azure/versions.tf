terraform {
  required_version = ">= 1.7.0"

  cloud {
    workspaces {
      name = "andeslog-lab-azure"
    }
  }

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "= 5.8.0"
    }
  }
}
