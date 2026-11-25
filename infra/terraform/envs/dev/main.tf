# Workload plane for dev. CI may apply this config (ci-apply), so it must never
# grant CI anything: CI's own role assignments live in infra/bootstrap.

data "azurerm_client_config" "current" {}

# Created by infra/bootstrap so that CI role assignments can target it.
data "azurerm_resource_group" "this" {
  name = "rg-gyazo-${var.env}"
}

locals {
  tags = {
    project    = "gyazo-clone"
    env        = var.env
    owner      = var.owner
    managed_by = "terraform"
    repo       = var.github_repo
  }
}

# One suffix for all globally unique names (ACR, storage, Key Vault). Kept in state,
# so names are stable across applies.
resource "random_string" "suffix" {
  length  = 5
  lower   = true
  numeric = true
  upper   = false
  special = false
}

module "network" {
  source = "../../modules/network"

  env                 = var.env
  suffix              = random_string.suffix.result
  resource_group_name = data.azurerm_resource_group.this.name
  location            = var.location
  tags                = local.tags
}

module "registry" {
  source = "../../modules/registry"

  env                 = var.env
  suffix              = random_string.suffix.result
  resource_group_name = data.azurerm_resource_group.this.name
  location            = var.location
  tags                = local.tags
}

module "storage" {
  source = "../../modules/storage"

  env                 = var.env
  suffix              = random_string.suffix.result
  resource_group_name = data.azurerm_resource_group.this.name
  location            = var.location
  tags                = local.tags
}

module "keyvault" {
  source = "../../modules/keyvault"

  env                 = var.env
  suffix              = random_string.suffix.result
  resource_group_name = data.azurerm_resource_group.this.name
  location            = var.location
  tenant_id           = data.azurerm_client_config.current.tenant_id
  tags                = local.tags
}

# Depends on network + registry only; identity consumes its issuer URL, so there's no cycle.
module "aks" {
  source = "../../modules/aks"

  env                  = var.env
  resource_group_name  = data.azurerm_resource_group.this.name
  location             = var.location
  tenant_id            = data.azurerm_client_config.current.tenant_id
  aks_subnet_id        = module.network.aks_subnet_id
  gateway_public_ip_id = module.network.gateway_public_ip_id
  acr_id               = module.registry.id
  tags                 = local.tags
}

module "identity" {
  source = "../../modules/identity"

  env                 = var.env
  resource_group_name = data.azurerm_resource_group.this.name
  location            = var.location
  storage_account_id  = module.storage.account_id
  images_container_id = module.storage.images_container_id
  image_jobs_queue_id = module.storage.image_jobs_queue_id
  images_table_id     = module.storage.images_table_id
  key_vault_id        = module.keyvault.id
  oidc_issuer_url     = module.aks.oidc_issuer_url
  tags                = local.tags
}
