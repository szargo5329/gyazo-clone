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

  # Local state on purpose (see README.md and docs/decisions.md D-006).
}

provider "azurerm" {
  features {}

  # Shared keys are disabled on every storage account, so all data-plane calls use Entra ID.
  storage_use_azuread = true

  # subscription_id comes from ARM_SUBSCRIPTION_ID (see README.md).
}
