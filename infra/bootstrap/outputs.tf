# Identifiers only, no secrets. Used for envs/dev/backend.hcl and GitHub repo variables.

output "state_resource_group_name" {
  description = "Resource group holding the Terraform state storage account and CI identities."
  value       = azurerm_resource_group.platform.name
}

output "state_storage_account_name" {
  description = "Name of the Terraform state storage account (backend.hcl storage_account_name)."
  value       = azurerm_storage_account.state.name
}

output "state_container_name" {
  description = "Name of the blob container holding Terraform state."
  value       = azurerm_storage_container.tfstate.name
}

output "env_resource_group_name" {
  description = "Workload resource group the main config deploys into."
  value       = azurerm_resource_group.env.name
}

output "ci_plan_client_id" {
  description = "Client ID of id-gyazo-ci-plan (GitHub `plan` environment variable AZURE_CLIENT_ID)."
  value       = azurerm_user_assigned_identity.ci_plan.client_id
}

output "ci_apply_client_id" {
  description = "Client ID of id-gyazo-ci-apply (GitHub `apply` environment variable AZURE_CLIENT_ID)."
  value       = azurerm_user_assigned_identity.ci_apply.client_id
}

output "tenant_id" {
  description = "Entra tenant ID (AZURE_TENANT_ID)."
  value       = data.azurerm_client_config.current.tenant_id
}

output "subscription_id" {
  description = "Azure subscription ID (AZURE_SUBSCRIPTION_ID)."
  value       = data.azurerm_subscription.current.subscription_id
}
