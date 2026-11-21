terraform {
  required_version = ">= 1.15"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.14"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.9"
    }
  }

  # Partial config: values come from backend.hcl (see backend.hcl.example), created
  # after infra/bootstrap is applied. Entra auth only; the state account has no keys.
  backend "azurerm" {}
}

provider "azurerm" {
  features {}

  # Shared keys are disabled on the storage accounts, so data-plane calls use Entra ID.
  storage_use_azuread = true

  # subscription_id comes from ARM_SUBSCRIPTION_ID (local: az account show; CI: repo variable).
}
