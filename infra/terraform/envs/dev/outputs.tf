output "resource_group_name" {
  description = "Workload resource group."
  value       = data.azurerm_resource_group.this.name
}

output "aks_subnet_id" {
  description = "AKS node subnet ID (input to the M3 cluster)."
  value       = module.network.aks_subnet_id
}

output "acr_login_server" {
  description = "Container registry login server."
  value       = module.registry.login_server
}

output "storage_account_name" {
  description = "App storage account name."
  value       = module.storage.account_name
}

output "key_vault_name" {
  description = "Key Vault name (target of the manual `az keyvault secret set`)."
  value       = module.keyvault.name
}

output "key_vault_uri" {
  description = "Key Vault URI."
  value       = module.keyvault.vault_uri
}

output "api_identity_client_id" {
  description = "Client ID of id-gyazo-api-<env>."
  value       = module.identity.api_client_id
}

output "worker_identity_client_id" {
  description = "Client ID of id-gyazo-worker-<env>."
  value       = module.identity.worker_client_id
}
