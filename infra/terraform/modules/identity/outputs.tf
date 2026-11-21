output "api_identity_id" {
  description = "Resource ID of the API workload identity."
  value       = azurerm_user_assigned_identity.api.id
}

output "api_client_id" {
  description = "Client ID of the API workload identity (service account annotation in M3)."
  value       = azurerm_user_assigned_identity.api.client_id
}

output "api_principal_id" {
  description = "Principal (object) ID of the API workload identity."
  value       = azurerm_user_assigned_identity.api.principal_id
}

output "worker_identity_id" {
  description = "Resource ID of the worker workload identity."
  value       = azurerm_user_assigned_identity.worker.id
}

output "worker_client_id" {
  description = "Client ID of the worker workload identity (service account annotation in M3)."
  value       = azurerm_user_assigned_identity.worker.client_id
}

output "worker_principal_id" {
  description = "Principal (object) ID of the worker workload identity."
  value       = azurerm_user_assigned_identity.worker.principal_id
}
