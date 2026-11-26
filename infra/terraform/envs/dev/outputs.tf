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

output "aks_cluster_name" {
  description = "AKS cluster name (az aks get-credentials -n)."
  value       = module.aks.name
}

output "aks_node_resource_group" {
  description = "AKS-managed node resource group (MC_*)."
  value       = module.aks.node_resource_group
}

output "aks_oidc_issuer_url" {
  description = "AKS OIDC issuer URL (issuer of the workload identity federated credentials)."
  value       = module.aks.oidc_issuer_url
}

output "gateway_public_ip_name" {
  description = "Gateway public IP name (service.beta.kubernetes.io/azure-pip-name annotation)."
  value       = module.network.gateway_public_ip_name
}

output "gateway_public_ip_address" {
  description = "Gateway static public IP address."
  value       = module.network.gateway_public_ip_address
}

output "gateway_fqdn" {
  description = "Public hostname of the app (Gateway listener / cert-manager HTTP-01, D-011)."
  value       = module.network.gateway_fqdn
}
