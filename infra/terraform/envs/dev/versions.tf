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

# Used for the images table (D-015). Auth mirrors azurerm: az CLI locally,
# ARM_USE_OIDC/ARM_CLIENT_ID/ARM_TENANT_ID/ARM_SUBSCRIPTION_ID in CI.
provider "azapi" {}
