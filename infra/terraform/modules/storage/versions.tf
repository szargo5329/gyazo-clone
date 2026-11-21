terraform {
  required_version = ">= 1.15"

  required_providers {
    azapi = {
      source  = "Azure/azapi"
      version = "~> 2.14"
    }
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.14"
    }
  }
}
